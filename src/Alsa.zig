const std = @import("std");
const c = @cImport(@cInclude("asoundlib.h"));
const util = @import("util.zig");
const Channel = @import("main.zig").Channel;
const ChannelId = @import("main.zig").ChannelId;
const ConnectOptions = @import("main.zig").ConnectOptions;
const Device = @import("main.zig").Device;
const DevicesInfo = @import("main.zig").DevicesInfo;
const Format = @import("main.zig").Format;
const Player = @import("main.zig").Player;
const Range = @import("main.zig").Range;
const default_latency = @import("main.zig").default_latency;
const max_channels = @import("main.zig").max_channels;
const inotify_event = std.os.linux.inotify_event;

const is_little = @import("builtin").cpu.arch.endian() == .Little;

const Alsa = @This();

allocator: std.mem.Allocator,
devices_info: DevicesInfo,
device_watcher: ?DeviceWatcher,

const DeviceWatcher = struct {
    thread: std.Thread,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    aborted: std.atomic.Atomic(bool),
    scan_queued: std.atomic.Atomic(bool),
    notify_fd: std.os.fd_t,
    notify_wd: std.os.fd_t,
    notify_pipe_fd: [2]std.os.fd_t,
};

pub fn connect(allocator: std.mem.Allocator, options: ConnectOptions) !*Alsa {
    var self = try allocator.create(Alsa);
    errdefer allocator.destroy(self);

    var device_watcher: ?DeviceWatcher = null;
    if (options.watch_devices) {
        const notify_fd = std.os.inotify_init1(std.os.linux.IN.NONBLOCK) catch |err| switch (err) {
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
            std.os.linux.IN.CREATE | std.os.linux.IN.DELETE,
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
        const notify_pipe_fd = std.os.pipe2(std.os.O.NONBLOCK) catch |err| switch (err) {
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            => return error.SystemResources,
            error.Unexpected => unreachable,
        };
        errdefer {
            std.os.close(notify_pipe_fd[0]);
            std.os.close(notify_pipe_fd[1]);
        }

        device_watcher = .{
            .thread = std.Thread.spawn(.{}, deviceEventsLoop, .{self}) catch |err| switch (err) {
                error.ThreadQuotaExceeded,
                error.SystemResources,
                error.LockedMemoryLimitExceeded,
                => return error.SystemResources,
                error.OutOfMemory => return error.OutOfMemory,
                error.Unexpected => unreachable,
            },
            .mutex = .{},
            .cond = .{},
            .aborted = .{ .value = false },
            .scan_queued = .{ .value = false },
            .notify_fd = notify_fd,
            .notify_wd = notify_wd,
            .notify_pipe_fd = notify_pipe_fd,
        };
    }

    // zig fmt: off
    _ = c.snd_lib_error_set_handler(@ptrCast(
            c.snd_lib_error_handler_t,
            &struct { fn e() callconv(.C) void {} }.e,
        ));
    // zig fmt: on

    self.* = .{
        .allocator = allocator,
        .devices_info = DevicesInfo.init(),
        .device_watcher = device_watcher,
    };
    return self;
}

pub fn disconnect(self: *Alsa) void {
    if (self.device_watcher) |*dw| {
        dw.aborted.store(true, .Unordered);

        // wake up thread
        _ = std.os.write(dw.notify_pipe_fd[1], "a") catch {};
        dw.thread.join();

        std.os.close(dw.notify_pipe_fd[0]);
        std.os.close(dw.notify_pipe_fd[1]);
        std.os.inotify_rm_watch(dw.notify_fd, dw.notify_wd);
        std.os.close(dw.notify_fd);
    }

    self.devices_info.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn deviceEventsLoop(self: *Alsa) void {
    var dw = &self.device_watcher.?;
    var last_crash: ?i64 = null;
    var buf: [2048]u8 = undefined;
    var fds = [2]std.os.pollfd{
        .{
            .fd = dw.notify_fd,
            .events = std.os.POLL.IN,
            .revents = 0,
        },
        .{
            .fd = dw.notify_pipe_fd[0],
            .events = std.os.POLL.IN,
            .revents = 0,
        },
    };

    while (!dw.aborted.load(.Unordered)) {
        _ = std.os.poll(&fds, -1) catch |err| switch (err) {
            error.NetworkSubsystemFailed,
            error.SystemResources,
            => {
                const ts = std.time.milliTimestamp();
                if (last_crash) |lc| {
                    if (ts - lc < 500) return;
                }
                last_crash = ts;
                continue;
            },
            error.Unexpected => unreachable,
        };

        if (util.hasFlag(dw.notify_fd, std.os.POLL.IN)) {
            while (true) {
                const len = std.os.read(dw.notify_fd, &buf) catch |err| {
                    if (err == error.WouldBlock) break;
                    const ts = std.time.milliTimestamp();
                    if (last_crash) |lc| {
                        if (ts - lc < 500) return;
                    }
                    last_crash = ts;
                    break;
                };
                if (len == 0) break;

                var i: usize = 0;
                var evt: *inotify_event = undefined;
                while (i < buf.len) : (i += @sizeOf(inotify_event) + evt.len) {
                    evt = @ptrCast(*inotify_event, @alignCast(4, buf[i..]));
                    const evt_name = @ptrCast([*]u8, buf[i..])[@sizeOf(inotify_event) .. @sizeOf(inotify_event) + 8];

                    if (util.hasFlag(evt.mask, std.os.linux.IN.ISDIR) or !std.mem.startsWith(u8, evt_name, "pcm"))
                        continue;

                    dw.mutex.lock();
                    defer dw.mutex.unlock();

                    dw.scan_queued.store(true, .Release);
                    dw.cond.signal();
                }
            }
        }
    }
}

pub fn flush(self: *Alsa) !void {
    if (self.device_watcher) |*dw| {
        dw.mutex.lock();
        defer dw.mutex.unlock();

        dw.scan_queued.store(false, .Release);
    }
    try self.refreshDevices();
}

pub fn wait(self: *Alsa) !void {
    std.debug.assert(self.device_watcher != null);
    var dw = &self.device_watcher.?;

    dw.mutex.lock();
    defer dw.mutex.unlock();
    while (!dw.scan_queued.load(.Acquire))
        dw.cond.wait(&dw.mutex);

    dw.scan_queued.store(false, .Release);
    try self.refreshDevices();
}

pub fn wakeUp(self: *Alsa) void {
    std.debug.assert(self.device_watcher != null);
    var dw = &self.device_watcher.?;

    dw.lock();
    defer dw.unlock();
    dw.scan_queued.store(true, .Release);
    dw.cond.signal();
}

fn refreshDevices(self: *Alsa) !void {
    self.devices_info.clear(self.allocator);

    var card_info: ?*c.snd_ctl_card_info_t = null;
    _ = c.snd_ctl_card_info_malloc(&card_info);
    defer c.snd_ctl_card_info_free(card_info);

    var pcm_info: ?*c.snd_pcm_info_t = null;
    _ = c.snd_pcm_info_malloc(&pcm_info);
    defer c.snd_pcm_info_free(pcm_info);

    var card_idx: c_int = -1;
    if (c.snd_card_next(&card_idx) < 0)
        return error.SystemResources;

    while (card_idx >= 0) {
        var card_id_buf: [8]u8 = undefined;
        const card_id = std.fmt.bufPrintZ(&card_id_buf, "hw:{d}", .{card_idx}) catch break;

        var ctl: ?*c.snd_ctl_t = undefined;
        _ = switch (c.snd_ctl_open(&ctl, card_id.ptr, 0)) {
            0 => {},
            -@intCast(i16, @enumToInt(std.os.E.NOENT)) => break,
            else => return error.OpeningDevice,
        };
        defer _ = c.snd_ctl_close(ctl);

        if (c.snd_ctl_card_info(ctl, card_info) < 0)
            return error.SystemResources;
        const card_name = c.snd_ctl_card_info_get_name(card_info);

        var dev_idx: c_int = -1;
        if (c.snd_ctl_pcm_next_device(ctl, &dev_idx) < 0)
            return error.SystemResources;
        if (dev_idx < 0) break;

        c.snd_pcm_info_set_device(pcm_info, @intCast(c_uint, dev_idx));
        c.snd_pcm_info_set_subdevice(pcm_info, 0);
        const dev_name = c.snd_pcm_info_get_name(pcm_info);

        for (&[_]Device.Aim{ .playback, .capture }) |aim| {
            const snd_stream = aimToStream(aim);
            c.snd_pcm_info_set_stream(pcm_info, snd_stream);
            const err = c.snd_ctl_pcm_info(ctl, pcm_info);
            switch (@intToEnum(std.os.E, -err)) {
                .SUCCESS => {},
                .NOENT,
                .NXIO,
                .NODEV,
                => break,
                else => return error.SystemResources,
            }

            var buf: [9]u8 = undefined; // 'hw' + max(card|device) * 2 + ':' + \0
            const id = std.fmt.bufPrintZ(&buf, "hw:{d},{d}", .{ card_idx, dev_idx }) catch continue;

            var pcm: ?*c.snd_pcm_t = null;
            if (c.snd_pcm_open(&pcm, id.ptr, snd_stream, 0) < 0)
                continue;
            defer _ = c.snd_pcm_close(pcm);

            var params: ?*c.snd_pcm_hw_params_t = null;
            _ = c.snd_pcm_hw_params_malloc(&params);
            defer c.snd_pcm_hw_params_free(params);
            if (c.snd_pcm_hw_params_any(pcm, params) < 0)
                continue;

            if (c.snd_pcm_hw_params_can_pause(params) == 0)
                continue;

            const device = Device{
                .aim = aim,
                .channels = blk: {
                    const chmap = c.snd_pcm_query_chmaps(pcm);
                    if (chmap) |_| {
                        defer c.snd_pcm_free_chmaps(chmap);

                        if (chmap[0] == null) continue;

                        const n_ch = chmap[0][0].map.channels;
                        if (n_ch <= 0 or n_ch > max_channels) continue;

                        var channels = try self.allocator.alloc(Channel, n_ch);
                        for (channels) |*ch, i|
                            ch.*.id = fromCHMAP(chmap[0][0].map.pos()[i]);
                        break :blk channels;
                    } else {
                        continue;
                    }
                },
                .formats = blk: {
                    var fmt_mask: ?*c.snd_pcm_format_mask_t = null;
                    _ = c.snd_pcm_format_mask_malloc(&fmt_mask);
                    defer c.snd_pcm_format_mask_free(fmt_mask);
                    c.snd_pcm_format_mask_none(fmt_mask);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S8);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U8);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S16_LE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S16_BE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U16_LE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U16_BE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S24_3LE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S24_3BE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U24_3LE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U24_3BE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S24_LE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S24_BE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U24_LE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U24_BE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S32_LE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S32_BE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U32_LE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U32_BE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_FLOAT_LE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_FLOAT_BE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_FLOAT64_LE);
                    c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_FLOAT64_BE);
                    c.snd_pcm_hw_params_get_format_mask(params, fmt_mask);

                    var fmt_arr = std.ArrayList(Format).init(self.allocator);
                    inline for (std.meta.tags(Format)) |format| {
                        if (c.snd_pcm_format_mask_test(
                            fmt_mask,
                            toPCM_FORMAT(format) catch unreachable,
                        ) != 0) {
                            try fmt_arr.append(format);
                        }
                    }

                    break :blk fmt_arr.toOwnedSlice();
                },
                .rate_range = blk: {
                    var rate_min: c_uint = 0;
                    var rate_max: c_uint = 0;
                    if (c.snd_pcm_hw_params_get_rate_min(params, &rate_min, null) < 0)
                        continue;
                    if (c.snd_pcm_hw_params_get_rate_max(params, &rate_max, null) < 0)
                        continue;
                    break :blk .{
                        .min = rate_min,
                        .max = rate_max,
                    };
                },
                .id = try self.allocator.dupeZ(u8, id),
                .name = try std.fmt.allocPrintZ(self.allocator, "{s} {s}", .{ card_name, dev_name }),
            };

            try self.devices_info.list.append(self.allocator, device);

            if (self.devices_info.default(aim) == null and dev_idx == 0) {
                self.devices_info.setDefault(aim, self.devices_info.list.items.len - 1);
            }
        }

        if (c.snd_card_next(&card_idx) < 0)
            return error.SystemResources;
    }
}

pub const PlayerData = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    mutex: std.Thread.Mutex,
    aborted: std.atomic.Atomic(bool),
    sample_buffer: []u8,
    pcm: *c.snd_pcm_t,
    mixer: *c.snd_mixer_t,
    selem: *c.snd_mixer_selem_id_t,
    mixer_elm: *c.snd_mixer_elem_t,
    period_size: c_ulong,
    vol_range: Range(c_long),
};

pub fn openPlayer(self: *Alsa, player: *Player, device: Device) !void {
    const format = toPCM_FORMAT(player.format) catch unreachable;
    var pcm: ?*c.snd_pcm_t = null;
    var mixer: ?*c.snd_mixer_t = null;
    var selem: ?*c.snd_mixer_selem_id_t = null;
    var mixer_elm: ?*c.snd_mixer_elem_t = null;
    var period_size: c_ulong = 0;
    var vol_min: c_long = 0;
    var vol_max: c_long = 0;

    if (c.snd_pcm_open(&pcm, device.id.ptr, aimToStream(device.aim), 0) < 0)
        return error.OpeningDevice;
    errdefer _ = c.snd_pcm_close(pcm);

    {
        var hw_params: ?*c.snd_pcm_hw_params_t = null;

        if ((c.snd_pcm_set_params(
            pcm,
            format,
            c.SND_PCM_ACCESS_RW_INTERLEAVED,
            @intCast(c_uint, player.device.channels.len),
            player.sample_rate,
            1,
            default_latency,
        )) < 0)
            return error.OpeningDevice;
        errdefer _ = c.snd_pcm_hw_free(pcm);

        if (c.snd_pcm_hw_params_malloc(&hw_params) < 0)
            return error.OpeningDevice;
        defer c.snd_pcm_hw_params_free(hw_params);

        if (c.snd_pcm_hw_params_current(pcm, hw_params) < 0)
            return error.OpeningDevice;

        if (c.snd_pcm_hw_params_get_period_size(hw_params, &period_size, null) < 0)
            return error.OpeningDevice;
    }

    {
        var chmap: c.snd_pcm_chmap_t = .{ .channels = @intCast(c_uint, player.device.channels.len) };

        for (player.device.channels) |ch, i|
            chmap.pos()[i] = toCHMAP(ch.id);

        if (c.snd_pcm_set_chmap(pcm, &chmap) < 0)
            return error.IncompatibleDevice;
    }

    {
        if (c.snd_mixer_open(&mixer, 0) < 0)
            return error.OutOfMemory;

        const card_id = try self.allocator.dupeZ(u8, std.mem.sliceTo(device.id, ','));
        defer self.allocator.free(card_id);

        if (c.snd_mixer_attach(mixer, card_id.ptr) < 0)
            return error.IncompatibleDevice;

        if (c.snd_mixer_selem_register(mixer, null, null) < 0)
            return error.OpeningDevice;

        if (c.snd_mixer_load(mixer) < 0)
            return error.OpeningDevice;

        if (c.snd_mixer_selem_id_malloc(&selem) < 0)
            return error.OutOfMemory;
        errdefer c.snd_mixer_selem_id_free(selem);

        c.snd_mixer_selem_id_set_index(selem, 0);
        c.snd_mixer_selem_id_set_name(selem, "Master");

        mixer_elm = c.snd_mixer_find_selem(mixer, selem) orelse
            return error.IncompatibleDevice;
        if (c.snd_mixer_selem_get_playback_volume_range(mixer_elm, &vol_min, &vol_max) < 0)
            return error.OpeningDevice;
    }

    player.backend_data = .{
        .Alsa = .{
            .allocator = self.allocator,
            .mutex = .{},
            .sample_buffer = try self.allocator.alloc(
                u8,
                player.bytesPerFrame() * period_size,
            ),
            .aborted = .{ .value = false },
            .vol_range = .{ .min = vol_min, .max = vol_max },
            .pcm = pcm.?,
            .mixer = mixer.?,
            .selem = selem.?,
            .mixer_elm = mixer_elm.?,
            .period_size = period_size,
            .thread = undefined,
        },
    };
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

    for (self.device.channels) |*ch, i| {
        ch.*.ptr = bd.sample_buffer.ptr + i * self.bytesPerSample();
    }

    var err: error{WriteFailed}!void = {};
    while (!bd.aborted.load(.Unordered)) {
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

pub fn playerPlay(self: *Player) !void {
    const bd = &self.backend_data.Alsa;

    if (c.snd_pcm_state(bd.pcm) == c.SND_PCM_STATE_PAUSED) {
        if (c.snd_pcm_pause(bd.pcm, 0) < 0)
            return error.CannotPlay;
    }
}

pub fn playerPause(self: *Player) !void {
    const bd = &self.backend_data.Alsa;

    if (c.snd_pcm_state(bd.pcm) != c.SND_PCM_STATE_PAUSED) {
        if (c.snd_pcm_pause(bd.pcm, 1) < 0)
            return error.CannotPause;
    }
}

pub fn playerPaused(self: *Player) bool {
    const bd = &self.backend_data.Alsa;

    return c.snd_pcm_state(bd.pcm) == c.SND_PCM_STATE_PAUSED;
}

pub fn playerSetVolume(self: *Player, volume: f32) !void {
    var bd = &self.backend_data.Alsa;

    bd.mutex.lock();
    defer bd.mutex.unlock();

    const dist = @intToFloat(f32, bd.vol_range.max - bd.vol_range.min);
    if (c.snd_mixer_selem_set_playback_volume_all(
        bd.mixer_elm,
        @floatToInt(c_long, dist * volume) + bd.vol_range.min,
    ) < 0)
        return error.CannotSetVolume;
}

pub fn playerVolume(self: *Player) !f32 {
    var bd = &self.backend_data.Alsa;

    bd.mutex.lock();
    defer bd.mutex.unlock();

    var volume: c_long = 0;
    var channel: c_int = 0;

    while (channel < c.SND_MIXER_SCHN_LAST) : (channel += 1) {
        if (c.snd_mixer_selem_has_playback_channel(bd.mixer_elm, channel) == 1) {
            if (c.snd_mixer_selem_get_playback_volume(bd.mixer_elm, channel, &volume) == 0)
                break;
        }
    }

    if (channel == c.SND_MIXER_SCHN_LAST)
        return error.CannotGetVolume;

    return @intToFloat(f32, volume) / @intToFloat(f32, bd.vol_range.max - bd.vol_range.min);
}

pub fn deviceDeinit(self: Device, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.name);
    allocator.free(self.formats);
    allocator.free(self.channels);
}

pub fn aimToStream(aim: Device.Aim) c_uint {
    return switch (aim) {
        .playback => c.SND_PCM_STREAM_PLAYBACK,
        .capture => c.SND_PCM_STREAM_CAPTURE,
    };
}

pub fn toPCM_FORMAT(format: Format) !c.snd_pcm_format_t {
    return switch (format) {
        .u8 => c.SND_PCM_FORMAT_U8,
        .i16 => if (is_little) c.SND_PCM_FORMAT_S16_LE else c.SND_PCM_FORMAT_S16_BE,
        .i24 => if (is_little) c.SND_PCM_FORMAT_S24_3LE else c.SND_PCM_FORMAT_S24_3BE,
        .i24_3b => if (is_little) c.SND_PCM_FORMAT_S24_LE else c.SND_PCM_FORMAT_S24_BE,
        .i32 => if (is_little) c.SND_PCM_FORMAT_S32_LE else c.SND_PCM_FORMAT_S32_BE,
        .f32 => if (is_little) c.SND_PCM_FORMAT_FLOAT_LE else c.SND_PCM_FORMAT_FLOAT_BE,
        .f64 => if (is_little) c.SND_PCM_FORMAT_FLOAT64_LE else c.SND_PCM_FORMAT_FLOAT64_BE,
    };
}

pub fn fromCHMAP(pos: c_uint) ChannelId {
    return switch (pos) {
        c.SND_CHMAP_UNKNOWN, c.SND_CHMAP_NA => unreachable, // TODO
        c.SND_CHMAP_MONO, c.SND_CHMAP_FC => .front_center,
        c.SND_CHMAP_FL => .front_left,
        c.SND_CHMAP_FR => .front_right,
        c.SND_CHMAP_LFE => .lfe,
        c.SND_CHMAP_SL => .side_left,
        c.SND_CHMAP_SR => .side_right,
        c.SND_CHMAP_RC => .back_center,
        c.SND_CHMAP_FLC => .front_left_center,
        c.SND_CHMAP_FRC => .front_right_center,
        c.SND_CHMAP_TC => .top_center,
        c.SND_CHMAP_TFL => .top_front_left,
        c.SND_CHMAP_TFR => .top_front_right,
        c.SND_CHMAP_TFC => .top_front_center,
        c.SND_CHMAP_TRL => .top_back_left,
        c.SND_CHMAP_TRR => .top_back_right,
        c.SND_CHMAP_TRC => .top_back_center,

        else => unreachable,
    };
}

pub fn toCHMAP(pos: ChannelId) c_uint {
    return switch (pos) {
        .front_center => c.SND_CHMAP_FC,
        .front_left => c.SND_CHMAP_FL,
        .front_right => c.SND_CHMAP_FR,
        .lfe => c.SND_CHMAP_LFE,
        .side_left => c.SND_CHMAP_SL,
        .side_right => c.SND_CHMAP_SR,
        .back_center => c.SND_CHMAP_RC,
        .front_left_center => c.SND_CHMAP_FLC,
        .front_right_center => c.SND_CHMAP_FRC,
        .top_center => c.SND_CHMAP_TC,
        .top_front_left => c.SND_CHMAP_TFL,
        .top_front_right => c.SND_CHMAP_TFR,
        .top_front_center => c.SND_CHMAP_TFC,
        .top_back_left => c.SND_CHMAP_TRL,
        .top_back_right => c.SND_CHMAP_TRR,
        .top_back_center => c.SND_CHMAP_TRC,
    };
}
