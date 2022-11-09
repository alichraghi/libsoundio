const std = @import("std");
const c = @cImport(@cInclude("asoundlib.h"));
const Device = @import("main.zig").Device;
const Outstream = @import("main.zig").Outstream;
const ChannelLayout = @import("main.zig").ChannelLayout;
const ChannelArea = @import("main.zig").ChannelArea;
const ConnectOptions = @import("main.zig").ConnectOptions;
const ShutdownFn = @import("main.zig").ShutdownFn;
const DevicesInfo = @import("main.zig").DevicesInfo;
const ChannelId = @import("main.zig").ChannelId;
const Range = @import("main.zig").Range;
const Format = @import("main.zig").Format;
const max_channels = @import("main.zig").max_channels;
const min_sample_rate = @import("main.zig").min_sample_rate;
const max_sample_rate = @import("main.zig").max_sample_rate;
const builtin_channel_layouts = @import("channel_layout.zig").builtin_channel_layouts;
const getLayoutByChannels = @import("channel_layout.zig").getLayoutByChannels;
const getLayoutByChannelCount = @import("channel_layout.zig").getLayoutByChannelCount;
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
    self.devices_info.default_output_index = null;
    self.devices_info.default_input_index = null;
    for (self.devices_info.list.items) |device|
        device.deinit(self.allocator);
    self.devices_info.list.clearAndFree(self.allocator);

    if (c.snd_config_update_free_global() < 0)
        return error.SystemResources;
    if (c.snd_config_update() < 0)
        return error.SystemResources;

    var card_index: c_int = -1;
    if (c.snd_card_next(&card_index) < 0)
        return error.SystemResources;

    var card_info: ?*c.snd_ctl_card_info_t = null;
    _ = c.snd_ctl_card_info_malloc(&card_info);
    defer c.snd_ctl_card_info_free(card_info);

    var pcm_info: ?*c.snd_pcm_info_t = null;
    _ = c.snd_pcm_info_malloc(&pcm_info);
    defer c.snd_pcm_info_free(pcm_info);

    while (card_index >= 0) {
        var handle: ?*c.snd_ctl_t = undefined;
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "hw:{d}", .{card_index}) catch unreachable;
        _ = switch (c.snd_ctl_open(&handle, name.ptr, 0)) {
            0 => {},
            -@intCast(i16, @enumToInt(std.os.linux.E.NOENT)) => break,
            else => return error.OpeningDevice,
        };
        defer _ = c.snd_ctl_close(handle);

        if (c.snd_ctl_card_info(handle, @ptrCast(*c.snd_ctl_card_info_t, card_info)) < 0)
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
                const snd_stream = aimToStream(aim);
                c.snd_pcm_info_set_stream(@ptrCast(*c.snd_pcm_info_t, pcm_info), snd_stream);

                _ = switch (c.snd_ctl_pcm_info(handle, @ptrCast(*c.snd_pcm_info_t, pcm_info))) {
                    0 => {},
                    -@intCast(i16, @enumToInt(std.os.linux.E.NOENT)) => break,
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
                    .latency_range = undefined,
                };
                errdefer {
                    self.allocator.free(device.id);
                    self.allocator.free(device.name);
                }

                self.probeDevice(&device) catch {
                    std.debug.print("{s} Skipped\n", .{device.id}); // TODO
                    self.allocator.free(device.id);
                    self.allocator.free(device.name);
                    continue;
                };

                try self.devices_info.list.append(self.allocator, device);

                if (self.devices_info.defaultIndex(device.aim) == null and
                    std.mem.startsWith(u8, device.id, "hw:") and std.mem.endsWith(u8, device.id, ",0"))
                {
                    self.devices_info.setDefaultIndex(device.aim, self.devices_info.list.items.len - 1);
                }
            }
        }

        if (c.snd_card_next(&card_index) < 0)
            return error.SystemResources;
    }
}

fn aimToStream(aim: Device.Aim) c_uint {
    return switch (aim) {
        .output => c.SND_PCM_STREAM_PLAYBACK,
        .input => c.SND_PCM_STREAM_CAPTURE,
    };
}

const prioritized_access_types = &[_]c.snd_pcm_access_t{
    c.SND_PCM_ACCESS_MMAP_INTERLEAVED,
    c.SND_PCM_ACCESS_MMAP_NONINTERLEAVED,
    c.SND_PCM_ACCESS_MMAP_COMPLEX,
    c.SND_PCM_ACCESS_RW_INTERLEAVED,
    c.SND_PCM_ACCESS_RW_NONINTERLEAVED,
};

fn setAccess(handle: *c.snd_pcm_t, hw_params: *c.snd_pcm_hw_params_t) !c.snd_pcm_access_t {
    for (prioritized_access_types) |access| {
        if (std.os.errno(c.snd_pcm_hw_params_set_access(handle, hw_params, access)) == .SUCCESS)
            return access;
    }
    return error.OpeningDevice;
}

// TODO: a test to make sure this is exact same as `supported_alsa_formats`
fn toAlsaFormat(format: Format) !c.snd_pcm_format_t {
    return switch (format) {
        .s8 => c.SND_PCM_FORMAT_S8,
        .u8 => c.SND_PCM_FORMAT_U8,
        .s16le => c.SND_PCM_FORMAT_S16_LE,
        .s16be => c.SND_PCM_FORMAT_S16_BE,
        .u16le => c.SND_PCM_FORMAT_U16_LE,
        .u16be => c.SND_PCM_FORMAT_U16_BE,
        .s24_32le => c.SND_PCM_FORMAT_S24_LE,
        .s24_32be => c.SND_PCM_FORMAT_S24_BE,
        .u24_32le => c.SND_PCM_FORMAT_U24_LE,
        .u24_32be => c.SND_PCM_FORMAT_U24_BE,
        .s32le => c.SND_PCM_FORMAT_S32_LE,
        .s32be => c.SND_PCM_FORMAT_S32_BE,
        .u32le => c.SND_PCM_FORMAT_U32_LE,
        .u32be => c.SND_PCM_FORMAT_U32_BE,
        .float32le => c.SND_PCM_FORMAT_FLOAT_LE,
        .float32be => c.SND_PCM_FORMAT_FLOAT_BE,
        .float64le => c.SND_PCM_FORMAT_FLOAT64_LE,
        .float64be => c.SND_PCM_FORMAT_FLOAT64_BE,
        else => error.UnsupportedFormat,
    };
}

fn probeDevice(self: *Alsa, device: *Device) !void {
    var handle: ?*c.snd_pcm_t = null;
    const snd_stream = aimToStream(device.aim);

    if (c.snd_pcm_open(&handle, device.id.ptr, snd_stream, 0) < 0)
        return error.OpeningDevice;
    defer _ = c.snd_pcm_close(handle);

    var hw_params: ?*c.snd_pcm_hw_params_t = null;
    _ = c.snd_pcm_hw_params_malloc(&hw_params);
    defer c.snd_pcm_hw_params_free(hw_params);

    if (c.snd_pcm_hw_params_any(handle, hw_params) < 0)
        return error.OpeningDevice;

    if (c.snd_pcm_hw_params_set_rate_resample(handle, hw_params, @bitCast(u1, !device.is_raw)) < 0) // TODO: revert is_raw?
        return error.OpeningDevice;

    if (c.snd_pcm_hw_params_get_rate_min(hw_params, &device.sample_rate_range.min, null) < 0)
        return error.OpeningDevice;
    if (c.snd_pcm_hw_params_set_rate_last(handle, hw_params, &device.sample_rate_range.max, null) < 0)
        return error.OpeningDevice;
    if (c.snd_pcm_hw_params_get_rate(hw_params, &device.sample_rate, null) < 0)
        return error.OpeningDevice;

    const one_over_actual_rate = 1.0 / @intToFloat(f32, device.sample_rate_range.max);

    var min_frames: c.snd_pcm_uframes_t = 0;
    var max_frames: c.snd_pcm_uframes_t = 0;
    if (c.snd_pcm_hw_params_get_buffer_size_min(hw_params, &min_frames) < 0)
        return error.OpeningDevice;
    if (c.snd_pcm_hw_params_get_buffer_size_max(hw_params, &max_frames) < 0)
        return error.OpeningDevice;

    device.latency_range.min = @intToFloat(f32, min_frames) * one_over_actual_rate;
    device.latency_range.max = @intToFloat(f32, max_frames) * one_over_actual_rate;

    if (c.snd_pcm_hw_params_set_buffer_size_first(handle, hw_params, &min_frames) < 0)
        return error.OpeningDevice;

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

    if (c.snd_pcm_hw_params_set_format_mask(handle, hw_params, fmt_mask) < 0)
        return error.OpeningDevice;
    c.snd_pcm_hw_params_get_format_mask(hw_params, fmt_mask);

    var fmt_arr = std.ArrayList(Format).init(self.allocator);
    for (alsa_supported_formats) |format| {
        if (c.snd_pcm_format_mask_test(fmt_mask, toAlsaFormat(format) catch unreachable) != 0)
            try fmt_arr.append(format);
    }
    device.formats = fmt_arr.toOwnedSlice();
    errdefer self.allocator.free(device.formats);

    const chmap = c.snd_pcm_get_chmap(handle);
    if (chmap != null) {
        defer std.heap.c_allocator.destroy(chmap);
        if (chmap.*.channels <= 0) return error.OpeningDevice;

        device.layout.channels = ChannelLayout.Array.init(std.math.min(max_channels, chmap.*.channels)) catch unreachable;
        for (device.layout.channels.slice()) |*pos, i|
            pos.* = fromAlsaChmapPos(chmap.*.pos()[i]);
        device.layout = getLayoutByChannels(device.layout.channels.slice()) orelse return error.OpeningDevice;
    } else {
        var min_channels: c_uint = 0;
        if (c.snd_pcm_hw_params_get_channels_min(hw_params, &min_channels) < 0)
            return error.OpeningDevice;
        device.layout = getLayoutByChannelCount(@intCast(u6, min_channels)) orelse return error.OpeningDevice;
    }
}

fn fromAlsaChmapPos(pos: c_uint) ChannelId {
    return switch (pos) {
        c.SND_CHMAP_UNKNOWN, c.SND_CHMAP_NA => unreachable, // TODO
        c.SND_CHMAP_MONO => .front_center,
        c.SND_CHMAP_FL => .front_left,
        c.SND_CHMAP_FR => .front_right,
        c.SND_CHMAP_RL => .back_left,
        c.SND_CHMAP_RR => .back_right,
        c.SND_CHMAP_FC => .front_center,
        c.SND_CHMAP_LFE => .lfe,
        c.SND_CHMAP_SL => .side_left,
        c.SND_CHMAP_SR => .side_right,
        c.SND_CHMAP_RC => .back_center,
        c.SND_CHMAP_FLC => .front_left_center,
        c.SND_CHMAP_FRC => .front_right_center,
        c.SND_CHMAP_RLC => .back_left_center,
        c.SND_CHMAP_RRC => .back_right_center,
        c.SND_CHMAP_FLW => .front_left_wide,
        c.SND_CHMAP_FRW => .front_right_wide,
        c.SND_CHMAP_FLH => .front_left_high,
        c.SND_CHMAP_FCH => .front_center_high,
        c.SND_CHMAP_FRH => .front_right_high,
        c.SND_CHMAP_TC => .top_center,
        c.SND_CHMAP_TFL => .top_front_left,
        c.SND_CHMAP_TFR => .top_front_right,
        c.SND_CHMAP_TFC => .top_front_center,
        c.SND_CHMAP_TRL => .top_back_left,
        c.SND_CHMAP_TRR => .top_back_right,
        c.SND_CHMAP_TRC => .top_back_center,
        c.SND_CHMAP_TFLC => .top_front_left_center,
        c.SND_CHMAP_TFRC => .top_front_right_center,
        c.SND_CHMAP_TSL => .top_side_left,
        c.SND_CHMAP_TSR => .top_side_right,
        c.SND_CHMAP_LLFE => .left_lfe,
        c.SND_CHMAP_RLFE => .right_lfe,
        c.SND_CHMAP_BC => .bottom_center,
        c.SND_CHMAP_BLC => .bottom_left_center,
        c.SND_CHMAP_BRC => .bottom_right_center,

        else => unreachable,
    };
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
    allocator.free(self.formats);
}

const alsa_supported_formats = &[_]Format{
    .s8,
    .u8,
    .s16le,
    .s16be,
    .u16le,
    .u16be,
    .s24_32le,
    .s24_32be,
    .u24_32le,
    .u24_32be,
    .s32le,
    .s32be,
    .u32le,
    .u32be,
    .float32le,
    .float32be,
    .float64le,
    .float64be,
};

// Generated from types.h
const snd_pcm_sync_id_t = extern union {
    id: [16]u8,
    id16: [8]c_ushort,
    id32: [4]c_uint,
};

const snd_pcm_info_t = extern struct {
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

const snd_ctl_card_info_t = extern struct {
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
