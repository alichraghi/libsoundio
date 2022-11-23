const std = @import("std");
const c = @import("Alsa/c.zig");
const queryDevices = @import("Alsa/device.zig").queryDevices;
const alsa_util = @import("Alsa/util.zig");
const Device = @import("main.zig").Device;
const Player = @import("main.zig").Player;
const Range = @import("main.zig").Range;
const DevicesInfo = @import("main.zig").DevicesInfo;
const util = @import("util.zig");
const linux = std.os.linux;

const Alsa = @This();

const max_snd_file_len = 16;

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex,
cond: std.Thread.Condition,
thread: std.Thread,
aborted: std.atomic.Atomic(bool),
device_scan_queued: std.atomic.Atomic(bool),
err: error{ SystemResources, OutOfMemory }!void,
devices_info: DevicesInfo,
notify_fd: linux.fd_t,
notify_wd: linux.fd_t,
notify_pipe_fd: [2]linux.fd_t,

pub fn connect(allocator: std.mem.Allocator) !*Alsa {
    const notify_fd = std.os.inotify_init1(linux.IN.NONBLOCK) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.SystemResources,
        => return error.SystemResources,
        error.Unexpected => unreachable,
    };
    errdefer std.os.close(notify_fd);

    const notify_wd = std.os.inotify_add_watch(
        notify_fd,
        "/dev/snd",
        linux.IN.CREATE | linux.IN.DELETE,
    ) catch |err| switch (err) {
        error.AccessDenied => return error.AccessDenied,
        error.UserResourceLimitReached,
        error.NotDir,
        error.FileNotFound,
        error.SystemResources,
        => return error.SystemResources,
        error.NameTooLong,
        error.WatchAlreadyExists,
        error.Unexpected,
        => unreachable,
    };
    errdefer std.os.inotify_rm_watch(notify_fd, notify_wd);

    // used to wakeup poll
    const notify_pipe_fd = std.os.pipe2(linux.O.NONBLOCK) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return error.SystemResources,
        error.Unexpected => unreachable,
    };
    errdefer {
        std.os.close(notify_pipe_fd[0]);
        std.os.close(notify_pipe_fd[1]);
    }

    // zig fmt: off
    _ = c.snd_lib_error_set_handler(@ptrCast(
            c.snd_lib_error_handler_t,
            &struct { fn e() callconv(.C) void {} }.e,
        ));
    // zig fmt: on

    var self = try allocator.create(Alsa);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .mutex = std.Thread.Mutex{},
        .cond = std.Thread.Condition{},
        .thread = std.Thread.spawn(.{}, deviceEventsLoop, .{self}) catch |err| switch (err) {
            error.ThreadQuotaExceeded,
            error.SystemResources,
            error.LockedMemoryLimitExceeded,
            => return error.SystemResources,
            error.OutOfMemory => return error.OutOfMemory,
            error.Unexpected => unreachable,
        },
        .aborted = .{ .value = false },
        .device_scan_queued = .{ .value = false },
        .err = {},
        .devices_info = DevicesInfo.init(),
        .notify_fd = notify_fd,
        .notify_wd = notify_wd,
        .notify_pipe_fd = notify_pipe_fd,
    };
    return self;
}

pub fn deinit(self: *Alsa) void {
    self.aborted.store(true, .Unordered);

    // wake up thread
    _ = std.os.write(self.notify_pipe_fd[1], "a") catch {};
    self.thread.join();

    std.os.close(self.notify_pipe_fd[0]);
    std.os.close(self.notify_pipe_fd[1]);
    std.os.inotify_rm_watch(self.notify_fd, self.notify_wd);
    std.os.close(self.notify_fd);

    self.devices_info.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn deviceEventsLoop(self: *Alsa) !void {
    var buf: [4096]u8 = undefined;
    var fds = [2]std.os.pollfd{
        .{
            .fd = self.notify_fd,
            .events = linux.POLL.IN,
            .revents = 0,
        },
        .{
            .fd = self.notify_pipe_fd[0],
            .events = linux.POLL.IN,
            .revents = 0,
        },
    };

    while (true) {
        var scan = false;

        if (self.aborted.load(.Unordered)) break;

        _ = std.os.poll(&fds, -1) catch |err| switch (err) {
            error.NetworkSubsystemFailed,
            error.SystemResources,
            => {
                self.wakeUp();
                self.err = error.SystemResources;
                return;
            },
            error.Unexpected => unreachable,
        };

        if (util.hasFlag(self.notify_fd, linux.POLL.IN)) {
            while (true) {
                const len = std.os.read(self.notify_fd, &buf) catch |err| {
                    if (err == error.WouldBlock) break;
                    self.wakeUp();
                    self.err = error.SystemResources;
                    return;
                };
                if (len == 0) break;

                var i: usize = 0;
                var evt: *linux.inotify_event = undefined;
                while (i < buf.len) : (i += @sizeOf(linux.inotify_event) + evt.len) {
                    evt = @ptrCast(*linux.inotify_event, @alignCast(4, buf[i..]));
                    const evt_name = @ptrCast([*]u8, buf[i..])[@sizeOf(linux.inotify_event) .. @sizeOf(linux.inotify_event) + 8];

                    if (util.hasFlag(evt.mask, linux.IN.ISDIR) or !std.mem.startsWith(u8, evt_name, "pcm"))
                        continue;

                    scan = true;
                }
            }
        }

        if (scan) {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.device_scan_queued.store(true, .Release);
            self.cond.signal();
        }
    }
}

pub fn flushEvents(self: *Alsa) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    try self.err;

    self.device_scan_queued.store(false, .Release);
    try self.refreshDevices();
}

pub fn waitEvents(self: *Alsa) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (!self.device_scan_queued.load(.Acquire))
        self.cond.wait(&self.mutex);

    try self.err;

    self.device_scan_queued.store(false, .Release);
    try self.refreshDevices();
}

fn refreshDevices(self: *Alsa) !void {
    self.devices_info.clear(self.allocator);

    try queryDevices(&self.devices_info, self.allocator);
}

pub fn wakeUp(self: *Alsa) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.device_scan_queued.store(true, .Release);
    self.cond.signal();
}

pub const PlayerData = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    aborted: std.atomic.Atomic(bool),
    pcm: ?*c.snd_pcm_t,
    period_size: c.snd_pcm_uframes_t,
    sample_buffer: []u8,
    mixer: ?*c.snd_mixer_t,
    selem: ?*c.snd_mixer_selem_id_t,
    mixer_elm: ?*c.snd_mixer_elem_t,
    volume_range: Range(c_long),
};

pub fn openPlayer(self: *Alsa, player: *Player, device: Device) !void {
    std.debug.print("{s}\n", .{self.devices_info.default(.playback).?.id});
    player.backend_data = .{
        .Alsa = .{
            .allocator = self.allocator,
            .thread = undefined,
            .aborted = .{ .value = false },
            .pcm = null,
            .period_size = undefined,
            .sample_buffer = undefined,
            .mixer = undefined,
            .selem = undefined,
            .mixer_elm = undefined,
            .volume_range = .{ .min = 0, .max = 0 },
        },
    };
    var bd = &player.backend_data.Alsa;

    const snd_stream = alsa_util.aimToStream(device.aim);
    if (c.snd_pcm_open(&bd.pcm, device.id.ptr, snd_stream, c.SND_PCM_ASYNC) < 0)
        return error.OpeningDevice;
    errdefer _ = c.snd_pcm_close(bd.pcm);

    const format = alsa_util.toAlsaFormat(player.format) catch return error.IncompatibleBackend;
    if ((c.snd_pcm_set_params(
        bd.pcm,
        format,
        c.SND_PCM_ACCESS_RW_INTERLEAVED,
        @intCast(u6, player.channels.len),
        player.sample_rate,
        @bitCast(u1, !device.is_raw),
        @intCast(c_uint, player.latency),
    )) < 0)
        return error.OpeningDevice;
    errdefer _ = c.snd_pcm_hw_free(bd.pcm);

    var hw_params: ?*c.snd_pcm_hw_params_t = null;
    if (c.snd_pcm_hw_params_malloc(&hw_params) < 0)
        return error.OpeningDevice;
    defer c.snd_pcm_hw_params_free(hw_params);
    if (c.snd_pcm_hw_params_current(bd.pcm, hw_params) < 0)
        return error.OpeningDevice;

    if (c.snd_pcm_hw_params_get_period_size(hw_params, &bd.period_size, null) < 0)
        return error.OpeningDevice;

    var buf_size: c.snd_pcm_uframes_t = 0;
    if (c.snd_pcm_hw_params_get_buffer_size(hw_params, &buf_size) < 0)
        return error.OpeningDevice;

    var latency: c_uint = 0;
    if (c.snd_pcm_hw_params_get_buffer_time(hw_params, &latency, null) < 0)
        return error.OpeningDevice;
    player.latency = latency;

    var chmap: c.snd_pcm_chmap_t = .{ .channels = @intCast(u6, player.channels.len) };
    for (player.channels.slice()) |ch, i| {
        chmap.pos()[i] = alsa_util.toAlsaChmapPos(ch.id);
    }
    if (c.snd_pcm_set_chmap(bd.pcm, &chmap) < 0)
        return error.IncompatibleDevice;

    bd.sample_buffer = try bd.allocator.alloc(u8, buf_size);

    if (c.snd_mixer_open(&bd.mixer, 0) < 0)
        return error.OpeningDevice;
    const card_id = try self.allocator.dupeZ(u8, std.mem.sliceTo(device.id, ','));
    defer self.allocator.free(card_id);
    if (c.snd_mixer_attach(bd.mixer, card_id.ptr) < 0)
        return error.OpeningDevice;
    if (c.snd_mixer_selem_register(bd.mixer, null, null) < 0)
        return error.OpeningDevice;
    if (c.snd_mixer_load(bd.mixer) < 0)
        return error.OpeningDevice;

    if (c.snd_mixer_selem_id_malloc(&bd.selem) < 0)
        return error.OutOfMemory;
    c.snd_mixer_selem_id_set_index(bd.selem, 0);
    c.snd_mixer_selem_id_set_name(bd.selem, "Master"); // current device
    bd.mixer_elm = c.snd_mixer_find_selem(bd.mixer, bd.selem);
    if (c.snd_mixer_selem_get_playback_volume_range(bd.mixer_elm, &bd.volume_range.min, &bd.volume_range.max) < 0)
        return error.OpeningDevice;
}

pub fn playerDeinit(self: *Player) void {
    var bd = &self.backend_data.Alsa;
    bd.aborted.store(true, .Unordered);
    bd.thread.join();
    _ = c.snd_mixer_close(bd.mixer);
    c.snd_mixer_selem_id_free(bd.selem);
    _ = c.snd_pcm_close(bd.pcm);
    _ = c.snd_pcm_hw_free(bd.pcm);
    bd.allocator.free(bd.sample_buffer);
}

pub fn playerStart(self: *Player) !void {
    var bd = &self.backend_data.Alsa;
    bd.thread = std.Thread.spawn(.{}, playerLoop, .{self}) catch |err| switch (err) {
        error.ThreadQuotaExceeded,
        error.SystemResources,
        error.LockedMemoryLimitExceeded,
        => return error.SystemResources,
        error.OutOfMemory => return error.OutOfMemory,
        error.Unexpected => unreachable,
    };
}

fn playerLoop(self: *Player) void {
    var bd = &self.backend_data.Alsa;
    for (self.channels.slice()) |*ch, i| {
        ch.*.ptr = bd.sample_buffer.ptr + i * self.bytes_per_sample;
    }

    var err: error{WriteFailed}!void = {};
    while (true) {
        if (bd.aborted.load(.Unordered)) return;

        var frames_left = bd.period_size;
        while (frames_left > 0) {
            self.writeFn(self, err, frames_left);
            const n = c.snd_pcm_writei(bd.pcm, bd.sample_buffer.ptr, frames_left);
            if (n < 0) {
                if (c.snd_pcm_recover(bd.pcm, @intCast(c_int, n), 1) < 0)
                    err = error.WriteFailed;
                return;
            }
            frames_left -= @intCast(c_uint, n);
        }
    }
}

pub fn playerPausePlay(self: *Player, pause: bool) !void {
    var bd = &self.backend_data.Alsa;
    if (c.snd_pcm_pause(bd.pcm, @boolToInt(pause)) < 0) {
        return if (pause)
            error.CannotPause
        else
            error.CannotPlay;
    }
}

pub fn playerSetVolume(self: *Player, volume: f64) !void {
    var bd = &self.backend_data.Alsa;

    if (c.snd_mixer_selem_set_playback_volume_all(
        bd.mixer_elm,
        @floatToInt(
            c_long,
            @intToFloat(f64, bd.volume_range.max - bd.volume_range.min) *
                volume +
                @intToFloat(f64, bd.volume_range.min),
        ),
    ) < 0) unreachable;
}

pub fn playerVolume(self: *Player) error{}!f64 {
    var bd = &self.backend_data.Alsa;

    var volume: c_long = 0;
    var channel: c_int = 0;

    while (channel < c.SND_MIXER_SCHN_LAST) : (channel += 1) {
        if (c.snd_mixer_selem_has_playback_channel(bd.mixer_elm, channel) == 1) {
            if (c.snd_mixer_selem_get_playback_volume(bd.mixer_elm, channel, &volume) == 0)
                break;
        }
    }

    return @intToFloat(f64, volume) / @intToFloat(f64, bd.volume_range.max);
}

pub fn deviceDeinit(self: Device, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.name);
    allocator.free(self.formats);
}
