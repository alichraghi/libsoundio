const std = @import("std");
const c = @import("Alsa/c.zig");
const queryCookedDevices = @import("Alsa/device.zig").queryCookedDevices;
const queryRawDevices = @import("Alsa/device.zig").queryRawDevices;
const alsa_util = @import("Alsa/util.zig");
const Device = @import("main.zig").Device;
const Outstream = @import("main.zig").Outstream;
const ChannelArea = @import("main.zig").ChannelArea;
const ConnectOptions = @import("main.zig").ConnectOptions;
const ShutdownFn = @import("main.zig").ShutdownFn;
const DevicesInfo = @import("main.zig").DevicesInfo;
const max_channels = @import("main.zig").max_channels;
const util = @import("util.zig");
const linux = std.os.linux;

const Alsa = @This();

const max_snd_file_len = 16;

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex,
cond: std.Thread.Condition,
thread: std.Thread,
devices_info: DevicesInfo,
pending_files: std.ArrayListUnmanaged([]const u8),
notify_fd: linux.fd_t,
notify_wd: linux.fd_t,
notify_pipe_fd: [2]linux.fd_t,
shutdownFn: ShutdownFn,
userdata: ?*anyopaque,
aborted: std.atomic.Atomic(bool),
device_scan_queued: std.atomic.Atomic(bool),

pub fn connect(allocator: std.mem.Allocator, options: ConnectOptions) !*Alsa {
    var self = try allocator.create(Alsa);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .mutex = std.Thread.Mutex{},
        .cond = std.Thread.Condition{},
        .thread = undefined,
        .devices_info = DevicesInfo.init(),
        .pending_files = .{},
        .notify_fd = undefined,
        .notify_wd = undefined,
        .notify_pipe_fd = undefined,
        .shutdownFn = options.shutdownFn orelse defaultShutdownFn,
        .userdata = options.userdata,
        .aborted = std.atomic.Atomic(bool).init(false),
        .device_scan_queued = std.atomic.Atomic(bool).init(false),
    };

    self.notify_fd = std.os.inotify_init1(linux.IN.NONBLOCK) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.SystemResources,
        => return error.SystemResources,
        error.Unexpected => unreachable,
    };

    self.notify_wd = std.os.inotify_add_watch(
        self.notify_fd,
        "/dev/snd",
        linux.IN.CREATE | linux.IN.CLOSE_WRITE | linux.IN.DELETE,
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

    self.notify_pipe_fd = std.os.pipe2(linux.O.NONBLOCK) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return error.SystemResources,
        error.Unexpected => unreachable,
    };

    _ = c.snd_lib_error_set_handler(@ptrCast(c.snd_lib_error_handler_t, &alsaErrorHandler));

    self.wakeUpDevicePoll() catch return error.SystemResources;
    self.thread = std.Thread.spawn(.{}, deviceEventLoop, .{self}) catch |err| switch (err) {
        error.ThreadQuotaExceeded,
        error.SystemResources,
        error.LockedMemoryLimitExceeded,
        => return error.SystemResources,
        error.OutOfMemory => return error.OutOfMemory,
        error.Unexpected => unreachable,
    };

    return self;
}

pub fn deinit(self: *Alsa) void {
    self.aborted.store(true, .Monotonic);
    self.wakeUpDevicePoll() catch {};
    self.thread.join();
    std.os.close(self.notify_pipe_fd[0]);
    std.os.close(self.notify_pipe_fd[1]);
    std.os.inotify_rm_watch(self.notify_fd, self.notify_wd);
    std.os.close(self.notify_fd);

    self.devices_info.deinit(self.allocator);
    for (self.pending_files.items) |file|
        self.allocator.free(file);
    self.pending_files.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn defaultShutdownFn(_: ?*anyopaque) void {
    @panic("Unhandled Error");
}

fn wakeUpDevicePoll(self: *Alsa) !void {
    _ = try std.os.write(self.notify_pipe_fd[1], "a");
}

fn alsaErrorHandler() callconv(.C) void {}

fn deviceEventLoop(self: *Alsa) !void {
    var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
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
        if (self.aborted.load(.Monotonic)) break;
        _ = std.os.poll(&fds, -1) catch |err| switch (err) {
            error.NetworkSubsystemFailed,
            error.SystemResources,
            => {
                self.shutdownFn(self.userdata);
                return;
            },
            error.Unexpected => unreachable,
        };
        var got_rescan_event = false;
        if (util.hasFlag(fds[0].revents, linux.POLL.IN)) {
            while (true) {
                const len = std.os.read(self.notify_fd, &buf) catch |err| {
                    if (err == error.WouldBlock) break;
                    self.shutdownFn(self.userdata);
                    return;
                };
                if (len == 0) break;

                var event: *linux.inotify_event = undefined;
                var i: usize = 0;
                while (i < buf.len) : (i += @sizeOf(linux.inotify_event) + event.len) {
                    event = @ptrCast(*linux.inotify_event, @alignCast(@alignOf(linux.inotify_event), buf[i..]));

                    if (!(util.hasFlag(event.mask, linux.IN.CLOSE_WRITE) or
                        util.hasFlag(event.mask, linux.IN.DELETE) or
                        util.hasFlag(event.mask, linux.IN.CREATE)))
                        continue;
                    if (util.hasFlag(event.mask, linux.IN.ISDIR))
                        continue;
                    if (event.len < 8 or std.mem.eql(u8, eventName(buf[i..], 8), "controlC"))
                        continue;

                    if (util.hasFlag(event.mask, linux.IN.CREATE)) {
                        const event_name = self.allocator.dupe(u8, eventName(buf[i..], event.len)) catch {
                            self.shutdownFn(self.userdata);
                            return;
                        };
                        self.pending_files.append(self.allocator, event_name) catch {
                            self.shutdownFn(self.userdata);
                            return;
                        };
                        continue;
                    }

                    if (self.pending_files.items.len > 0) {
                        if (!util.hasFlag(event.mask, linux.IN.CLOSE_WRITE))
                            continue;

                        for (self.pending_files.items) |file, j| {
                            if (std.mem.eql(u8, file, eventName(buf[i..], event.len))) {
                                self.allocator.free(self.pending_files.swapRemove(j));
                                if (self.pending_files.items.len == 0)
                                    got_rescan_event = true;
                                break;
                            }
                        }
                    } else if (util.hasFlag(event.mask, linux.IN.DELETE)) {
                        got_rescan_event = true;
                    }
                }
            }
        }
        if (util.hasFlag(fds[1].revents, linux.POLL.IN)) {
            got_rescan_event = true;
            while (true) {
                const len = std.os.read(self.notify_pipe_fd[0], &buf) catch |err| {
                    if (err == error.WouldBlock) break;
                    self.shutdownFn(self.userdata);
                    return;
                };
                if (len == 0) break;
            }
        }
        if (got_rescan_event) {
            if (self.mutex.tryLock()) {
                defer self.mutex.unlock();
                self.device_scan_queued.store(true, .Monotonic);
                self.cond.signal();
            }
        }
    }
}

fn eventName(self: []const u8, len: usize) []const u8 {
    return self.ptr[@sizeOf(linux.inotify_event) .. @sizeOf(linux.inotify_event) + std.math.min(max_snd_file_len, len)];
}

pub fn flushEvents(self: *Alsa) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.device_scan_queued.store(false, .Monotonic);
    try self.refreshDevices();
}

pub fn waitEvents(self: *Alsa) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (!self.device_scan_queued.load(.Acquire))
        self.cond.wait(&self.mutex);

    self.device_scan_queued.store(false, .Monotonic);
    try self.refreshDevices();
}

fn refreshDevices(self: *Alsa) !void {
    self.devices_info.clear(self.allocator);

    if (c.snd_config_update() < 0)
        return error.SystemResources;
    defer _ = c.snd_config_update_free_global();

    try queryCookedDevices(&self.devices_info, self.allocator);
    try queryRawDevices(&self.devices_info, self.allocator);
}

pub fn wakeUp(self: *Alsa) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.device_scan_queued.store(true, .Monotonic);
    self.cond.signal();
}

pub const OutstreamData = struct {
    alsa: *const Alsa,
    period_size: c.snd_pcm_uframes_t,
    sample_buffer: []u8,
    thread: std.Thread,
    pcm: ?*c.snd_pcm_t,
    aborted: std.atomic.Atomic(bool),
    clear_buffer: std.atomic.Atomic(bool),
};

pub fn openOutstream(self: *Alsa, outstream: *Outstream, device: Device) !void {
    outstream.backend_data = .{
        .Alsa = .{
            .alsa = self,
            .period_size = undefined,
            .sample_buffer = undefined,
            .pcm = null,
            .thread = undefined,
            .aborted = std.atomic.Atomic(bool).init(false),
            .clear_buffer = std.atomic.Atomic(bool).init(false),
        },
    };
    var bd = &outstream.backend_data.Alsa;

    const snd_stream = alsa_util.aimToStream(device.aim);
    if (c.snd_pcm_open(&bd.pcm, device.id.ptr, snd_stream, 0) < 0)
        return error.OpeningDevice;

    const format = alsa_util.toAlsaFormat(outstream.format) catch return error.IncompatibleBackend;
    if ((c.snd_pcm_set_params(
        bd.pcm,
        format,
        c.SND_PCM_ACCESS_RW_INTERLEAVED,
        @intCast(u6, outstream.layout.channels.len),
        outstream.sample_rate,
        @bitCast(u1, !device.is_raw),
        @floatToInt(c_uint, outstream.latency * std.time.us_per_s),
    )) < 0)
        return error.OpeningDevice;

    var hw_params: ?*c.snd_pcm_hw_params_t = null;
    _ = c.snd_pcm_hw_params_malloc(&hw_params);
    defer c.snd_pcm_hw_params_free(hw_params);
    if (c.snd_pcm_hw_params_current(bd.pcm, hw_params) < 0)
        return error.OpeningDevice;

    if (c.snd_pcm_hw_params_get_period_size(hw_params, &bd.period_size, null) < 0)
        return error.OpeningDevice;

    var buf_size: c.snd_pcm_uframes_t = 0;
    if (c.snd_pcm_hw_params_get_buffer_size(hw_params, &buf_size) < 0)
        return error.OpeningDevice;

    var chmap: c.snd_pcm_chmap_t = .{ .channels = @intCast(c_uint, outstream.layout.channels.len) };
    for (outstream.layout.channels.slice()) |ch, i| {
        chmap.pos()[i] = alsa_util.toAlsaChmapPos(ch);
    }
    if (c.snd_pcm_set_chmap(bd.pcm, &chmap) < 0)
        return error.IncompatibleDevice;

    bd.sample_buffer = try self.allocator.alloc(u8, buf_size);
}

pub fn outstreamDeinit(self: *Outstream) void {
    var bd = &self.backend_data.Alsa;
    bd.aborted.store(true, .Monotonic);
    bd.thread.join();
    _ = c.snd_pcm_close(bd.pcm);
    bd.alsa.allocator.free(bd.sample_buffer);
}

pub fn outstreamStart(self: *Outstream) !void {
    var bd = &self.backend_data.Alsa;
    bd.thread = std.Thread.spawn(.{}, outstreamLoop, .{self}) catch |err| switch (err) {
        error.ThreadQuotaExceeded,
        error.SystemResources,
        error.LockedMemoryLimitExceeded,
        => return error.SystemResources,
        error.OutOfMemory => return error.OutOfMemory,
        error.Unexpected => unreachable,
    };
}

fn outstreamLoop(self: *Outstream) void {
    var bd = &self.backend_data.Alsa;
    var areas: [max_channels]ChannelArea = undefined;
    for (self.layout.channels.slice()) |_, i| {
        areas[i].ptr = bd.sample_buffer.ptr + i * self.bytes_per_sample;
        areas[i].step = self.bytes_per_frame;
    }

    while (true) {
        if (bd.aborted.load(.Acquire)) return;
        var frames_left = bd.period_size;
        while (frames_left > 0) {
            var t = std.time.Timer.start() catch unreachable;
            self.writeFn(self, areas[0..self.layout.channels.len], frames_left);
            const written = c.snd_pcm_writei(bd.pcm, bd.sample_buffer.ptr, frames_left);
            if (written < 0) {
                switch (@intToEnum(linux.E, -written)) {
                    .AGAIN => continue,
                    .PIPE => {
                        _ = c.snd_pcm_prepare(bd.pcm);
                    },
                    .STRPIPE => {
                        while (true) {
                            const res = c.snd_pcm_resume(bd.pcm);
                            if (-res != @enumToInt(linux.E.AGAIN)) {
                                if (res < 0)
                                    _ = c.snd_pcm_prepare(bd.pcm);
                                break;
                            }
                            _ = std.os.poll(&.{}, 1) catch {
                                bd.alsa.shutdownFn(bd.alsa.userdata);
                                return;
                            };
                        }
                    },
                    else => {
                        bd.alsa.shutdownFn(bd.alsa.userdata);
                        return;
                    },
                }
                break;
            }
            frames_left -= @intCast(c_uint, written);
            std.debug.print("{d}\n", .{t.read() / std.time.ns_per_ms});
        }
    }
}

pub fn outstreamClearBuffer(self: *Outstream) void {
    _ = self;
}

pub fn outstreamPausePlay(self: *Outstream, pause: bool) !void {
    _ = self;
    _ = pause;
}

pub fn outstreamGetLatency(self: *Outstream) !f64 {
    _ = self;
    return undefined;
}

pub fn outstreamSetVolume(self: *Outstream, volume: f64) !void {
    _ = self;
    _ = volume;
}

pub fn outstreamVolume(self: *Outstream) error{}!f64 {
    _ = self;
    return undefined;
}

pub fn deviceDeinit(self: Device, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.name);
    allocator.free(self.formats);
}
