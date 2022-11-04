const std = @import("std");
const c = @cImport(@cInclude("alsa/asoundlib.h"));
const Device = @import("main.zig").Device;
const Outstream = @import("main.zig").Outstream;
const ChannelLayout = @import("main.zig").ChannelLayout;
const ChannelArea = @import("main.zig").ChannelArea;
const ConnectOptions = @import("main.zig").ConnectOptions;
const ShutdownFn = @import("main.zig").ShutdownFn;
const DevicesInfo = @import("main.zig").DevicesInfo;
const Range = @import("main.zig").Range;
const Format = @import("main.zig").Format;
const min_sample_rate = @import("main.zig").min_sample_rate;
const max_sample_rate = @import("main.zig").max_sample_rate;
const getLayoutByChannels = @import("channel_layout.zig").getLayoutByChannels;
const parseChannelId = @import("channel_layout.zig").parseChannelId;
const IN = std.os.linux.IN;
const O = std.os.O;
const POLL = std.os.POLL;
const InotifyEvent = std.os.linux.inotify_event;

const Alsa = @This();

const max_snd_file_len = 16;

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex,
cond: std.Thread.Condition,
thread: std.Thread,
notify_fd: std.os.linux.fd_t,
notify_wd: std.os.linux.fd_t,
notify_pipe_fd: [2]std.os.linux.fd_t,
devices_info: DevicesInfo,
userdata: ?*anyopaque,
shutdown_emmited: bool, // TODO: make this atomic
shutdownFn: ShutdownFn,
pending_files: std.ArrayListUnmanaged([]const u8),
aborted: std.atomic.Atomic(bool),

fn defaultShutdownFn(_: ?*anyopaque) void {}

pub fn connect(allocator: std.mem.Allocator, options: ConnectOptions) !*Alsa {
    var self = try allocator.create(Alsa);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .mutex = std.Thread.Mutex{},
        .cond = std.Thread.Condition{},
        .thread = undefined,
        .notify_fd = undefined,
        .notify_wd = undefined,
        .notify_pipe_fd = undefined,
        .devices_info = .{
            .list = .{},
            .default_output_index = 0,
            .default_input_index = 0,
        },
        .userdata = options.userdata,
        .shutdown_emmited = false,
        .shutdownFn = options.shutdownFn orelse defaultShutdownFn,
        .pending_files = .{},
        .aborted = std.atomic.Atomic(bool).init(false),
    };

    self.notify_fd = std.os.inotify_init1(IN.NONBLOCK) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.SystemResources,
        => return error.SystemResources,
        error.Unexpected => unreachable,
    };

    self.notify_wd = std.os.inotify_add_watch(
        self.notify_fd,
        "/dev/snd",
        IN.CREATE | IN.CLOSE_WRITE | IN.DELETE,
    ) catch |err| switch (err) {
        error.UserResourceLimitReached,
        error.FileNotFound,
        error.SystemResources,
        => return error.SystemResources,
        error.AccessDenied,
        error.NameTooLong,
        error.NotDir,
        error.WatchAlreadyExists,
        error.Unexpected,
        => unreachable,
    };
    self.notify_pipe_fd = std.os.pipe2(O.NONBLOCK) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return error.SystemResources,
        error.Unexpected => unreachable,
    };

    _ = c.snd_lib_error_set_handler(null);
    self.wakeUpDevicePoll();
    self.thread = std.Thread.spawn(.{}, threadRun, .{self}) catch |err| switch (err) {
        error.ThreadQuotaExceeded,
        error.SystemResources,
        error.LockedMemoryLimitExceeded,
        => return error.SystemResources,
        error.OutOfMemory => return error.OutOfMemory,
        error.Unexpected => unreachable,
    };

    try self.refreshDevices();
    return self;
}

fn eventName(self: [*]const u8, len: usize) []const u8 {
    return self[@sizeOf(InotifyEvent) .. @sizeOf(InotifyEvent) + len];
}

fn threadRun(self: *Alsa) !void {
    var buf: [4096]u8 align(@alignOf(InotifyEvent)) = undefined;
    var fds = [2]std.os.pollfd{
        .{
            .fd = self.notify_fd,
            .events = POLL.IN,
            .revents = 0,
        },
        .{
            .fd = self.notify_pipe_fd[0],
            .events = POLL.IN,
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
        if (fds[0].revents & POLL.IN != 0) {
            while (true) {
                const len = std.c.read(self.notify_fd, &buf, buf.len);
                if (len < 0) {
                    switch (std.os.errno(len)) {
                        .FAULT,
                        .INVAL,
                        .BADF,
                        .IO,
                        .ISDIR,
                        => {
                            self.shutdownFn(self.userdata);
                            return;
                        },
                        .INTR, .AGAIN => continue,
                        else => unreachable,
                    }
                } else if (len == 0) break;

                var i: usize = 0;
                var event: *InotifyEvent = undefined;
                while (i < buf.len) : (i += @sizeOf(InotifyEvent) + event.len) {
                    event = @ptrCast(*InotifyEvent, @alignCast(@alignOf(InotifyEvent), buf[i..]));

                    if (!(event.mask & IN.CLOSE_WRITE != 0 or
                        event.mask & IN.DELETE != 0 or
                        event.mask & IN.CREATE != 0) or
                        event.mask & IN.ISDIR != 0 or
                        event.len < 8 or
                        std.mem.eql(u8, eventName(buf[i..].ptr, 8), "controlC"))
                        continue;

                    if (event.mask & IN.CREATE != 0) {
                        const event_name = self.allocator.dupe(u8, eventName(buf[i..].ptr, std.math.min(max_snd_file_len, event.len))) catch {
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
                        // At this point ignore IN.DELETE in favor of waiting until the files
                        // opened with IN.CREATE have their IN.CLOSE_WRITE event.
                        if (event.mask & IN.CLOSE_WRITE == 0)
                            continue;

                        for (self.pending_files.items) |file, j| {
                            if (std.mem.eql(u8, file, eventName(buf[i..].ptr, std.math.min(max_snd_file_len, event.len)))) {
                                self.allocator.free(self.pending_files.swapRemove(j));
                                if (self.pending_files.items.len == 0)
                                    got_rescan_event = true;
                                break;
                            }
                        }
                    } else if (event.mask & IN.DELETE != 0) {
                        // We are not waiting on created files to be closed, so when
                        // a delete happens we act on it.
                        got_rescan_event = true;
                    }
                }
            }
        }
        if (fds[1].revents & POLL.IN != 0) {
            got_rescan_event = true;
            while (true) {
                const len = std.c.read(self.notify_pipe_fd[0], &buf, buf.len);
                if (len < 0) {
                    switch (std.os.errno(len)) {
                        .FAULT,
                        .INVAL,
                        .BADF,
                        .IO,
                        .ISDIR,
                        => {
                            self.shutdownFn(self.userdata);
                            return;
                        },
                        .INTR, .AGAIN => break,
                        else => unreachable,
                    }
                } else if (len == 0) break;
            }
        }
        if (got_rescan_event) {
            self.refreshDevices() catch {
                self.shutdownFn(self.userdata);
                return;
            };
        }
    }
}

fn wakeUpDevicePoll(self: *Alsa) void {
    const res = std.os.errno(std.c.write(self.notify_pipe_fd[1], "a", 1));
    std.debug.assert(res != .BADF);
    std.debug.assert(res != .IO);
    std.debug.assert(res != .NOSPC);
    std.debug.assert(res != .PERM);
    std.debug.assert(res != .PIPE);
    std.debug.assert(res == .SUCCESS);
}

pub fn refreshDevices(self: *Alsa) !void {
    if (c.snd_config_update_free_global() < 0 or c.snd_config_update() < 0)
        return error.SystemResources;

    var hints: [*c][*c]?*anyopaque = null;
    if (c.snd_device_name_hint(-1, "pcm", hints) < 0)
        return error.OutOfMemory;

    // var sysdefault_output_index = -1;
    // var sysdefault_input_index = -1;

    var i: usize = 0;
    while (hints[i] != null) : (i += 1) {
        const name = std.mem.span(c.snd_device_name_get_hint(hints[i], "NAME"));
        // null - libsoundio has its own dummy backend. API clients should use
        // that instead of alsa null device.
        if (std.mem.eql(u8, name, "null") or
            // all these surround devices are clutter
            std.mem.startsWith(u8, name, "front:") or
            std.mem.startsWith(u8, name, "surround21:") or
            std.mem.startsWith(u8, name, "surround40:") or
            std.mem.startsWith(u8, name, "surround41:") or
            std.mem.startsWith(u8, name, "surround50:") or
            std.mem.startsWith(u8, name, "surround51:") or
            std.mem.startsWith(u8, name, "surround71:"))
        {
            self.allocator.free(name);
            continue;
        }
    }
}

pub fn deinit(self: *Alsa) void {
    self.aborted.store(true, .Monotonic);
    self.wakeUpDevicePoll();
    self.thread.detach();
    for (self.devices_info.list.items) |device|
        deviceDeinit(device, self.allocator);
    for (self.pending_files.items) |file|
        self.allocator.free(file);
    self.devices_info.list.deinit(self.allocator);
    self.pending_files.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn flushEvents(self: *Alsa) !void {
    try self.refreshDevices();
}

pub fn waitEvents(self: *Alsa) !void {
    // while (!self.device_scan_queued.loadUnchecked())
    //     self.cond.wait(&self.mutex);

    // defer self.device_scan_queued.storeUnchecked(false);
    try self.refreshDevices();
}

pub fn wakeUp(self: *Alsa) void {
    _ = self;
}

pub fn getDevice(self: Alsa, aim: Device.Aim, index: ?usize) Device {
    _ = self;
    _ = aim;
    _ = index;
    return undefined;
}

pub fn devicesList(self: Alsa) []const Device {
    return self.devices_info.list.items;
}

const OpenStreamError = error{
    OutOfMemory,
    IncompatibleBackend,
    StreamDisconnected,
    OpeningDevice,
};

pub fn openOutstream(self: *Alsa, outstream: *Outstream, device: Device) !void {
    _ = self;
    _ = outstream;
    _ = device;
    return undefined;
}

pub fn outstreamDeinit(self: *Outstream) void {
    _ = self;
}

pub fn outstreamStart(self: *Outstream) !void {
    _ = self;
}

pub fn outstreamBeginWrite(self: *Outstream, frame_count: *usize) ![]const ChannelArea {
    _ = self;
    _ = frame_count;
    return undefined;
}

pub fn outstreamEndWrite(self: *Outstream) !void {
    _ = self;
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
    _ = self;
    _ = allocator;
    // allocator.free(self.id);
}
