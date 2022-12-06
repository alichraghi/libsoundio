const std = @import("std");
const backends = @import("backends.zig");
const util = @import("util.zig");
const Player = @import("player.zig").Player;
const Backend = backends.Backend;
const BackendData = backends.BackendData;

pub usingnamespace @import("player.zig");
pub usingnamespace @import("backends.zig");

pub const max_channels = 32;
pub const min_sample_rate = 8_000; // Hz
pub const max_sample_rate = 5_644_800; // Hz
pub const default_sample_rate = 44_100; // Hz
pub const default_latency = 500 * std.time.us_per_ms; // μs

const SysAudio = @This();

data: BackendData,

pub const ConnectError = error{
    OutOfMemory,
    AccessDenied,
    SystemResources,
    ConnectionRefused,
};
pub const DeviceChangeFn = *const fn (self: ?*anyopaque) void;
pub const ConnectOptions = struct {
    app_name: [:0]const u8 = "Mach Game",
    deviceChangeFn: ?DeviceChangeFn = null,
    userdata: ?*anyopaque = null,
};

pub fn connect(comptime backend: ?Backend, allocator: std.mem.Allocator, options: ConnectOptions) ConnectError!SysAudio {
    var data: BackendData = blk: {
        if (backend) |b| {
            break :blk try @field(backends, @tagName(b)).connect(allocator, options);
        } else {
            var first_err: ConnectError!void = {};

            inline for (std.meta.fields(Backend)) |b, i| {
                if (@field(backends, b.name).connect(allocator, options) catch |err| fblk: {
                    if (i == 0) first_err = err;
                    break :fblk null;
                }) |d| {
                    break :blk d;
                }
            }

            try first_err;
            unreachable;
        }
    };

    return .{ .data = data };
}

pub fn disconnect(self: SysAudio) void {
    switch (self.data) {
        inline else => |b| b.disconnect(),
    }
}

pub const RefreshError = error{
    OutOfMemory,
    SystemResources,
    OpeningDevice,
};

pub fn refresh(self: SysAudio) RefreshError!void {
    return switch (self.data) {
        inline else => |b| b.refresh(),
    };
}

pub fn devices(self: SysAudio) []const Device {
    return switch (self.data) {
        inline else => |b| b.devices(),
    };
}

pub fn defaultDevice(self: SysAudio, aim: Device.Aim) ?Device {
    return switch (self.data) {
        inline else => |b| b.defaultDevice(aim),
    };
}

pub const CreateStreamError = error{
    OutOfMemory,
    SystemResources,
    OpeningDevice,
    IncompatibleBackend,
    IncompatibleDevice,
};

pub const PlayerOptions = struct {
    format: ?Format = null,
    sample_rate: u32 = default_sample_rate,
    userdata: ?*anyopaque = null,
};

pub fn createPlayer(self: SysAudio, device: Device, writeFn: Player.WriteFn, options: PlayerOptions) CreateStreamError!Player {
    std.debug.assert(device.aim == .playback);

    var player = Player{
        .writeFn = writeFn,
        .userdata = options.userdata,
        .device = device,
        .format = blk: {
            for (device.formats) |dfmt| {
                if (options.format == dfmt) {
                    break :blk dfmt;
                }
            }
            break :blk device.preferredFormat();
        },
        .sample_rate = device.sample_rate.clamp(options.sample_rate),
        .data = undefined,
    };

    switch (self.data) {
        inline else => |b| try b.createPlayer(&player, device),
    }

    return player;
}

pub const Device = struct {
    pub const Aim = enum {
        playback,
        capture,
    };

    id: [:0]const u8,
    name: [:0]const u8,
    aim: Aim,
    channels: []Channel,
    formats: []const Format,
    sample_rate: util.Range(u32),

    pub fn preferredFormat(self: Device) Format {
        var best: Format = self.formats[0];
        for (self.formats) |fmt| {
            if (fmt.bytesPerSample() >= best.bytesPerSample()) {
                if (fmt == .i24_4b and best == .i24)
                    continue;
                best = fmt;
            }
        }
        return best;
    }
};

pub const Channel = struct {
    ptr: [*]u8 = undefined,
    id: ChannelId,
};

pub const ChannelId = enum {
    front_center,
    front_left,
    front_right,
    front_left_center,
    front_right_center,
    back_center,
    side_left,
    side_right,
    top_center,
    top_front_center,
    top_front_left,
    top_front_right,
    top_back_center,
    top_back_left,
    top_back_right,
    lfe,
};

pub const Format = enum {
    u8,
    i8,
    i16,
    i24,
    i24_4b,
    i32,
    f32,
    f64,

    pub fn bytesPerSample(self: Format) u4 {
        return switch (self) {
            .u8, .i8 => 1,
            .i16 => 2,
            .i24 => 3,
            .i24_4b,
            .i32,
            .f32,
            => 4,
            .f64 => 8,
        };
    }

    pub fn bytesPerFrame(self: Format, ch_count: u5) u8 {
        return self.bytesPerSample() * ch_count;
    }
};

test {
    comptime {
        std.testing.refAllDeclsRecursive(@This());
    }
}
