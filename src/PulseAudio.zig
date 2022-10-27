const std = @import("std");
const c = @cImport(@cInclude("pulse/pulseaudio.h"));
const DevicesInfo = @import("main.zig").DevicesInfo;
const Device = @import("main.zig").Device;
const Format = @import("main.zig").Format;
const ChannelLayout = @import("main.zig").ChannelLayout;
const ChannelId = @import("main.zig").ChannelId;
const ChannelArea = @import("main.zig").ChannelArea;
const Outstream = @import("main.zig").Outstream;
const max_channels = @import("main.zig").max_channels;
const min_sample_rate = @import("main.zig").min_sample_rate;
const max_sample_rate = @import("main.zig").max_sample_rate;
const builtin_channel_layouts = @import("channel_layout.zig").builtin_channel_layouts;

const PulseAudio = @This();

const DeviceQueryError = error{
    OutOfMemory,
    IncompatibleBackend,
    InvalidFormat,
    InvalidChannelPos,
};

allocator: std.mem.Allocator,
main_loop: *c.pa_threaded_mainloop,
props: *c.pa_proplist,
pulse_context: *c.pa_context,
context_state: c.pa_context_state_t,
device_scan_queued: bool, // TODO make this atomic
devices_info: DevicesInfo,
device_query_err: ?DeviceQueryError,
default_sink_id: ?[:0]const u8,
default_source_id: ?[:0]const u8,

pub fn connect(allocator: std.mem.Allocator) !*PulseAudio {
    const main_loop = c.pa_threaded_mainloop_new() orelse
        return error.OutOfMemory;
    errdefer c.pa_threaded_mainloop_free(main_loop);
    var main_loop_api = c.pa_threaded_mainloop_get_api(main_loop);

    const props = c.pa_proplist_new() orelse
        return error.OutOfMemory;
    errdefer c.pa_proplist_free(props);

    const pulse_context = c.pa_context_new_with_proplist(main_loop_api, "SoundIO", props) orelse
        return error.OutOfMemory;
    errdefer c.pa_context_unref(pulse_context);

    if (c.pa_context_connect(pulse_context, null, 0, null) != 0)
        return switch (getError(pulse_context)) {
            error.InvalidServer => return error.InvalidServer,
            else => unreachable,
        };
    errdefer c.pa_context_disconnect(pulse_context);

    if (c.pa_threaded_mainloop_start(main_loop) != 0)
        return error.OutOfMemory;

    c.pa_threaded_mainloop_lock(main_loop);
    defer c.pa_threaded_mainloop_unlock(main_loop);

    var self = try allocator.create(PulseAudio);
    self.* = PulseAudio{
        .allocator = allocator,
        .main_loop = main_loop,
        .props = props,
        .pulse_context = pulse_context,
        .context_state = c.PA_CONTEXT_UNCONNECTED,
        .device_scan_queued = false,
        .devices_info = .{
            .outputs = .{},
            .inputs = .{},
            .default_output_index = 0,
            .default_input_index = 0,
        },
        .device_query_err = null,
        .default_sink_id = null,
        .default_source_id = null,
    };
    c.pa_context_set_subscribe_callback(pulse_context, subscribeCallback, self);
    c.pa_context_set_state_callback(pulse_context, contextStateCallback, self);

    while (true) {
        switch (self.context_state) {
            // The context hasn't been connected yet.
            c.PA_CONTEXT_UNCONNECTED,
            // A connection is being established.
            c.PA_CONTEXT_CONNECTING,
            // The client is authorizing itself to the daemon.
            c.PA_CONTEXT_AUTHORIZING,
            // The client is passing its application name to the daemon.
            c.PA_CONTEXT_SETTING_NAME,
            // The connection was terminated cleanly.
            c.PA_CONTEXT_TERMINATED,
            => c.pa_threaded_mainloop_wait(main_loop),
            // The connection is established, the context is ready to execute operations.
            c.PA_CONTEXT_READY => break,
            // The connection failed or was disconnected.
            c.PA_CONTEXT_FAILED => return error.Disconnected,

            else => unreachable,
        }
    }

    // subscribe to events
    const events = c.PA_SUBSCRIPTION_MASK_SINK | c.PA_SUBSCRIPTION_MASK_SOURCE | c.PA_SUBSCRIPTION_MASK_SERVER;
    const subscribe_op = c.pa_context_subscribe(pulse_context, events, null, self) orelse
        return error.OutOfMemory;
    c.pa_operation_unref(subscribe_op);

    return self;
}

pub fn deinit(self: *PulseAudio) void {
    c.pa_threaded_mainloop_stop(self.main_loop);
    c.pa_context_disconnect(self.pulse_context);
    c.pa_context_unref(self.pulse_context);
    c.pa_threaded_mainloop_free(self.main_loop);
    c.pa_proplist_free(self.props);
    for (self.devices_info.outputs.items) |device|
        deviceDeinit(device, self.allocator);
    for (self.devices_info.inputs.items) |device|
        deviceDeinit(device, self.allocator);
    self.devices_info.outputs.deinit(self.allocator);
    self.devices_info.inputs.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn flushEvents(self: *PulseAudio) !void {
    try self.refreshDevices();
}

pub fn waitEvents(self: *PulseAudio) !void {
    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);
    if (!self.device_scan_queued)
        c.pa_threaded_mainloop_wait(self.main_loop);
    try self.refreshDevices();
    self.device_scan_queued = false;
}

pub fn wakeUp(self: *PulseAudio) void {
    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

pub fn getDevice(self: PulseAudio, aim: Device.Aim, index: ?usize) Device {
    return switch (aim) {
        .output => self.devices_info.outputs.items[index orelse self.devices_info.default_output_index],
        .input => self.devices_info.inputs.items[index orelse self.devices_info.default_input_index],
    };
}

pub fn devicesList(self: PulseAudio, aim: Device.Aim) []const Device {
    return switch (aim) {
        .output => self.devices_info.outputs.items,
        .input => self.devices_info.inputs.items,
    };
}

pub const OutstreamData = struct {
    sipa: *const PulseAudio,
    stream: *c.pa_stream,
    buf_attr: c.pa_buffer_attr,
    stream_ready: std.atomic.Atomic(StreamStatus),
    clear_buffer: std.atomic.Atomic(bool),
    write_byte_count: usize,
    write_ptr: ?[*]u8,
    volume: f64,
};

const StreamStatus = enum(u8) {
    unknown,
    ready,
    failure,
};

pub fn outstreamOpen(self: *PulseAudio, outstream: *Outstream, device: Device) !void {
    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);

    outstream.backend_data = .{
        .pulseaudio = .{
            .sipa = self,
            .stream = undefined,
            .buf_attr = undefined,
            .stream_ready = std.atomic.Atomic(StreamStatus).init(.unknown),
            .clear_buffer = std.atomic.Atomic(bool).init(false),
            .write_byte_count = undefined,
            .write_ptr = null,
            .volume = undefined,
        },
    };
    var ospa = &outstream.backend_data.pulseaudio;

    const sample_spec = c.pa_sample_spec{
        .format = try toPAFormat(outstream.format),
        .rate = outstream.sample_rate,
        .channels = @intCast(u5, outstream.layout.channels.len),
    };
    const channel_map = try toPAChannelMap(outstream.layout);
    if (c.pa_stream_new(self.pulse_context, outstream.name.ptr, &sample_spec, &channel_map)) |s|
        ospa.stream = s
    else
        return error.OutOfMemory;
    c.pa_stream_set_state_callback(ospa.stream, playbackStreamStateCallback, ospa);
    ospa.buf_attr = .{
        .maxlength = std.math.maxInt(u32),
        .tlength = std.math.maxInt(u32),
        .prebuf = 0,
        .minreq = std.math.maxInt(u32),
        .fragsize = std.math.maxInt(u32),
    };
    const bytes_per_second = outstream.bytes_per_frame * outstream.sample_rate;
    if (outstream.software_latency > 0.0) {
        const buf_len = outstream.bytes_per_frame *
            @floatToInt(
            u32,
            std.math.ceil(outstream.software_latency * @intToFloat(f64, bytes_per_second) / @intToFloat(f64, outstream.bytes_per_frame)),
        );
        ospa.buf_attr.maxlength = buf_len;
        ospa.buf_attr.tlength = buf_len;
    }

    const flags = c.PA_STREAM_START_CORKED | c.PA_STREAM_AUTO_TIMING_UPDATE | c.PA_STREAM_INTERPOLATE_TIMING | c.PA_STREAM_ADJUST_LATENCY;
    if (c.pa_stream_connect_playback(ospa.stream, device.id.ptr, &ospa.buf_attr, flags, null, null) != 0)
        return switch (getError(self.pulse_context)) {
            else => unreachable,
        };

    while (true) {
        switch (ospa.stream_ready.loadUnchecked()) {
            .unknown => c.pa_threaded_mainloop_wait(self.main_loop),
            .ready => break,
            .failure => return error.StreamDisconnected,
        }
    }

    const writable_size = c.pa_stream_writable_size(ospa.stream);
    outstream.software_latency = @intToFloat(f64, writable_size) / @intToFloat(f64, bytes_per_second);

    try performOperation(self.main_loop, c.pa_stream_update_timing_info(ospa.stream, timingUpdateCallback, self));
}

pub fn outstreamDeinit(self: *Outstream) void {
    var ospa = &self.backend_data.pulseaudio;
    c.pa_threaded_mainloop_lock(ospa.sipa.main_loop);
    defer c.pa_threaded_mainloop_unlock(ospa.sipa.main_loop);
    c.pa_stream_set_write_callback(ospa.stream, null, null);
    c.pa_stream_set_state_callback(ospa.stream, null, null);
    c.pa_stream_set_underflow_callback(ospa.stream, null, null);
    c.pa_stream_set_overflow_callback(ospa.stream, null, null);
    _ = c.pa_stream_disconnect(ospa.stream);
    c.pa_stream_unref(ospa.stream);
}

pub fn outstreamStart(self: *Outstream) !void {
    var ospa = &self.backend_data.pulseaudio;
    c.pa_threaded_mainloop_lock(ospa.sipa.main_loop);
    defer c.pa_threaded_mainloop_unlock(ospa.sipa.main_loop);
    ospa.write_byte_count = c.pa_stream_writable_size(ospa.stream);
    const op = c.pa_stream_cork(ospa.stream, 0, null, null) orelse
        return error.StreamDisconnected;
    c.pa_operation_unref(op);
    c.pa_stream_set_write_callback(ospa.stream, playbackStreamWriteCallback, self);
    if (self.underflowFn) |_| {
        c.pa_stream_set_underflow_callback(ospa.stream, playbackStreamUnderflowCallback, self);
        c.pa_stream_set_overflow_callback(ospa.stream, playbackStreamUnderflowCallback, self);
    }
}

pub fn outstreamBeginWrite(self: *Outstream, frame_count: *usize) ![]const ChannelArea {
    var ospa = &self.backend_data.pulseaudio;
    var areas: [max_channels]ChannelArea = undefined;

    ospa.write_byte_count = frame_count.* * self.bytes_per_frame;
    if (c.pa_stream_begin_write(
        ospa.stream,
        @ptrCast(
            [*c]?*anyopaque,
            @alignCast(@alignOf([*c]?*anyopaque), &ospa.write_ptr),
        ),
        &ospa.write_byte_count,
    ) != 0)
        return switch (getError(ospa.sipa.pulse_context)) {
            else => unreachable,
        };

    for (self.layout.channels.constSlice()) |_, i| {
        areas[i].ptr = ospa.write_ptr.? + self.bytes_per_sample * i;
        areas[i].step = self.bytes_per_frame;
    }

    frame_count.* = ospa.write_byte_count / self.bytes_per_frame;
    return areas[0..self.layout.channels.len];
}

pub fn outstreamEndWrite(self: *Outstream) !void {
    var ospa = &self.backend_data.pulseaudio;
    const seek_mode: c_uint = if (ospa.clear_buffer.loadUnchecked()) c.PA_SEEK_RELATIVE_ON_READ else c.PA_SEEK_RELATIVE;
    if (c.pa_stream_write(ospa.stream, &ospa.write_ptr.?[0], ospa.write_byte_count, null, 0, seek_mode) != 0)
        return error.StreamDisconnected;
}

pub fn outstreamClearBuffer(self: *Outstream) void {
    self.backend_data.pulseaudio.clear_buffer.storeUnchecked(true);
}

pub fn outstreamPausePlay(self: *Outstream, pause: bool) !void {
    var ospa = &self.backend_data.pulseaudio;

    if (c.pa_threaded_mainloop_in_thread(ospa.sipa.main_loop) == 0)
        c.pa_threaded_mainloop_lock(ospa.sipa.main_loop);
    defer if (c.pa_threaded_mainloop_in_thread(ospa.sipa.main_loop) == 0)
        c.pa_threaded_mainloop_unlock(ospa.sipa.main_loop);

    if (pause != (c.pa_stream_is_corked(ospa.stream) != 0)) {
        const op = c.pa_stream_cork(ospa.stream, @bitCast(c_int, pause), null, null) orelse
            return error.StreamDisconnected;
        c.pa_operation_unref(op);
    }
}

pub fn outstreamGetLatency(self: *Outstream) !f64 {
    var r_usec: c.pa_usec_t = 0;
    var negative: c_int = 0;
    if (c.pa_stream_get_latency(self.backend_data.pulseaudio.stream, &r_usec, &negative) != 0)
        return switch (getError(self.pulse_context)) {
            // Timing info is automatically updated
            error.NoData => unreachable,
            else => unreachable,
        };
    return @intToFloat(f64, r_usec) / 1000000.0;
}

pub fn outstreamSetVolume(self: *Outstream, volume: f64) !void {
    var ospa = &self.backend_data.pulseaudio;
    var v: c.pa_cvolume = undefined;
    _ = c.pa_cvolume_init(&v);
    v.channels = @intCast(u5, self.layout.channels.len);
    const vol = @floatToInt(u32, @intToFloat(f64, c.PA_VOLUME_NORM) * volume);
    for (self.layout.channels.constSlice()) |_, i|
        v.values[i] = vol;
    const op = c.pa_context_set_sink_input_volume(
        ospa.sipa.pulse_context,
        c.pa_stream_get_index(ospa.stream),
        &v,
        null,
        null,
    ) orelse
        return error.StreamDisconnected;
    c.pa_operation_unref(op);
}

pub fn outstreamVolume(self: *Outstream) !f64 {
    var ospa = &self.backend_data.pulseaudio;
    try performOperation(
        ospa.sipa.main_loop,
        c.pa_context_get_sink_input_info(
            ospa.sipa.pulse_context,
            c.pa_stream_get_index(ospa.stream),
            sinkInputInfoCallback,
            ospa,
        ),
    );
    return ospa.volume;
}

pub fn deviceDeinit(self: Device, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.name);
}

fn sinkInputInfoCallback(_: ?*c.pa_context, info: [*c]const c.pa_sink_input_info, eol: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var ospa = @ptrCast(*OutstreamData, @alignCast(@alignOf(*OutstreamData), userdata.?));
    if (eol != 0) {
        c.pa_threaded_mainloop_signal(ospa.sipa.main_loop, 0);
        return;
    }
    ospa.volume = @intToFloat(f64, info.*.volume.values[0]) / @intToFloat(f64, c.PA_VOLUME_NORM);
}

fn playbackStreamWriteCallback(_: ?*c.pa_stream, nbytes: usize, userdata: ?*anyopaque) callconv(.C) void {
    var outstream = @ptrCast(*Outstream, @alignCast(@alignOf(*Outstream), userdata.?));
    const frame_count = nbytes / outstream.bytes_per_frame;
    outstream.writeFn(outstream, 0, frame_count);
}

fn playbackStreamUnderflowCallback(_: ?*c.pa_stream, userdata: ?*anyopaque) callconv(.C) void {
    var outstream = @ptrCast(*Outstream, @alignCast(@alignOf(*Outstream), userdata.?));
    outstream.underflowFn.?(outstream);
}

fn playbackStreamStateCallback(stream: ?*c.pa_stream, userdata: ?*anyopaque) callconv(.C) void {
    var ospa = @ptrCast(*OutstreamData, @alignCast(@alignOf(*OutstreamData), userdata.?));
    switch (c.pa_stream_get_state(stream)) {
        c.PA_STREAM_UNCONNECTED, c.PA_STREAM_CREATING, c.PA_STREAM_TERMINATED => {},
        c.PA_STREAM_READY => {
            ospa.stream_ready.storeUnchecked(.ready);
            c.pa_threaded_mainloop_signal(ospa.sipa.main_loop, 0);
        },
        c.PA_STREAM_FAILED => {
            ospa.stream_ready.storeUnchecked(.failure);
            c.pa_threaded_mainloop_signal(ospa.sipa.main_loop, 0);
        },
        else => unreachable,
    }
}

fn timingUpdateCallback(_: ?*c.pa_stream, _: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

fn refreshDevices(self: *PulseAudio) !void {
    const list_sink_op = c.pa_context_get_sink_info_list(self.pulse_context, sinkInfoCallback, self);
    const list_source_op = c.pa_context_get_source_info_list(self.pulse_context, sourceInfoCallback, self);
    const server_info_op = c.pa_context_get_server_info(self.pulse_context, serverInfoCallback, self);

    for (self.devices_info.outputs.items) |device|
        device.deinit(self.allocator);
    for (self.devices_info.inputs.items) |device|
        device.deinit(self.allocator);
    self.devices_info.outputs.clearAndFree(self.allocator);
    self.devices_info.inputs.clearAndFree(self.allocator);
    try performOperation(self.main_loop, list_sink_op);
    try performOperation(self.main_loop, list_source_op);
    try performOperation(self.main_loop, server_info_op);
    if (self.device_query_err) |err| return err;
    defer {
        if (self.default_sink_id) |id| {
            self.allocator.free(id);
            self.default_sink_id = null;
        }
        if (self.default_source_id) |id| {
            self.allocator.free(id);
            self.default_source_id = null;
        }
    }

    if (self.devices_info.outputs.items.len > 0) {
        self.devices_info.default_output_index = 0;
        for (self.devices_info.outputs.items) |device, i| {
            if (std.mem.eql(u8, device.id, self.default_sink_id orelse break)) {
                self.devices_info.default_output_index = i;
                break;
            }
        }
    }

    if (self.devices_info.inputs.items.len > 0) {
        self.devices_info.default_input_index = 0;
        for (self.devices_info.inputs.items) |device, i| {
            if (std.mem.eql(u8, device.id, self.default_sink_id orelse break)) {
                self.devices_info.default_input_index = i;
                break;
            }
        }
    }
}

fn performOperation(main_loop: *c.pa_threaded_mainloop, op: ?*c.pa_operation) !void {
    if (op == null) return error.OutOfMemory;
    while (true) {
        switch (c.pa_operation_get_state(op)) {
            c.PA_OPERATION_RUNNING => c.pa_threaded_mainloop_wait(main_loop),
            c.PA_OPERATION_DONE => return c.pa_operation_unref(op),
            c.PA_OPERATION_CANCELLED => {
                c.pa_operation_unref(op);
                return error.Interrupted;
            },
            else => unreachable,
        }
    }
}

fn subscribeCallback(_: ?*c.pa_context, _: c.pa_subscription_event_type_t, _: u32, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    self.device_scan_queued = true;
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

fn contextStateCallback(ctx: ?*c.pa_context, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    self.context_state = c.pa_context_get_state(ctx);
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

fn sinkInfoCallback(_: ?*c.pa_context, info: [*c]const c.pa_sink_info, eol: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    if (eol != 0) {
        c.pa_threaded_mainloop_signal(self.main_loop, 0);
        return;
    }
    if (self.device_query_err != null) return;
    if (info.*.name == null or info.*.description == null) self.device_query_err = error.OutOfMemory;
    var device = Device{
        .id = self.allocator.dupeZ(u8, std.mem.span(info.*.name)) catch |err| {
            self.device_query_err = err;
            return;
        },
        .name = self.allocator.dupeZ(u8, std.mem.span(info.*.description)) catch |err| {
            self.device_query_err = err;
            return;
        },
        .aim = .output,
        .is_raw = false,
        .layout = fromPAChannelMap(info.*.channel_map) catch |err| {
            self.device_query_err = err;
            return;
        },
        .formats = allDeviceFormats(),
        .current_format = fromPAFormat(info.*.sample_spec.format) catch |err| {
            self.device_query_err = err;
            return;
        },
        .sample_rate_range = .{
            .min = std.math.clamp(info.*.sample_spec.rate, min_sample_rate, max_sample_rate),
            .max = std.math.clamp(info.*.sample_spec.rate, min_sample_rate, max_sample_rate),
        },
        .current_sample_rate = info.*.sample_spec.rate,
        .current_software_latency = null,
        .software_latency_min = null,
        .software_latency_max = null,
    };

    self.devices_info.outputs.append(self.allocator, device) catch |err| {
        self.device_query_err = err;
        return;
    };
}

fn sourceInfoCallback(_: ?*c.pa_context, info: [*c]const c.pa_source_info, eol: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    if (eol != 0) {
        c.pa_threaded_mainloop_signal(self.main_loop, 0);
        return;
    }
    if (self.device_query_err != null) return;
    if (info.*.name == null or info.*.description == null) self.device_query_err = error.OutOfMemory;
    var device = Device{
        .id = self.allocator.dupeZ(u8, std.mem.span(info.*.name)) catch |err| {
            self.device_query_err = err;
            return;
        },
        .name = self.allocator.dupeZ(u8, std.mem.span(info.*.description)) catch |err| {
            self.device_query_err = err;
            return;
        },
        .aim = .input,
        .is_raw = false,
        .layout = fromPAChannelMap(info.*.channel_map) catch |err| {
            self.device_query_err = err;
            return;
        },
        .formats = allDeviceFormats(),
        .current_format = fromPAFormat(info.*.sample_spec.format) catch |err| {
            self.device_query_err = err;
            return;
        },
        .sample_rate_range = .{
            .min = std.math.clamp(info.*.sample_spec.rate, min_sample_rate, max_sample_rate),
            .max = std.math.clamp(info.*.sample_spec.rate, min_sample_rate, max_sample_rate),
        },
        .current_sample_rate = info.*.sample_spec.rate,
        .current_software_latency = null,
        .software_latency_min = null,
        .software_latency_max = null,
    };

    self.devices_info.inputs.append(self.allocator, device) catch |err| {
        self.device_query_err = err;
        return;
    };
}

fn serverInfoCallback(_: ?*c.pa_context, info: [*c]const c.pa_server_info, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    defer c.pa_threaded_mainloop_signal(self.main_loop, 0);
    self.default_sink_id = self.allocator.dupeZ(u8, std.mem.span(info.*.default_sink_name)) catch |err| {
        self.device_query_err = err;
        return;
    };
    self.default_source_id = self.allocator.dupeZ(u8, std.mem.span(info.*.default_source_name)) catch |err| {
        self.device_query_err = err;
        return;
    };
}

fn fromPAChannelMap(map: c.pa_channel_map) !ChannelLayout {
    var channels = ChannelLayout.Array.init(map.channels) catch return error.IncompatibleBackend;
    for (channels.slice()) |*ch, i|
        ch.* = try fromPAChannelPos(map.map[i]);
    var layout = ChannelLayout{
        .name = null,
        .channels = channels,
    };
    for (builtin_channel_layouts) |bl| {
        if (bl.eql(layout)) {
            layout.name = bl.name;
            break;
        }
    }
    return layout;
}

fn fromPAChannelPos(pos: c.pa_channel_position_t) !ChannelId {
    return switch (pos) {
        c.PA_CHANNEL_POSITION_MONO => .front_center,
        c.PA_CHANNEL_POSITION_FRONT_LEFT => .front_left,
        c.PA_CHANNEL_POSITION_FRONT_RIGHT => .front_right,
        c.PA_CHANNEL_POSITION_FRONT_CENTER => .front_center,
        c.PA_CHANNEL_POSITION_REAR_CENTER => .back_center,
        c.PA_CHANNEL_POSITION_REAR_LEFT => .back_left,
        c.PA_CHANNEL_POSITION_REAR_RIGHT => .back_right,
        c.PA_CHANNEL_POSITION_LFE => .lfe,
        c.PA_CHANNEL_POSITION_FRONT_LEFT_OF_CENTER => .front_left_center,
        c.PA_CHANNEL_POSITION_FRONT_RIGHT_OF_CENTER => .front_right_center,
        c.PA_CHANNEL_POSITION_SIDE_LEFT => .side_left,
        c.PA_CHANNEL_POSITION_SIDE_RIGHT => .side_right,
        c.PA_CHANNEL_POSITION_TOP_CENTER => .top_center,
        c.PA_CHANNEL_POSITION_TOP_FRONT_LEFT => .top_front_left,
        c.PA_CHANNEL_POSITION_TOP_FRONT_RIGHT => .top_front_right,
        c.PA_CHANNEL_POSITION_TOP_FRONT_CENTER => .top_front_center,
        c.PA_CHANNEL_POSITION_TOP_REAR_LEFT => .top_back_left,
        c.PA_CHANNEL_POSITION_TOP_REAR_RIGHT => .top_back_right,
        c.PA_CHANNEL_POSITION_TOP_REAR_CENTER => .top_back_center,

        c.PA_CHANNEL_POSITION_AUX0 => .aux0,
        c.PA_CHANNEL_POSITION_AUX1 => .aux1,
        c.PA_CHANNEL_POSITION_AUX2 => .aux2,
        c.PA_CHANNEL_POSITION_AUX3 => .aux3,
        c.PA_CHANNEL_POSITION_AUX4 => .aux4,
        c.PA_CHANNEL_POSITION_AUX5 => .aux5,
        c.PA_CHANNEL_POSITION_AUX6 => .aux6,
        c.PA_CHANNEL_POSITION_AUX7 => .aux7,
        c.PA_CHANNEL_POSITION_AUX8 => .aux8,
        c.PA_CHANNEL_POSITION_AUX9 => .aux9,
        c.PA_CHANNEL_POSITION_AUX10 => .aux10,
        c.PA_CHANNEL_POSITION_AUX11 => .aux11,
        c.PA_CHANNEL_POSITION_AUX12 => .aux12,
        c.PA_CHANNEL_POSITION_AUX13 => .aux13,
        c.PA_CHANNEL_POSITION_AUX14 => .aux14,
        c.PA_CHANNEL_POSITION_AUX15 => .aux15,

        else => error.InvalidChannelPos,
    };
}

fn fromPAFormat(format: c.pa_sample_format_t) !Format {
    return switch (format) {
        c.PA_SAMPLE_U8 => .u8,
        c.PA_SAMPLE_S16LE => .s16le,
        c.PA_SAMPLE_S16BE => .s16be,
        c.PA_SAMPLE_FLOAT32LE => .float32le,
        c.PA_SAMPLE_FLOAT32BE => .float32be,
        c.PA_SAMPLE_S32LE => .s32le,
        c.PA_SAMPLE_S32BE => .s32be,
        c.PA_SAMPLE_S24_32LE => .s24le,
        c.PA_SAMPLE_S24_32BE => .s24be,

        c.PA_SAMPLE_MAX,
        c.PA_SAMPLE_INVALID,
        c.PA_SAMPLE_ALAW,
        c.PA_SAMPLE_ULAW,
        c.PA_SAMPLE_S24LE,
        c.PA_SAMPLE_S24BE,
        => error.InvalidFormat,

        else => unreachable,
    };
}

pub fn toPAFormat(format: Format) !c.pa_sample_format_t {
    return switch (format) {
        .u8 => c.PA_SAMPLE_U8,
        .s16le => c.PA_SAMPLE_S16LE,
        .s24le => c.PA_SAMPLE_S24_32LE,
        .s32le => c.PA_SAMPLE_S32LE,
        .float32le => c.PA_SAMPLE_FLOAT32LE,
        .s16be => c.PA_SAMPLE_S16BE,
        .s24be => c.PA_SAMPLE_S24_32BE,
        .s32be => c.PA_SAMPLE_S32BE,
        .float32be => c.PA_SAMPLE_FLOAT32BE,
        .s8,
        .u16le,
        .u16be,
        .u24le,
        .u24be,
        .u32le,
        .u32be,
        .float64le,
        .float64be,
        => error.IncompatibleBackend,
    };
}

fn toPAChannelPos(channel_id: ChannelId) !c.pa_channel_position_t {
    return switch (channel_id) {
        .front_left => c.PA_CHANNEL_POSITION_FRONT_LEFT,
        .front_right => c.PA_CHANNEL_POSITION_FRONT_RIGHT,
        .front_center => c.PA_CHANNEL_POSITION_FRONT_CENTER,
        .lfe => c.PA_CHANNEL_POSITION_LFE,
        .back_left => c.PA_CHANNEL_POSITION_REAR_LEFT,
        .back_right => c.PA_CHANNEL_POSITION_REAR_RIGHT,
        .front_left_center => c.PA_CHANNEL_POSITION_FRONT_LEFT_OF_CENTER,
        .front_right_center => c.PA_CHANNEL_POSITION_FRONT_RIGHT_OF_CENTER,
        .back_center => c.PA_CHANNEL_POSITION_REAR_CENTER,
        .side_left => c.PA_CHANNEL_POSITION_SIDE_LEFT,
        .side_right => c.PA_CHANNEL_POSITION_SIDE_RIGHT,
        .top_center => c.PA_CHANNEL_POSITION_TOP_CENTER,
        .top_front_left => c.PA_CHANNEL_POSITION_TOP_FRONT_LEFT,
        .top_front_center => c.PA_CHANNEL_POSITION_TOP_FRONT_CENTER,
        .top_front_right => c.PA_CHANNEL_POSITION_TOP_FRONT_RIGHT,
        .top_back_left => c.PA_CHANNEL_POSITION_TOP_REAR_LEFT,
        .top_back_center => c.PA_CHANNEL_POSITION_TOP_REAR_CENTER,
        .top_back_right => c.PA_CHANNEL_POSITION_TOP_REAR_RIGHT,

        .aux0 => c.PA_CHANNEL_POSITION_AUX0,
        .aux1 => c.PA_CHANNEL_POSITION_AUX1,
        .aux2 => c.PA_CHANNEL_POSITION_AUX2,
        .aux3 => c.PA_CHANNEL_POSITION_AUX3,
        .aux4 => c.PA_CHANNEL_POSITION_AUX4,
        .aux5 => c.PA_CHANNEL_POSITION_AUX5,
        .aux6 => c.PA_CHANNEL_POSITION_AUX6,
        .aux7 => c.PA_CHANNEL_POSITION_AUX7,
        .aux8 => c.PA_CHANNEL_POSITION_AUX8,
        .aux9 => c.PA_CHANNEL_POSITION_AUX9,
        .aux10 => c.PA_CHANNEL_POSITION_AUX10,
        .aux11 => c.PA_CHANNEL_POSITION_AUX11,
        .aux12 => c.PA_CHANNEL_POSITION_AUX12,
        .aux13 => c.PA_CHANNEL_POSITION_AUX13,
        .aux14 => c.PA_CHANNEL_POSITION_AUX14,
        .aux15 => c.PA_CHANNEL_POSITION_AUX15,

        else => error.IncompatibleBackend,
    };
}

fn toPAChannelMap(layout: ChannelLayout) !c.pa_channel_map {
    var channel_map: c.pa_channel_map = undefined;
    channel_map.channels = @intCast(u5, layout.channels.len);
    for (layout.channels.slice()) |ch, i|
        channel_map.map[i] = try toPAChannelPos(ch);
    return channel_map;
}

fn allDeviceFormats() []const Format {
    return &[_]Format{
        .u8,    .s16le,     .s16be,
        .s24le, .s24be,     .s32le,
        .s32be, .float32le, .float32be,
    };
}

// based on pulseaudio v16.0
const RawError = error{
    AccessFailure,
    // UnknownCommand,
    // InvalidArgument,
    EntityExists,
    NoSuchEntity,
    ConnectionRefused,
    ProtocolError,
    Timeout,
    NoAuthenticationKey,
    InternalError,
    ConnectionTerminated,
    EntityKilled,
    InvalidServer,
    ModuleInitializationFailed,
    // BadState,
    NoData,
    IncompatibleProtocolVersion,
    DataTooLarge,
    OperationNotSupported,
    Unknown,
    NoExtension,
    // Obsolete,
    NotImplemented,
    // Forked,
    InputOutput,
    BusyResource,
};
fn getError(ctx: *c.pa_context) RawError {
    return switch (c.pa_context_errno(ctx)) {
        c.PA_OK => unreachable,
        c.PA_ERR_ACCESS => error.AccessFailure,
        c.PA_ERR_COMMAND => unreachable, // Unexpected
        c.PA_ERR_INVALID => unreachable, // Unexpected
        c.PA_ERR_EXIST => error.EntityExists,
        c.PA_ERR_NOENTITY => error.NoSuchEntity,
        c.PA_ERR_CONNECTIONREFUSED => error.ConnectionRefused,
        c.PA_ERR_PROTOCOL => error.ProtocolError,
        c.PA_ERR_TIMEOUT => error.Timeout,
        c.PA_ERR_AUTHKEY => error.NoAuthenticationKey,
        c.PA_ERR_INTERNAL => error.InternalError,
        c.PA_ERR_CONNECTIONTERMINATED => error.ConnectionTerminated,
        c.PA_ERR_KILLED => error.EntityKilled,
        c.PA_ERR_INVALIDSERVER => error.InvalidServer,
        c.PA_ERR_MODINITFAILED => error.ModuleInitializationFailed,
        c.PA_ERR_BADSTATE => unreachable, // Unexpected
        c.PA_ERR_NODATA => error.NoData,
        c.PA_ERR_VERSION => error.IncompatibleProtocolVersion,
        c.PA_ERR_TOOLARGE => error.DataTooLarge,
        c.PA_ERR_NOTSUPPORTED => error.OperationNotSupported,
        c.PA_ERR_UNKNOWN => error.Unknown,
        c.PA_ERR_NOEXTENSION => error.NoExtension,
        c.PA_ERR_OBSOLETE => unreachable, // Unexpected
        c.PA_ERR_NOTIMPLEMENTED => error.NotImplemented,
        c.PA_ERR_FORKED => unreachable, // Unexpected
        c.PA_ERR_IO => error.InputOutput,
        c.PA_ERR_BUSY => error.BusyResource,
        else => unreachable, // Unexpected
    };
}
