const std = @import("std");
const c = @import("Pulseaudio/c.zig");
const pulse_util = @import("Pulseaudio/util.zig");
const DevicesInfo = @import("main.zig").DevicesInfo;
const Device = @import("main.zig").Device;
const Format = @import("main.zig").Format;
const ChannelId = @import("main.zig").ChannelId;
const ChannelsArray = @import("main.zig").ChannelsArray;
const Player = @import("main.zig").Player;
const min_sample_rate = @import("main.zig").min_sample_rate;
const max_sample_rate = @import("main.zig").max_sample_rate;

const PulseAudio = @This();

const DeviceQueryError = error{
    OutOfMemory,
    IncompatibleBackend,
    InvalidFormat,
};

allocator: std.mem.Allocator,
main_loop: *c.pa_threaded_mainloop,
pulse_context: *c.pa_context,
context_state: c.pa_context_state_t,
devices_info: DevicesInfo,
device_scan_queued: std.atomic.Atomic(bool),
device_query_err: ?DeviceQueryError,
default_sink_id: ?[:0]const u8,
default_source_id: ?[:0]const u8,

pub fn connect(allocator: std.mem.Allocator) !*PulseAudio {
    const main_loop = c.pa_threaded_mainloop_new() orelse
        return error.OutOfMemory;
    errdefer c.pa_threaded_mainloop_free(main_loop);
    var main_loop_api = c.pa_threaded_mainloop_get_api(main_loop);

    const pulse_context = c.pa_context_new_with_proplist(main_loop_api, "SoundIO", null) orelse
        return error.OutOfMemory;
    errdefer c.pa_context_unref(pulse_context);

    if (c.pa_context_connect(pulse_context, null, 0, null) != 0)
        return switch (pulse_util.getError(pulse_context)) {
            error.InvalidServer => error.InvalidServer,
            error.ConnectionRefused => error.ConnectionRefused,
            error.ConnectionTerminated => error.ConnectionTerminated,
            else => error.ConnectionRefused,
        };
    errdefer c.pa_context_disconnect(pulse_context);

    if (c.pa_threaded_mainloop_start(main_loop) != 0)
        return error.OutOfMemory;
    errdefer {
        c.pa_threaded_mainloop_stop(main_loop);
        c.pa_threaded_mainloop_free(main_loop);
    }

    c.pa_threaded_mainloop_lock(main_loop);
    defer c.pa_threaded_mainloop_unlock(main_loop);

    var self = try allocator.create(PulseAudio);
    errdefer allocator.destroy(self);
    self.* = PulseAudio{
        .allocator = allocator,
        .main_loop = main_loop,
        .pulse_context = pulse_context,
        .context_state = c.PA_CONTEXT_UNCONNECTED,
        .devices_info = DevicesInfo.init(),
        .device_scan_queued = std.atomic.Atomic(bool).init(false),
        .device_query_err = null,
        .default_sink_id = null,
        .default_source_id = null,
    };
    c.pa_context_set_subscribe_callback(pulse_context, subscribeCb, self);
    c.pa_context_set_state_callback(pulse_context, contextStateCb, self);

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
    c.pa_context_disconnect(self.pulse_context);
    c.pa_context_unref(self.pulse_context);
    c.pa_threaded_mainloop_stop(self.main_loop);
    c.pa_threaded_mainloop_free(self.main_loop);
    self.devices_info.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn flushEvents(self: *PulseAudio) !void {
    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);
    try self.refreshDevices();
}

pub fn waitEvents(self: *PulseAudio) !void {
    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);
    while (!self.device_scan_queued.load(.Acquire))
        c.pa_threaded_mainloop_wait(self.main_loop);
    self.device_scan_queued.store(false, .Release);
    try self.refreshDevices();
}

pub fn wakeUp(self: *PulseAudio) void {
    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);
    self.device_scan_queued.store(true, .Release);
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

pub const PlayerData = struct {
    pa: *const PulseAudio,
    stream: *c.pa_stream,
    buf_attr: c.pa_buffer_attr,
    stream_ready: std.atomic.Atomic(StreamStatus),
    write_ptr: [*]u8,
    volume: f64,
};

const StreamStatus = enum(u8) {
    unknown,
    ready,
    failure,
};

pub fn openPlayer(self: *PulseAudio, player: *Player, device: Device) !void {
    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);
    player.backend_data = .{
        .PulseAudio = .{
            .pa = self,
            .stream = undefined,
            .buf_attr = undefined,
            .stream_ready = std.atomic.Atomic(StreamStatus).init(.unknown),
            .write_ptr = undefined,
            .volume = undefined,
        },
    };
    var bd = &player.backend_data.PulseAudio;

    const sample_spec = c.pa_sample_spec{
        .format = try pulse_util.toPAFormat(player.format),
        .rate = player.sample_rate,
        .channels = @intCast(u5, player.channels.len),
    };
    const channel_map = try pulse_util.toPAChannelMap(player.channels);
    if (c.pa_stream_new(self.pulse_context, player.name.ptr, &sample_spec, &channel_map)) |s|
        bd.stream = s
    else
        return error.OutOfMemory;
    c.pa_stream_set_state_callback(bd.stream, playbackStreamStateCb, bd);
    bd.buf_attr = .{
        .maxlength = std.math.maxInt(u32),
        .tlength = std.math.maxInt(u32),
        .prebuf = 0,
        .minreq = std.math.maxInt(u32),
        .fragsize = std.math.maxInt(u32),
    };

    const flags = c.PA_STREAM_START_CORKED | c.PA_STREAM_AUTO_TIMING_UPDATE | c.PA_STREAM_INTERPOLATE_TIMING | c.PA_STREAM_ADJUST_LATENCY;
    if (c.pa_stream_connect_playback(bd.stream, device.id.ptr, &bd.buf_attr, flags, null, null) != 0)
        return switch (pulse_util.getError(self.pulse_context)) {
            else => error.OpeningDevice,
        };

    while (true) {
        switch (bd.stream_ready.loadUnchecked()) {
            .unknown => c.pa_threaded_mainloop_wait(self.main_loop),
            .ready => break,
            .failure => return error.StreamDisconnected,
        }
    }

    performOperation(self.main_loop, c.pa_stream_update_timing_info(bd.stream, timingUpdateCb, self));
}

pub fn playerDeinit(self: *Player) void {
    var bd = &self.backend_data.PulseAudio;
    c.pa_threaded_mainloop_lock(bd.pa.main_loop);
    defer c.pa_threaded_mainloop_unlock(bd.pa.main_loop);
    c.pa_stream_set_write_callback(bd.stream, null, null);
    c.pa_stream_set_state_callback(bd.stream, null, null);
    c.pa_stream_set_underflow_callback(bd.stream, null, null);
    c.pa_stream_set_overflow_callback(bd.stream, null, null);
    _ = c.pa_stream_disconnect(bd.stream);
    c.pa_stream_unref(bd.stream);
}

pub fn playerStart(self: *Player) !void {
    var bd = &self.backend_data.PulseAudio;
    c.pa_threaded_mainloop_lock(bd.pa.main_loop);
    defer c.pa_threaded_mainloop_unlock(bd.pa.main_loop);
    const op = c.pa_stream_cork(bd.stream, 0, null, null) orelse
        return error.StreamDisconnected;
    c.pa_operation_unref(op);
    c.pa_stream_set_write_callback(bd.stream, playbackStreamWriteCb, self);
}

pub fn playerPausePlay(self: *Player, pause: bool) !void {
    var bd = &self.backend_data.PulseAudio;

    if (c.pa_threaded_mainloop_in_thread(bd.pa.main_loop) == 0)
        c.pa_threaded_mainloop_lock(bd.pa.main_loop);
    defer if (c.pa_threaded_mainloop_in_thread(bd.pa.main_loop) == 0)
        c.pa_threaded_mainloop_unlock(bd.pa.main_loop);

    if (pause != (c.pa_stream_is_corked(bd.stream) != 0)) {
        const op = c.pa_stream_cork(bd.stream, @boolToInt(pause), null, null) orelse
            return error.StreamDisconnected;
        c.pa_operation_unref(op);
    }
}

pub fn playerSetVolume(self: *Player, volume: f64) !void {
    var bd = &self.backend_data.PulseAudio;

    if (c.pa_threaded_mainloop_in_thread(bd.pa.main_loop) == 0)
        c.pa_threaded_mainloop_lock(bd.pa.main_loop);
    defer if (c.pa_threaded_mainloop_in_thread(bd.pa.main_loop) == 0)
        c.pa_threaded_mainloop_unlock(bd.pa.main_loop);

    var v: c.pa_cvolume = undefined;
    _ = c.pa_cvolume_init(&v);
    v.channels = @intCast(u5, self.channels.len);
    const vol = @floatToInt(u32, @intToFloat(f64, c.PA_VOLUME_NORM) * volume);
    for (self.channels.slice()) |_, i|
        v.values[i] = vol;

    performOperation(
        bd.pa.main_loop,
        c.pa_context_set_sink_input_volume(
            bd.pa.pulse_context,
            c.pa_stream_get_index(bd.stream),
            &v,
            opSuccessCb,
            bd,
        ),
    );
}

fn opSuccessCb(_: ?*c.pa_context, success: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var bd = @ptrCast(*PlayerData, @alignCast(@alignOf(*PlayerData), userdata.?));

    if (success == 1) {
        c.pa_threaded_mainloop_signal(bd.pa.main_loop, 0);
    }
}

pub fn playerVolume(self: *Player) !f64 {
    var bd = &self.backend_data.PulseAudio;

    if (c.pa_threaded_mainloop_in_thread(bd.pa.main_loop) == 0)
        c.pa_threaded_mainloop_lock(bd.pa.main_loop);
    defer if (c.pa_threaded_mainloop_in_thread(bd.pa.main_loop) == 0)
        c.pa_threaded_mainloop_unlock(bd.pa.main_loop);

    performOperation(
        bd.pa.main_loop,
        c.pa_context_get_sink_input_info(
            bd.pa.pulse_context,
            c.pa_stream_get_index(bd.stream),
            sinkInputInfoCb,
            bd,
        ),
    );
    return bd.volume;
}

pub fn deviceDeinit(self: Device, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.name);
}

pub fn playerErr(self: *Player) !void {
    _ = self;
    return;
}

fn sinkInputInfoCb(_: ?*c.pa_context, info: [*c]const c.pa_sink_input_info, eol: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var bd = @ptrCast(*PlayerData, @alignCast(@alignOf(*PlayerData), userdata.?));
    if (eol != 0) {
        c.pa_threaded_mainloop_signal(bd.pa.main_loop, 0);
        return;
    }
    bd.volume = @intToFloat(f64, info.*.volume.values[0]) / @intToFloat(f64, c.PA_VOLUME_NORM);
}

fn playbackStreamWriteCb(_: ?*c.pa_stream, nbytes: usize, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*Player, @alignCast(@alignOf(*Player), userdata.?));
    var bd = &self.backend_data.PulseAudio;
    var frames_left = nbytes;
    var err: error{WriteFailed}!void = {};
    while (frames_left > 0) {
        var chunk_size = frames_left;
        if (c.pa_stream_begin_write(
            bd.stream,
            @ptrCast(
                [*c]?*anyopaque,
                @alignCast(@alignOf([*c]?*anyopaque), &bd.write_ptr),
            ),
            &chunk_size,
        ) != 0)
            return switch (pulse_util.getError(bd.pa.pulse_context)) {
                else => unreachable,
            };

        for (self.channels.slice()) |*ch, i| {
            ch.*.ptr = bd.write_ptr + self.bytes_per_sample * i;
        }

        const frames = chunk_size / self.bytes_per_frame;
        self.writeFn(self, err, frames);

        if (c.pa_stream_write(bd.stream, bd.write_ptr, chunk_size, null, 0, c.PA_SEEK_RELATIVE) != 0)
            err = error.WriteFailed;
        frames_left -= chunk_size;
    }
}

fn playbackStreamStateCb(stream: ?*c.pa_stream, userdata: ?*anyopaque) callconv(.C) void {
    var bd = @ptrCast(*PlayerData, @alignCast(@alignOf(*PlayerData), userdata.?));
    switch (c.pa_stream_get_state(stream)) {
        c.PA_STREAM_UNCONNECTED, c.PA_STREAM_CREATING, c.PA_STREAM_TERMINATED => {},
        c.PA_STREAM_READY => {
            bd.stream_ready.store(.ready, .Unordered);
            c.pa_threaded_mainloop_signal(bd.pa.main_loop, 0);
        },
        c.PA_STREAM_FAILED => {
            bd.stream_ready.store(.failure, .Unordered);
            c.pa_threaded_mainloop_signal(bd.pa.main_loop, 0);
        },
        else => unreachable,
    }
}

fn timingUpdateCb(_: ?*c.pa_stream, _: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

fn refreshDevices(self: *PulseAudio) !void {
    self.devices_info.clear(self.allocator);

    const list_sink_op = c.pa_context_get_sink_info_list(self.pulse_context, sinkInfoCb, self);
    const list_source_op = c.pa_context_get_source_info_list(self.pulse_context, sourceInfoCb, self);
    const server_info_op = c.pa_context_get_server_info(self.pulse_context, serverInfoCb, self);

    errdefer self.devices_info.list.clearAndFree(self.allocator);
    performOperation(self.main_loop, list_sink_op);
    performOperation(self.main_loop, list_source_op);
    performOperation(self.main_loop, server_info_op);
    if (self.device_query_err) |err| return err;
    defer {
        self.allocator.free(self.default_sink_id.?);
        self.allocator.free(self.default_source_id.?);
    }

    for (self.devices_info.list.items) |device, i| {
        if ((device.aim == .playback and std.mem.eql(u8, device.id, self.default_sink_id.?)) or
            (device.aim == .capture and std.mem.eql(u8, device.id, self.default_source_id.?)))
        {
            self.devices_info.setDefault(device.aim, i);
            break;
        }
    }
}

fn performOperation(main_loop: *c.pa_threaded_mainloop, op: ?*c.pa_operation) void {
    while (true) {
        switch (c.pa_operation_get_state(op)) {
            c.PA_OPERATION_RUNNING => c.pa_threaded_mainloop_wait(main_loop),
            c.PA_OPERATION_DONE => return c.pa_operation_unref(op),
            c.PA_OPERATION_CANCELLED => {
                std.debug.assert(false);
                c.pa_operation_unref(op);
                return;
            },
            else => unreachable,
        }
    }
}

fn subscribeCb(_: ?*c.pa_context, _: c.pa_subscription_event_type_t, _: u32, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    self.device_scan_queued.store(true, .Unordered);
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

fn contextStateCb(ctx: ?*c.pa_context, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    self.context_state = c.pa_context_get_state(ctx);
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

fn sinkInfoCb(_: ?*c.pa_context, info: [*c]const c.pa_sink_info, eol: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    if (eol != 0) {
        c.pa_threaded_mainloop_signal(self.main_loop, 0);
        return;
    }
    self.deviceInfoCb(info, .playback);
}

fn sourceInfoCb(_: ?*c.pa_context, info: [*c]const c.pa_source_info, eol: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    if (eol != 0) {
        c.pa_threaded_mainloop_signal(self.main_loop, 0);
        return;
    }
    self.deviceInfoCb(info, .capture);
}

fn deviceInfoCb(self: *PulseAudio, info: anytype, aim: Device.Aim) void {
    if (self.device_query_err != null) return;
    if (info.*.name == null or info.*.description == null)
        self.device_query_err = error.OutOfMemory;

    const id = self.allocator.dupeZ(u8, std.mem.span(info.*.name)) catch |err| {
        self.device_query_err = err;
        return;
    };
    const name = self.allocator.dupeZ(u8, std.mem.span(info.*.description)) catch |err| {
        self.allocator.free(id);
        self.device_query_err = err;
        return;
    };
    var device = Device{
        .id = id,
        .name = name,
        .aim = aim,
        .is_raw = false,
        .channels = pulse_util.fromPAChannelMap(info.*.channel_map) orelse {
            self.allocator.free(id);
            self.allocator.free(name);
            return;
        }, // Incompatible device. skip it
        .formats = pulse_util.supported_formats,
        .rate_range = .{
            .min = std.math.clamp(info.*.sample_spec.rate, min_sample_rate, max_sample_rate),
            .max = std.math.clamp(info.*.sample_spec.rate, min_sample_rate, max_sample_rate),
        },
    };

    self.devices_info.list.append(self.allocator, device) catch |err| {
        self.allocator.free(id);
        self.allocator.free(name);
        self.device_query_err = err;
        return;
    };
}

fn serverInfoCb(_: ?*c.pa_context, info: [*c]const c.pa_server_info, userdata: ?*anyopaque) callconv(.C) void {
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
