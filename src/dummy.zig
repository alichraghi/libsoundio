const std = @import("std");
const main = @import("main.zig");
const backends = @import("backends.zig");
const util = @import("util.zig");

const dummy_playback = main.Device{
    .id = "dummy-playback",
    .name = "Dummy Device",
    .mode = .playback,
    .channels = undefined,
    .formats = std.meta.tags(main.Format),
    .sample_rate = .{
        .min = main.min_sample_rate,
        .max = main.max_sample_rate,
    },
};

const dummy_capture = main.Device{
    .id = "dummy-capture",
    .name = "Dummy Device",
    .mode = .capture,
    .channels = undefined,
    .formats = std.meta.tags(main.Format),
    .sample_rate = .{
        .min = main.min_sample_rate,
        .max = main.max_sample_rate,
    },
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    devices_info: util.DevicesInfo,

    pub fn init(allocator: std.mem.Allocator, options: main.Context.Options) !backends.BackendContext {
        _ = options;

        var self = try allocator.create(Context);
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

        return .{ .dummy = self };
    }

    pub fn deinit(self: *Context) void {
        for (self.devices_info.list.items) |d|
            freeDevice(self.allocator, d);
        self.devices_info.list.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn refresh(self: *Context) !void {
        _ = self;
    }

    pub fn devices(self: Context) []const main.Device {
        return self.devices_info.list.items;
    }

    pub fn defaultDevice(self: Context, aim: main.Device.Mode) ?main.Device {
        return self.devices_info.default(aim);
    }

    pub fn createPlayer(self: *Context, player: *main.Player, device: main.Device) !void {
        _ = device;
        player.data = .{
            .dummy = .{
                .allocator = self.allocator,
                .mutex = .{},
                .cond = .{},
                .aborted = .{ .value = false },
                ._paused = .{ .value = false },
                ._volume = 1.0,
                .thread = undefined,
            },
        };
    }
};

pub const Player = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    aborted: std.atomic.Atomic(bool),
    _paused: std.atomic.Atomic(bool),
    _volume: f32,

    pub fn deinit(self: *Player) void {
        self.aborted.store(true, .Unordered);
        self.cond.signal();
        self.thread.join();
    }

    pub fn start(self: *Player) !void {
        self.thread = std.Thread.spawn(.{}, writeLoop, .{self}) catch |err| switch (err) {
            error.ThreadQuotaExceeded,
            error.SystemResources,
            error.LockedMemoryLimitExceeded,
            => return error.SystemResources,
            error.OutOfMemory => return error.OutOfMemory,
            error.Unexpected => unreachable,
        };
    }

    fn writeLoop(self: *Player) void {
        var parent = @fieldParentPtr(main.Player, "data", @ptrCast(*const backends.BackendPlayer, self));

        const buf_size = @as(u11, 1024);
        const bps = buf_size / parent.bytesPerSample();
        var buf: [1024]u8 = undefined;

        parent.device.channels[0].ptr = &buf;

        while (!self.aborted.load(.Unordered)) {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.cond.timedWait(&self.mutex, main.default_latency * std.time.ns_per_us) catch {};
            if (self._paused.load(.Unordered))
                continue;
            parent.writeFn(parent, bps);
        }
    }

    pub fn play(self: *Player) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self._paused.store(false, .Unordered);
        self.cond.signal();
    }

    pub fn pause(self: *Player) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self._paused.store(true, .Unordered);
    }

    pub fn paused(self: *Player) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self._paused.load(.Unordered);
    }

    pub fn setVolume(self: *Player, vol: f32) !void {
        self._volume = vol;
    }

    pub fn volume(self: *Player) !f32 {
        return self._volume;
    }
};

fn freeDevice(allocator: std.mem.Allocator, device: main.Device) void {
    allocator.free(device.channels);
}
