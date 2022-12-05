const std = @import("std");
const main = @import("main.zig");
const util = @import("util.zig");

const Dummy = @This();

const dummy_playback = main.Device{
    .id = "dummy-playback",
    .name = "Dummy main.Device",
    .aim = .playback,
    .channels = undefined,
    .formats = std.meta.tags(main.Format),
    .sample_rate = .{
        .min = main.min_sample_rate,
        .max = main.max_sample_rate,
    },
};

const dummy_capture = main.Device{
    .id = "dummy-capture",
    .name = "Dummy main.Device",
    .aim = .capture,
    .channels = undefined,
    .formats = std.meta.tags(main.Format),
    .sample_rate = .{
        .min = main.min_sample_rate,
        .max = main.max_sample_rate,
    },
};

allocator: std.mem.Allocator,
devices_info: util.DevicesInfo,

pub fn connect(allocator: std.mem.Allocator, options: main.ConnectOptions) !*Dummy {
    _ = options;

    var self = try allocator.create(Dummy);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .devices_info = util.DevicesInfo.init(),
    };

    try self.devices_info.list.append(self.allocator, dummy_playback);
    try self.devices_info.list.append(self.allocator, dummy_capture);
    self.devices_info.list.items[0].channels = try allocator.alloc(main.Channel, 1);
    self.devices_info.list.items[0].channels[0] = .{
        .id = .front_center,
    };
    self.devices_info.list.items[1].channels = try allocator.alloc(main.Channel, 1);
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

pub fn refresh(self: *Dummy) !void {
    _ = self;
}

pub fn devices(self: Dummy) []const main.Device {
    return self.devices_info.list.items;
}

pub fn defaultDevice(self: Dummy, aim: main.Device.Aim) ?main.Device {
    return self.devices_info.default(aim);
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

pub fn openPlayer(self: *Dummy, player: *main.Player, device: main.Device) !void {
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

pub fn playerDeinit(self: *main.Player) void {
    var bd = &self.backend_data.Dummy;

    bd.aborted.store(true, .Unordered);
    bd.cond.signal();
    bd.thread.join();
}

pub fn playerStart(self: *main.Player) !void {
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

fn playerLoop(self: *main.Player) void {
    var bd = &self.backend_data.Dummy;

    const buf_size = @as(u11, 1024);
    const bps = buf_size / self.bytesPerSample();
    var buf: [1024]u8 = undefined;

    self.device.channels[0].ptr = &buf;

    while (!bd.aborted.load(.Unordered)) {
        bd.mutex.lock();
        defer bd.mutex.unlock();
        bd.cond.timedWait(&bd.mutex, main.default_latency * std.time.ns_per_us) catch {};
        if (bd.paused.load(.Unordered))
            continue;
        self.writeFn(self, bps);
    }
}

pub fn playerPlay(self: *main.Player) !void {
    var bd = &self.backend_data.Dummy;
    bd.mutex.lock();
    defer bd.mutex.unlock();
    bd.paused.store(false, .Unordered);
    bd.cond.signal();
}

pub fn playerPause(self: *main.Player) !void {
    const bd = &self.backend_data.Dummy;
    bd.mutex.lock();
    defer bd.mutex.unlock();
    bd.paused.store(true, .Unordered);
}

pub fn playerPaused(self: *main.Player) bool {
    const bd = &self.backend_data.Dummy;
    bd.mutex.lock();
    defer bd.mutex.unlock();
    return bd.paused.load(.Unordered);
}

pub fn playerSetVolume(self: *main.Player, volume: f32) !void {
    var bd = &self.backend_data.Dummy;
    bd.volume = volume;
}

pub fn playerVolume(self: *main.Player) !f32 {
    var bd = &self.backend_data.Dummy;
    return bd.volume;
}

pub fn deviceDeinit(self: main.Device, allocator: std.mem.Allocator) void {
    allocator.free(self.channels);
}
