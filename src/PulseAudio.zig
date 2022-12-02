const std = @import("std");
const c = @cImport(@cInclude("pulse/pulseaudio.h"));
const Channel = @import("main.zig").Channel;
const ChannelId = @import("main.zig").ChannelId;
const ConnectOptions = @import("main.zig").ConnectOptions;
const Device = @import("main.zig").Device;
const DevicesInfo = @import("main.zig").DevicesInfo;
const Format = @import("main.zig").Format;
const Player = @import("main.zig").Player;
const min_sample_rate = @import("main.zig").min_sample_rate;
const max_sample_rate = @import("main.zig").max_sample_rate;

const is_little = @import("builtin").cpu.arch.endian() == .Little;

const PulseAudio = @This();

allocator: std.mem.Allocator,
devices_info: DevicesInfo,
app_name: [:0]const u8,
main_loop: *c.pa_threaded_mainloop,
ctx: *c.pa_context,
ctx_state: c.pa_context_state_t,
default_sink: ?[:0]const u8,
default_source: ?[:0]const u8,
scan_queued: ?std.atomic.Atomic(bool),

pub fn connect(allocator: std.mem.Allocator, options: ConnectOptions) !*PulseAudio {
    const main_loop = c.pa_threaded_mainloop_new() orelse
        return error.OutOfMemory;
    errdefer c.pa_threaded_mainloop_free(main_loop);

    var main_loop_api = c.pa_threaded_mainloop_get_api(main_loop);

    const ctx = c.pa_context_new_with_proplist(main_loop_api, options.app_name.ptr, null) orelse
        return error.OutOfMemory;
    errdefer c.pa_context_unref(ctx);

    if (c.pa_context_connect(ctx, null, 0, null) != 0)
        return error.ConnectionRefused;
    errdefer c.pa_context_disconnect(ctx);

    var self = try allocator.create(PulseAudio);
    errdefer allocator.destroy(self);
    self.* = PulseAudio{
        .allocator = allocator,
        .devices_info = DevicesInfo.init(),
        .app_name = options.app_name,
        .main_loop = main_loop,
        .ctx = ctx,
        .ctx_state = c.PA_CONTEXT_UNCONNECTED,
        .default_sink = null,
        .default_source = null,
        .scan_queued = if (options.watch_devices) .{ .value = false } else null,
    };

    c.pa_context_set_state_callback(ctx, contextStateOp, self);

    if (c.pa_threaded_mainloop_start(main_loop) != 0)
        return error.SystemResources;
    errdefer c.pa_threaded_mainloop_stop(main_loop);

    c.pa_threaded_mainloop_lock(main_loop);
    defer c.pa_threaded_mainloop_unlock(main_loop);

    while (true) {
        switch (self.ctx_state) {
            // The context hasn't been connected yet.
            c.PA_CONTEXT_UNCONNECTED,
            // A connection is being established.
            c.PA_CONTEXT_CONNECTING,
            // The client is authorizing itself to the daemon.
            c.PA_CONTEXT_AUTHORIZING,
            // The client is passing its application name to the daemon.
            c.PA_CONTEXT_SETTING_NAME,
            => c.pa_threaded_mainloop_wait(main_loop),

            // The connection is established, the context is ready to execute operations.
            c.PA_CONTEXT_READY => break,

            // The connection was terminated cleanly.
            c.PA_CONTEXT_TERMINATED,
            // The connection failed or was disconnected.
            c.PA_CONTEXT_FAILED,
            => return error.ConnectionRefused,

            else => unreachable,
        }
    }
    // subscribe to events
    if (options.watch_devices) {
        c.pa_context_set_subscribe_callback(ctx, subscribeOp, self);
        const events = c.PA_SUBSCRIPTION_MASK_SINK | c.PA_SUBSCRIPTION_MASK_SOURCE | c.PA_SUBSCRIPTION_MASK_SERVER;
        const subscribe_op = c.pa_context_subscribe(ctx, events, null, self) orelse
            return error.OutOfMemory;
        c.pa_operation_unref(subscribe_op);
    }

    return self;
}

fn subscribeOp(_: ?*c.pa_context, _: c.pa_subscription_event_type_t, _: u32, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));

    self.scan_queued.?.store(true, .Unordered);
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

fn contextStateOp(ctx: ?*c.pa_context, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));

    self.ctx_state = c.pa_context_get_state(ctx);
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

pub fn disconnect(self: *PulseAudio) void {
    c.pa_context_set_subscribe_callback(self.ctx, null, null);
    c.pa_context_set_state_callback(self.ctx, null, null);
    c.pa_context_disconnect(self.ctx);
    c.pa_context_unref(self.ctx);
    c.pa_threaded_mainloop_stop(self.main_loop);
    c.pa_threaded_mainloop_free(self.main_loop);
    self.devices_info.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn flush(self: *PulseAudio) !void {
    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);
    try self.refreshDevices();
}

pub fn wait(self: *PulseAudio) !void {
    std.debug.assert(self.scan_queued != null);

    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);
    while (!self.scan_queued.?.load(.Acquire))
        c.pa_threaded_mainloop_wait(self.main_loop);
    self.scan_queued.?.store(false, .Release);
    try self.refreshDevices();
}

pub fn wakeUp(self: *PulseAudio) void {
    std.debug.assert(self.scan_queued != null);

    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);
    self.scan_queued.?.store(true, .Release);
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

fn refreshDevices(self: *PulseAudio) !void {
    self.devices_info.clear(self.allocator);

    const list_sink_op = c.pa_context_get_sink_info_list(self.ctx, sinkInfoOp, self);
    const list_source_op = c.pa_context_get_source_info_list(self.ctx, sourceInfoOp, self);
    const server_info_op = c.pa_context_get_server_info(self.ctx, serverInfoOp, self);

    performOperation(self.main_loop, list_sink_op);
    performOperation(self.main_loop, list_source_op);
    performOperation(self.main_loop, server_info_op);

    defer {
        if (self.default_sink) |d|
            self.allocator.free(d);
        if (self.default_source) |d|
            self.allocator.free(d);
    }
    for (self.devices_info.list.items) |device, i| {
        if ((device.aim == .playback and
            self.default_sink != null and
            std.mem.eql(u8, device.id, self.default_sink.?)) or
            //
            (device.aim == .capture and
            self.default_source != null and
            std.mem.eql(u8, device.id, self.default_source.?)))
        {
            self.devices_info.setDefault(device.aim, i);
            break;
        }
    }
}

fn serverInfoOp(_: ?*c.pa_context, info: [*c]const c.pa_server_info, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));

    defer c.pa_threaded_mainloop_signal(self.main_loop, 0);
    self.default_sink = self.allocator.dupeZ(u8, std.mem.span(info.*.default_sink_name)) catch return;
    self.default_source = self.allocator.dupeZ(u8, std.mem.span(info.*.default_source_name)) catch {
        self.allocator.free(self.default_sink.?);
        return;
    };
}

fn sinkInfoOp(_: ?*c.pa_context, info: [*c]const c.pa_sink_info, eol: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    if (eol != 0) {
        c.pa_threaded_mainloop_signal(self.main_loop, 0);
        return;
    }

    self.deviceInfoOp(info, .playback) catch return;
}

fn sourceInfoOp(_: ?*c.pa_context, info: [*c]const c.pa_source_info, eol: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    if (eol != 0) {
        c.pa_threaded_mainloop_signal(self.main_loop, 0);
        return;
    }

    self.deviceInfoOp(info, .capture) catch return;
}

fn deviceInfoOp(self: *PulseAudio, info: anytype, aim: Device.Aim) !void {
    var id = try self.allocator.dupeZ(u8, std.mem.span(info.*.name));
    errdefer self.allocator.free(id);
    var name = try self.allocator.dupeZ(u8, std.mem.span(info.*.description));
    errdefer self.allocator.free(name);

    if (info.*.sample_spec.rate < min_sample_rate or
        info.*.sample_spec.rate > max_sample_rate)
        return;

    var device = Device{
        .aim = aim,
        .channels = blk: {
            // TODO: check channels count
            var channels = try self.allocator.alloc(Channel, info.*.channel_map.channels);
            for (channels) |*ch, i|
                ch.*.id = fromPAChannelPos(info.*.channel_map.map[i]);
            break :blk channels;
        },
        .formats = available_formats,
        .rate_range = .{
            .min = info.*.sample_spec.rate,
            .max = info.*.sample_spec.rate,
        },
        .id = id,
        .name = name,
    };

    try self.devices_info.list.append(self.allocator, device);
}

const StreamStatus = enum(u8) {
    unknown,
    ready,
    failure,
};

pub const PlayerData = struct {
    main_loop: *c.pa_threaded_mainloop,
    ctx: *c.pa_context,
    stream: *c.pa_stream,
    status: std.atomic.Atomic(StreamStatus),
    write_ptr: [*]u8,
    volume: f32,
};

pub fn openPlayer(self: *PulseAudio, player: *Player, device: Device) !void {
    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);

    const sample_spec = c.pa_sample_spec{
        .format = toPAFormat(player.format) catch unreachable,
        .rate = player.sample_rate,
        .channels = @intCast(u5, player.device.channels.len),
    };

    const channel_map = try toPAChannelMap(player.device.channels);

    var stream = c.pa_stream_new(self.ctx, self.app_name.ptr, &sample_spec, &channel_map);
    if (stream == null)
        return error.OutOfMemory;
    errdefer c.pa_stream_unref(stream);

    player.backend_data = .{
        .PulseAudio = .{
            .main_loop = self.main_loop,
            .ctx = self.ctx,
            .stream = stream.?,
            .status = std.atomic.Atomic(StreamStatus).init(.unknown),
            .write_ptr = undefined,
            .volume = 1.0,
        },
    };
    var bd = &player.backend_data.PulseAudio;

    c.pa_stream_set_state_callback(bd.stream, playbackStreamStateOp, bd);

    const buf_attr = c.pa_buffer_attr{
        .maxlength = std.math.maxInt(u32),
        .tlength = std.math.maxInt(u32),
        .prebuf = 0,
        .minreq = std.math.maxInt(u32),
        .fragsize = std.math.maxInt(u32),
    };

    const flags =
        c.PA_STREAM_START_CORKED |
        c.PA_STREAM_AUTO_TIMING_UPDATE |
        c.PA_STREAM_INTERPOLATE_TIMING |
        c.PA_STREAM_ADJUST_LATENCY;

    if (c.pa_stream_connect_playback(bd.stream, device.id.ptr, &buf_attr, flags, null, null) != 0) {
        return error.OpeningDevice;
    }
    errdefer _ = c.pa_stream_disconnect(bd.stream);

    while (true) {
        switch (bd.status.load(.Unordered)) {
            .unknown => c.pa_threaded_mainloop_wait(self.main_loop),
            .ready => break,
            .failure => return error.OpeningDevice,
        }
    }
}

fn playbackStreamStateOp(stream: ?*c.pa_stream, userdata: ?*anyopaque) callconv(.C) void {
    var bd = @ptrCast(*PlayerData, @alignCast(@alignOf(*PlayerData), userdata.?));

    switch (c.pa_stream_get_state(stream)) {
        c.PA_STREAM_UNCONNECTED,
        c.PA_STREAM_CREATING,
        c.PA_STREAM_TERMINATED,
        => {},
        c.PA_STREAM_READY => {
            bd.status.store(.ready, .Unordered);
            c.pa_threaded_mainloop_signal(bd.main_loop, 0);
        },
        c.PA_STREAM_FAILED => {
            bd.status.store(.failure, .Unordered);
            c.pa_threaded_mainloop_signal(bd.main_loop, 0);
        },
        else => unreachable,
    }
}

pub fn playerDeinit(self: *Player) void {
    var bd = &self.backend_data.PulseAudio;

    c.pa_threaded_mainloop_lock(bd.main_loop);
    defer c.pa_threaded_mainloop_unlock(bd.main_loop);

    c.pa_stream_set_write_callback(bd.stream, null, null);
    c.pa_stream_set_state_callback(bd.stream, null, null);
    c.pa_stream_set_underflow_callback(bd.stream, null, null);
    c.pa_stream_set_overflow_callback(bd.stream, null, null);
    _ = c.pa_stream_disconnect(bd.stream);
    c.pa_stream_unref(bd.stream);
}

pub fn playerStart(self: *Player) !void {
    var bd = &self.backend_data.PulseAudio;

    c.pa_threaded_mainloop_lock(bd.main_loop);
    defer c.pa_threaded_mainloop_unlock(bd.main_loop);

    const op = c.pa_stream_cork(bd.stream, 0, null, null) orelse
        return error.CannotPlay;
    c.pa_operation_unref(op);

    c.pa_stream_set_write_callback(bd.stream, playbackStreamWriteOp, self);
}

fn playbackStreamWriteOp(_: ?*c.pa_stream, nbytes: usize, userdata: ?*anyopaque) callconv(.C) void {
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
            err = error.WriteFailed;

        for (self.device.channels) |*ch, i| {
            ch.*.ptr = bd.write_ptr + self.bytesPerSample() * i;
        }

        const frames = chunk_size / self.bytesPerFrame();
        self.writeFn(self, err, frames);

        if (c.pa_stream_write(bd.stream, bd.write_ptr, chunk_size, null, 0, c.PA_SEEK_RELATIVE) != 0)
            err = error.WriteFailed;

        frames_left -= chunk_size;
    }
}

pub fn playerPlay(self: *Player) !void {
    var bd = &self.backend_data.PulseAudio;

    c.pa_threaded_mainloop_lock(bd.main_loop);
    defer c.pa_threaded_mainloop_unlock(bd.main_loop);

    if (c.pa_stream_is_corked(bd.stream) > 0) {
        const op = c.pa_stream_cork(bd.stream, 0, null, null) orelse
            return error.CannotPlay;
        c.pa_operation_unref(op);
    }
}

pub fn playerPause(self: *Player) !void {
    var bd = &self.backend_data.PulseAudio;

    c.pa_threaded_mainloop_lock(bd.main_loop);
    defer c.pa_threaded_mainloop_unlock(bd.main_loop);

    if (c.pa_stream_is_corked(bd.stream) == 0) {
        const op = c.pa_stream_cork(bd.stream, 1, null, null) orelse
            return error.CannotPause;
        c.pa_operation_unref(op);
    }
}

pub fn playerPaused(self: *Player) bool {
    var bd = &self.backend_data.PulseAudio;

    c.pa_threaded_mainloop_lock(bd.main_loop);
    defer c.pa_threaded_mainloop_unlock(bd.main_loop);

    return c.pa_stream_is_corked(bd.stream) > 0;
}

pub fn playerSetVolume(self: *Player, volume: f32) !void {
    var bd = &self.backend_data.PulseAudio;

    c.pa_threaded_mainloop_lock(bd.main_loop);
    defer c.pa_threaded_mainloop_unlock(bd.main_loop);

    var v: c.pa_cvolume = undefined;
    _ = c.pa_cvolume_init(&v);
    v.channels = @intCast(u5, self.device.channels.len);
    for (self.device.channels) |_, i| {
        _ = c.pa_cvolume_set(&v, @intCast(c_uint, i), c.pa_sw_volume_from_linear(volume));
    }

    performOperation(
        bd.main_loop,
        c.pa_context_set_sink_input_volume(
            bd.ctx,
            c.pa_stream_get_index(bd.stream),
            &v,
            successOp,
            bd,
        ),
    );
}

fn successOp(_: ?*c.pa_context, success: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var bd = @ptrCast(*PlayerData, @alignCast(@alignOf(*PlayerData), userdata.?));

    if (success == 1) {
        c.pa_threaded_mainloop_signal(bd.main_loop, 0);
    }
}

pub fn playerVolume(self: *Player) !f32 {
    var bd = &self.backend_data.PulseAudio;

    c.pa_threaded_mainloop_lock(bd.main_loop);
    defer c.pa_threaded_mainloop_unlock(bd.main_loop);

    performOperation(
        bd.main_loop,
        c.pa_context_get_sink_input_info(
            bd.ctx,
            c.pa_stream_get_index(bd.stream),
            sinkInputInfoOp,
            bd,
        ),
    );

    return bd.volume;
}

fn sinkInputInfoOp(_: ?*c.pa_context, info: [*c]const c.pa_sink_input_info, eol: c_int, userdata: ?*anyopaque) callconv(.C) void {
    var bd = @ptrCast(*PlayerData, @alignCast(@alignOf(*PlayerData), userdata.?));

    if (eol != 0) {
        c.pa_threaded_mainloop_signal(bd.main_loop, 0);
        return;
    }

    bd.volume = @intToFloat(f32, info.*.volume.values[0]) / @intToFloat(f32, c.PA_VOLUME_NORM);
}

pub fn deviceDeinit(self: Device, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.name);
    allocator.free(self.channels);
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

pub const available_formats = &[_]Format{
    .u8,  .i16,
    .i24, .i24_3b,
    .i32, .f32,
};

pub fn fromPAChannelPos(pos: c.pa_channel_position_t) ChannelId {
    return switch (pos) {
        c.PA_CHANNEL_POSITION_MONO => .front_center,
        c.PA_CHANNEL_POSITION_FRONT_LEFT => .front_left, // PA_CHANNEL_POSITION_LEFT
        c.PA_CHANNEL_POSITION_FRONT_RIGHT => .front_right, // PA_CHANNEL_POSITION_RIGHT
        c.PA_CHANNEL_POSITION_FRONT_CENTER => .front_center, // PA_CHANNEL_POSITION_CENTER
        c.PA_CHANNEL_POSITION_REAR_CENTER => .back_center,
        c.PA_CHANNEL_POSITION_LFE => .lfe, // PA_CHANNEL_POSITION_SUBWOOFER
        c.PA_CHANNEL_POSITION_FRONT_LEFT_OF_CENTER => .front_left_center,
        c.PA_CHANNEL_POSITION_FRONT_RIGHT_OF_CENTER => .front_right_center,
        c.PA_CHANNEL_POSITION_SIDE_LEFT => .side_left,
        c.PA_CHANNEL_POSITION_SIDE_RIGHT => .side_right,

        // TODO: .front_center?
        c.PA_CHANNEL_POSITION_AUX0...c.PA_CHANNEL_POSITION_AUX31 => unreachable,

        c.PA_CHANNEL_POSITION_TOP_CENTER => .top_center,
        c.PA_CHANNEL_POSITION_TOP_FRONT_LEFT => .top_front_left,
        c.PA_CHANNEL_POSITION_TOP_FRONT_RIGHT => .top_front_right,
        c.PA_CHANNEL_POSITION_TOP_FRONT_CENTER => .top_front_center,
        c.PA_CHANNEL_POSITION_TOP_REAR_LEFT => .top_back_left,
        c.PA_CHANNEL_POSITION_TOP_REAR_RIGHT => .top_back_right,
        c.PA_CHANNEL_POSITION_TOP_REAR_CENTER => .top_back_center,

        else => unreachable,
    };
}

pub fn toPAFormat(format: Format) !c.pa_sample_format_t {
    return switch (format) {
        .u8 => c.PA_SAMPLE_U8,
        .i16 => if (is_little) c.PA_SAMPLE_S16LE else c.PA_SAMPLE_S16BE,
        .i24 => if (is_little) c.PA_SAMPLE_S24LE else c.PA_SAMPLE_S24LE,
        .i24_3b => if (is_little) c.PA_SAMPLE_S24_32LE else c.PA_SAMPLE_S24_32BE,
        .i32 => if (is_little) c.PA_SAMPLE_S32LE else c.PA_SAMPLE_S32BE,
        .f32 => if (is_little) c.PA_SAMPLE_FLOAT32LE else c.PA_SAMPLE_FLOAT32BE,

        .f64 => error.IncompatibleBackend,
    };
}

pub fn toPAChannelMap(channels: []const Channel) !c.pa_channel_map {
    var channel_map: c.pa_channel_map = undefined;
    channel_map.channels = @intCast(u5, channels.len);
    for (channels) |ch, i|
        channel_map.map[i] = try toPAChannelPos(ch.id);
    return channel_map;
}

fn toPAChannelPos(channel_id: ChannelId) !c.pa_channel_position_t {
    return switch (channel_id) {
        .front_left => c.PA_CHANNEL_POSITION_FRONT_LEFT,
        .front_right => c.PA_CHANNEL_POSITION_FRONT_RIGHT,
        .front_center => c.PA_CHANNEL_POSITION_FRONT_CENTER,
        .lfe => c.PA_CHANNEL_POSITION_LFE,
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
    };
}
