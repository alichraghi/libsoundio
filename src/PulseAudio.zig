const builtin = @import("builtin");
const std = @import("std");
const c = @cImport(@cInclude("pulse/pulseaudio.h"));
const DevicesInfo = @import("main.zig").DevicesInfo;
const Device = @import("main.zig").Device;
const SampleRateRange = @import("main.zig").SampleRateRange;
const Format = @import("main.zig").Format;
const ChannelLayout = @import("main.zig").ChannelLayout;
const ChannelId = @import("main.zig").ChannelId;
const Outstream = @import("main.zig").Outstream;
const min_sample_rate = @import("main.zig").min_sample_rate;
const max_sample_rate = @import("main.zig").max_sample_rate;
const builtin_channel_layouts = @import("channel_layout.zig").builtin_channel_layouts;

const PulseAudio = @This();

allocator: std.mem.Allocator,
main_loop: *c.pa_threaded_mainloop,
props: *c.pa_proplist,
pulse_context: *c.pa_context,
context_state: c.pa_context_state_t,
device_scan_queued: bool,
devices_info: DevicesInfo,
device_query_err: ?DeviceQueryError,
default_sink_id: ?[:0]const u8,
default_source_id: ?[:0]const u8,

const DeviceQueryError = error{
    OutOfMemory,
    IncompatibleBackend,
    InvalidFormat,
    InvalidChannelPos,
};

const StreamReadyError = error{
    StreamDisconnected,
};

pub const ConnectError = error{
    OutOfMemory,
    Disconnected,
    InitAudioBackend,
};
pub fn connect(allocator: std.mem.Allocator) ConnectError!*PulseAudio {
    var self = try allocator.create(PulseAudio);
    self.allocator = allocator;
    self.main_loop = c.pa_threaded_mainloop_new() orelse return error.OutOfMemory;
    errdefer c.pa_threaded_mainloop_free(self.main_loop);
    var main_loop_api = c.pa_threaded_mainloop_get_api(self.main_loop);

    self.props = c.pa_proplist_new() orelse return error.OutOfMemory;
    errdefer c.pa_proplist_free(self.props);

    self.pulse_context = c.pa_context_new_with_proplist(main_loop_api, "SoundIO", self.props) orelse return error.OutOfMemory;
    errdefer c.pa_context_unref(self.pulse_context);

    self.context_state = c.PA_CONTEXT_UNCONNECTED;
    self.device_scan_queued = false;
    self.devices_info = .{
        .outputs = .{},
        .inputs = .{},
        .default_output_index = 0,
        .default_input_index = 0,
    };
    self.device_query_err = null;
    self.default_sink_id = null;
    self.default_source_id = null;

    c.pa_context_set_subscribe_callback(self.pulse_context, subscribeCallback, self);
    c.pa_context_set_state_callback(self.pulse_context, contextStateCallback, self);

    if (c.pa_context_connect(self.pulse_context, null, 0, null) != 0) return error.InitAudioBackend;
    errdefer c.pa_context_disconnect(self.pulse_context);

    if (c.pa_threaded_mainloop_start(self.main_loop) > 0)
        return error.OutOfMemory;

    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);

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
            => c.pa_threaded_mainloop_wait(self.main_loop),
            // The connection is established, the context is ready to execute operations.
            c.PA_CONTEXT_READY => break,
            // The connection failed or was disconnected.
            c.PA_CONTEXT_FAILED => return error.Disconnected,

            else => unreachable,
        }
    }

    // subscribe to events
    const events = c.PA_SUBSCRIPTION_MASK_SINK | c.PA_SUBSCRIPTION_MASK_SOURCE | c.PA_SUBSCRIPTION_MASK_SERVER;
    const subscribe_op = c.pa_context_subscribe(self.pulse_context, events, null, self) orelse return error.OutOfMemory;
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
        clearDevice(device, self.allocator);
    for (self.devices_info.inputs.items) |device|
        clearDevice(device, self.allocator);
    self.devices_info.outputs.deinit(self.allocator);
    self.devices_info.inputs.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn flushEvents(self: *PulseAudio) RefreshDevicesError!void {
    try self.refreshDevices();
}

pub fn waitEvents(self: *PulseAudio) RefreshDevicesError!void {
    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);
    if (!self.device_scan_queued)
        c.pa_threaded_mainloop_wait(self.main_loop);
    try self.refreshDevices();
    self.device_scan_queued = false;
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
    stream_ready: std.atomic.Atomic(bool),
    clear_buffer: std.atomic.Atomic(bool),
    stream_ready_err: ?StreamReadyError,
};
pub fn openOutstream(self: *PulseAudio, outstream: *Outstream, device: Device) !void {
    if (outstream.layout.channels.len > c.PA_CHANNELS_MAX)
        return error.IncompatibleBackend;

    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);

    outstream.backend_data = .{ .pulseaudio = .{
        .sipa = self,
        .stream = undefined,
        .buf_attr = undefined,
        .stream_ready = std.atomic.Atomic(bool).init(false),
        .clear_buffer = std.atomic.Atomic(bool).init(true),
        .stream_ready_err = null,
    } };
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
            @floatToInt(u32, std.math.ceil(outstream.software_latency * @intToFloat(f64, bytes_per_second) / @intToFloat(f64, outstream.bytes_per_frame)));
        ospa.buf_attr.maxlength = buf_len;
        ospa.buf_attr.tlength = buf_len;
    }

    const flags = c.PA_STREAM_START_CORKED | c.PA_STREAM_AUTO_TIMING_UPDATE | c.PA_STREAM_INTERPOLATE_TIMING | c.PA_STREAM_ADJUST_LATENCY;
    if (c.pa_stream_connect_playback(ospa.stream, device.id.ptr, &ospa.buf_attr, flags, null, null) != 0)
        return error.OpeningDevice;

    while (!ospa.stream_ready.loadUnchecked())
        c.pa_threaded_mainloop_wait(self.main_loop);
    if (ospa.stream_ready_err) |err|
        return err;

    const writable_size = c.pa_stream_writable_size(ospa.stream);
    outstream.software_latency = @intToFloat(f64, writable_size) / @intToFloat(f64, bytes_per_second);

    try performOperation(self.main_loop, c.pa_stream_update_timing_info(ospa.stream, timingUpdateCallback, self));
}

pub fn clearDevice(self: Device, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.name);
}

fn playbackStreamStateCallback(stream: ?*c.pa_stream, userdata: ?*anyopaque) callconv(.C) void {
    var ospa = @ptrCast(*OutstreamData, @alignCast(@alignOf(*OutstreamData), userdata.?));
    switch (c.pa_stream_get_state(stream)) {
        c.PA_STREAM_UNCONNECTED, c.PA_STREAM_CREATING, c.PA_STREAM_TERMINATED => {},
        c.PA_STREAM_READY => {
            ospa.stream_ready.storeUnchecked(true);
            c.pa_threaded_mainloop_signal(ospa.sipa.main_loop, 0);
        },
        c.PA_STREAM_FAILED => {
            ospa.stream_ready_err = error.StreamDisconnected;
            c.pa_threaded_mainloop_signal(ospa.sipa.main_loop, 0);
        },
        else => unreachable,
    }
}

fn timingUpdateCallback(_: ?*c.pa_stream, _: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

const RefreshDevicesError = error{
    OutOfMemory,
    Interrupted,
    IncompatibleBackend,
    InvalidFormat,
    InvalidChannelPos,
};
fn refreshDevices(self: *PulseAudio) RefreshDevicesError!void {
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

const OperationError = error{ OutOfMemory, Interrupted };
fn performOperation(main_loop: *c.pa_threaded_mainloop, op: ?*c.pa_operation) OperationError!void {
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
        .sample_rates = &[_]SampleRateRange{.{
            .min = std.math.min(min_sample_rate, info.*.sample_spec.rate),
            .max = std.math.max(max_sample_rate, info.*.sample_spec.rate),
        }},
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
        .sample_rates = &[_]SampleRateRange{.{
            .min = std.math.min(min_sample_rate, info.*.sample_spec.rate),
            .max = std.math.max(max_sample_rate, info.*.sample_spec.rate),
        }},
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

fn fromPAChannelMap(map: c.pa_channel_map) error{ IncompatibleBackend, InvalidChannelPos }!ChannelLayout {
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

fn fromPAChannelPos(pos: c.pa_channel_position_t) error{InvalidChannelPos}!ChannelId {
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

fn fromPAFormat(format: c.pa_sample_format_t) error{InvalidFormat}!Format {
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

pub fn toPAFormat(format: Format) error{IncompatibleBackend}!c.pa_sample_format_t {
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

fn toPAChannelPos(channel_id: ChannelId) error{IncompatibleBackend}!c.pa_channel_position_t {
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

fn toPAChannelMap(layout: ChannelLayout) error{IncompatibleBackend}!c.pa_channel_map {
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
