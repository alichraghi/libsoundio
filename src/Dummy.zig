const std = @import("std");
const c = @cImport(@cInclude("asoundlib.h"));
const util = @import("util.zig");
const Channel = @import("main.zig").Channel;
const ConnectOptions = @import("main.zig").ConnectOptions;
const Device = @import("main.zig").Device;
const DevicesInfo = @import("main.zig").DevicesInfo;
const Format = @import("main.zig").Format;
const Player = @import("main.zig").Player;
const default_latency = @import("main.zig").default_latency;
const min_sample_rate = @import("main.zig").min_sample_rate;
const max_sample_rate = @import("main.zig").max_sample_rate;

const Dummy = @This();

const dummy_playback = Device{
    .id = "dummy-playback",
    .name = "Dummy Device",
    .aim = .playback,
    .channels = undefined,
    .formats = &.{
        .i8,
        .u8,
        .i16,
        .u16,
        .i24,
        .u24,
        .i24_3b,
        .u24_3b,
        .i32,
        .u32,
        .f32,
        .f64,
    },
    .rate_range = .{
        .min = min_sample_rate,
        .max = max_sample_rate,
    },
};

const dummy_capture = Device{
    .id = "dummy-capture",
    .name = "Dummy Device",
    .aim = .capture,
    .channels = undefined,
    .formats = &.{
        .i8,
        .u8,
        .i16,
        .u16,
        .i24,
        .u24,
        .i24_3b,
        .u24_3b,
        .i32,
        .u32,
        .f32,
        .f64,
    },
    .rate_range = .{
        .min = min_sample_rate,
        .max = max_sample_rate,
    },
};

allocator: std.mem.Allocator,
devices_info: DevicesInfo,
device_watcher: ?DeviceWatcher,

const DeviceWatcher = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    scan_queued: std.atomic.Atomic(bool),
};

pub fn connect(allocator: std.mem.Allocator, options: ConnectOptions) !*Dummy {
    var self = try allocator.create(Dummy);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .devices_info = DevicesInfo.init(),
        .device_watcher = if (options.watch_devices) .{
            .mutex = .{},
            .cond = .{},
            .scan_queued = .{ .value = false },
        } else null,
    };

    try self.devices_info.list.append(self.allocator, dummy_playback);
    try self.devices_info.list.append(self.allocator, dummy_capture);
    self.devices_info.list.items[0].channels = try allocator.alloc(Channel, 1);
    self.devices_info.list.items[0].channels[0] = .{
        .id = .front_center,
    };
    self.devices_info.list.items[1].channels = try allocator.alloc(Channel, 1);
    self.devices_info.list.items[1].channels[0] = .{
        .id = .front_center,
    };
    self.devices_info.setDefault(.playback, 0);
    self.devices_info.setDefault(.capture, 1);

    return self;
}

pub fn disconnect(self: *Dummy) void {
    self.devices_info.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn flush(self: *Dummy) !void {
    if (self.device_watcher) |*dw| {
        dw.mutex.lock();
        defer dw.mutex.unlock();
        dw.scan_queued.store(false, .Release);
    }
}

pub fn wait(self: *Dummy) !void {
    std.debug.assert(self.device_watcher != null);
    var dw = &self.device_watcher.?;

    dw.mutex.lock();
    defer dw.mutex.unlock();

    while (!dw.scan_queued.load(.Acquire))
        dw.cond.wait(&dw.mutex);

    dw.scan_queued.store(false, .Release);
}

pub fn wakeUp(self: *Dummy) void {
    std.debug.assert(self.device_watcher != null);
    var dw = &self.device_watcher.?;

    dw.mutex.lock();
    defer dw.mutex.unlock();
    dw.scan_queued.store(true, .Release);
    dw.cond.signal();
}

pub const PlayerData = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    aborted: std.atomic.Atomic(bool),
    paused: std.atomic.Atomic(bool),
    volume: f32,
};

pub fn openPlayer(self: *Dummy, player: *Player, device: Device) !void {
    _ = device;
    player.backend_data = .{
        .Dummy = .{
            .allocator = self.allocator,
            .mutex = .{},
            .cond = .{},
            .aborted = .{ .value = false },
            .paused = .{ .value = false },
            .volume = 1.0,
            .thread = undefined,
        },
    };
}

pub fn playerDeinit(self: *Player) void {
    var bd = &self.backend_data.Dummy;

    bd.aborted.store(true, .Unordered);
    bd.cond.signal();
    bd.thread.join();
}

pub fn playerStart(self: *Player) !void {
    var bd = &self.backend_data.Dummy;

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
    var bd = &self.backend_data.Dummy;

    const buf_size = @as(u11, 1024);
    const bps = buf_size / self.bytesPerSample();
    var buf: [1024]u8 = undefined;

    self.device.channels[0].ptr = &buf;

    while (!bd.aborted.load(.Unordered)) {
        bd.mutex.lock();
        defer bd.mutex.unlock();
        bd.cond.timedWait(&bd.mutex, default_latency * std.time.ns_per_us) catch {};
        if (bd.paused.load(.Unordered))
            continue;
        self.writeFn(self, {}, bps);
    }
}

pub fn playerPlay(self: *Player) !void {
    var bd = &self.backend_data.Dummy;
    bd.mutex.lock();
    defer bd.mutex.unlock();
    bd.paused.store(false, .Unordered);
    bd.cond.signal();
}

pub fn playerPause(self: *Player) !void {
    const bd = &self.backend_data.Dummy;
    bd.mutex.lock();
    defer bd.mutex.unlock();
    bd.paused.store(true, .Unordered);
}

pub fn playerPaused(self: *Player) bool {
    const bd = &self.backend_data.Dummy;
    bd.mutex.lock();
    defer bd.mutex.unlock();
    return bd.paused.load(.Unordered);
}

pub fn playerSetVolume(self: *Player, volume: f32) !void {
    var bd = &self.backend_data.Dummy;
    bd.volume = volume;
}

pub fn playerVolume(self: *Player) !f32 {
    var bd = &self.backend_data.Dummy;

    return bd.volume;
}

pub fn deviceDeinit(self: Device, allocator: std.mem.Allocator) void {
    allocator.free(self.channels);
}
