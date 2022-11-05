const std = @import("std");
const c = @cImport(@cInclude("asoundlib.h"));
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
device_scan_queued: std.atomic.Atomic(bool),

fn defaultShutdownFn(_: ?*anyopaque) void {
    unreachable;
}

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
        .device_scan_queued = std.atomic.Atomic(bool).init(false),
    };

    // IN.NONBLOCK
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
    // O.NONBLOCK
    self.notify_pipe_fd = std.os.pipe2(O.NONBLOCK) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return error.SystemResources,
        error.Unexpected => unreachable,
    };

    // _ = c.snd_lib_error_set_handler(null);
    self.wakeUpDevicePoll();
    self.thread = std.Thread.spawn(.{}, threadRun, .{self}) catch |err| switch (err) {
        error.ThreadQuotaExceeded,
        error.SystemResources,
        error.LockedMemoryLimitExceeded,
        => return error.SystemResources,
        error.OutOfMemory => return error.OutOfMemory,
        error.Unexpected => unreachable,
    };

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
                const len = std.os.read(self.notify_fd, &buf) catch |err| {
                    if (err == error.WouldBlock) break;
                    self.shutdownFn(self.userdata);
                    return;
                };
                if (len == 0) break;

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
                const len = std.os.read(self.notify_pipe_fd[0], &buf) catch |err| {
                    if (err == error.WouldBlock) break;
                    self.shutdownFn(self.userdata);
                    return;
                };
                if (len == 0) break;
            }
        }
        if (got_rescan_event) {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.device_scan_queued.store(true, .Monotonic);
            self.cond.signal();
        }
    }
}

fn wakeUpDevicePoll(self: *Alsa) void {
    _ = std.os.write(self.notify_pipe_fd[1], "a") catch unreachable;
}

pub fn refreshDevices(self: *Alsa) !void {
    if (c.snd_config_update_free_global() < 0)
        return error.SystemResources;
    if (c.snd_config_update() < 0)
        return error.SystemResources;

    var hints: []?*anyopaque = undefined;
    if (c.snd_device_name_hint(-1, "pcm", @ptrCast([*c][*c]?*anyopaque, &hints)) < 0)
        return error.OutOfMemory;
    defer _ = c.snd_device_name_free_hint(hints[0..].ptr);

    var i: usize = 0;
    while (hints[i] != null) : (i += 1) {
        const name = std.mem.span(c.snd_device_name_get_hint(hints[i], "NAME") orelse continue);
        defer std.heap.c_allocator.free(name); // TODO: require a c_allocator option

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
            continue;
        }

        const desc = c.snd_device_name_get_hint(hints[i], "DESC");
        var desc_first: ?[]const u8 = null;
        var desc_next: ?[]const u8 = null;
        if (desc != null) {
            var desc_iter = std.mem.split(u8, std.mem.span(desc), "\n");
            desc_first = desc_iter.first();
            desc_next = desc_iter.next();
        }

        // WTF!?
        var aims = std.BoundedArray(Device.Aim, 2).init(0) catch unreachable;

        if (c.snd_device_name_get_hint(hints[i], "IOID")) |io| {
            const io_span = std.mem.span(io);
            if (std.mem.eql(u8, io_span, "Output")) {
                aims.append(.output) catch unreachable;
            } else {
                aims.append(.input) catch unreachable;
            }
            std.heap.c_allocator.free(io_span);
        } else {
            aims.appendSlice(&.{ .output, .input }) catch unreachable;
        }

        for (aims.slice()) |aim| {
            var device = Device{
                .id = try self.allocator.dupeZ(u8, name),
                .name = blk: {
                    if (desc_first == null)
                        break :blk try self.allocator.dupeZ(u8, name);
                    if (desc_next == null)
                        break :blk try self.allocator.dupeZ(u8, desc_first.?);
                    break :blk try std.fmt.allocPrintZ(self.allocator, "{s}: {s}", .{ desc_first.?, desc_next.? });
                },
                .aim = aim,
                .is_raw = false,
                .layout = undefined,
                .formats = undefined,
                .format = undefined,
                .sample_rate = undefined,
                .sample_rate_range = undefined,
                .software_latency = undefined,
                .software_latency_range = undefined,
            };
            errdefer {
                self.allocator.free(device.id);
                self.allocator.free(device.name);
            }

            try self.devices_info.list.append(self.allocator, device);

            const is_default = std.mem.startsWith(u8, name, "default:") or std.mem.eql(u8, name, "default") or std.mem.startsWith(u8, name, "sysdefault:") or std.mem.eql(u8, name, "sysdefault");
            if (is_default) {
                switch (aim) {
                    .output => self.devices_info.default_output_index = self.devices_info.list.items.len,
                    .input => self.devices_info.default_input_index = self.devices_info.list.items.len,
                }
            }
        }
    }

    var card_index: c_int = -1;
    if (c.snd_card_next(&card_index) < 0)
        return error.SystemResources;

    var card_info = try self.allocator.create(snd_ctl_card_info_t);
    defer self.allocator.destroy(card_info);
    var pcm_info = try self.allocator.create(snd_pcm_info_t);
    defer self.allocator.destroy(pcm_info);

    while (card_index >= 0) {
        var handle: ?*c.snd_ctl_t = undefined;
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "hw:{d}", .{card_index}) catch unreachable;
        _ = switch (std.os.errno(c.snd_ctl_open(@ptrCast([*c]?*c.snd_ctl_t, &handle), name.ptr, 0))) {
            .SUCCESS => {},
            .NOENT => break,
            else => return error.OpeningDevice,
        };
        defer _ = c.snd_ctl_close(handle);

        if (std.os.errno(c.snd_ctl_card_info(handle, @ptrCast(*c.snd_ctl_card_info_t, card_info))) != .SUCCESS)
            return error.SystemResources;
        const card_name = c.snd_ctl_card_info_get_name(@ptrCast(*c.snd_ctl_card_info_t, card_info));

        var device_index: c_int = -1;
        while (true) {
            if (c.snd_ctl_pcm_next_device(handle, &device_index) < 0)
                return error.SystemResources;

            if (device_index < 0) break;

            c.snd_pcm_info_set_device(@ptrCast(*c.snd_pcm_info_t, pcm_info), @intCast(c_uint, device_index));
            c.snd_pcm_info_set_subdevice(@ptrCast(*c.snd_pcm_info_t, pcm_info), 0);

            for (&[_]Device.Aim{ .output, .input }) |aim| {
                const snd_stream: c.snd_pcm_stream_t = switch (aim) {
                    .output => c.SND_PCM_STREAM_PLAYBACK,
                    .input => c.SND_PCM_STREAM_CAPTURE,
                };
                c.snd_pcm_info_set_stream(@ptrCast(*c.snd_pcm_info_t, pcm_info), snd_stream);

                _ = switch (std.os.errno(c.snd_ctl_pcm_info(handle, @ptrCast(*c.snd_pcm_info_t, pcm_info)))) {
                    .SUCCESS => {},
                    .NOENT => continue,
                    else => return error.SystemResources,
                };

                const device_name = c.snd_pcm_info_get_name(@ptrCast(*c.snd_pcm_info_t, pcm_info));

                var device = Device{
                    .id = try std.fmt.allocPrintZ(self.allocator, "hw:{d},{d}", .{ card_index, device_index }),
                    .name = try std.fmt.allocPrintZ(self.allocator, "{s} {s}", .{ card_name, device_name }),
                    .aim = aim,
                    .is_raw = true,
                    .layout = undefined,
                    .formats = undefined,
                    .format = undefined,
                    .sample_rate = undefined,
                    .sample_rate_range = undefined,
                    .software_latency = undefined,
                    .software_latency_range = undefined,
                };
                errdefer {
                    self.allocator.free(device.id);
                    self.allocator.free(device.name);
                }

                try self.devices_info.list.append(self.allocator, device);
            }
        }

        if (std.os.errno(c.snd_card_next(&card_index)) != .SUCCESS)
            return error.SystemResources;
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
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.refreshDevices();
}

pub fn waitEvents(self: *Alsa) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (!self.device_scan_queued.load(.Acquire))
        self.cond.wait(&self.mutex);

    defer self.device_scan_queued.store(false, .Monotonic);
    try self.refreshDevices();
}

pub fn wakeUp(self: *Alsa) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.device_scan_queued.store(true, .Monotonic);
    self.cond.signal();
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
    allocator.free(self.id);
    allocator.free(self.name);
}

// Generated from types.h
pub const snd_pcm_sync_id_t = extern union {
    id: [16]u8,
    id16: [8]c_ushort,
    id32: [4]c_uint,
};

pub const snd_pcm_info_t = extern struct {
    device: c_uint,
    subdevice: c_uint,
    stream: c_int,
    card: c_int,
    id: [64]u8,
    name: [80]u8,
    subname: [32]u8,
    dev_class: c_int,
    dev_subclass: c_int,
    subdevices_count: c_uint,
    subdevices_avail: c_uint,
    sync: snd_pcm_sync_id_t,
    reserved: [64]u8,
};

pub const snd_ctl_card_info_t = extern struct {
    card: c_int,
    pad: c_int,
    id: [16]u8,
    driver: [16]u8,
    name: [32]u8,
    longname: [80]u8,
    reserved_: [16]u8,
    mixername: [80]u8,
    components: [128]u8,
};
