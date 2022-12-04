const builtin = @import("builtin");
const std = @import("std");

const PulseAudio = if (builtin.os.tag == .linux) @import("PulseAudio.zig") else void;
const Alsa = if (builtin.os.tag == .linux) @import("Alsa.zig") else void;
const WASApi = if (builtin.os.tag == .windows) @import("WASApi.zig") else void;
const Dummy = @import("Dummy.zig");

comptime {
    std.testing.refAllDeclsRecursive(SysAudio);
    std.testing.refAllDeclsRecursive(@import("util.zig"));
}

pub const max_channels = 32;
pub const min_sample_rate = 8_000; // Hz
pub const max_sample_rate = 5_644_800; // Hz
pub const default_sample_rate = 44_100; // Hz
pub const default_latency = 500 * std.time.us_per_ms; // μs
var current_backend: ?Backend = null;

const SysAudio = @This();

pub const Backend = std.meta.Tag(BackendData);
pub const BackendData = switch (builtin.os.tag) {
    .linux,
    .kfreebsd,
    .freebsd,
    .openbsd,
    .netbsd,
    .dragonfly,
    => union(enum) {
        PulseAudio: *PulseAudio,
        Alsa: *Alsa,
        Dummy: *Dummy,
    },
    .windows => union(enum) {
        WASApi: *WASApi,
        Dummy: *Dummy,
    },
    .ios, .macos, .watchos, .tvos => union(enum) {
        // CoreAudio,
        Dummy: *Dummy,
    },
    else => union(enum) {
        Dummy: *Dummy,
    },
};

data: BackendData,

pub const ConnectError = error{
    OutOfMemory,
    SystemResources,
    AccessDenied,
    ConnectionRefused,
};

pub const ConnectOptions = struct {
    app_name: [:0]const u8 = "Mach Game",
    watch_devices: bool = false,
};

/// must be called in the main thread
pub fn connect(comptime backend: ?Backend, allocator: std.mem.Allocator, options: ConnectOptions) ConnectError!SysAudio {
    std.debug.assert(current_backend == null);

    var data: BackendData = blk: {
        if (backend) |b| {
            break :blk @unionInit(
                BackendData,
                @tagName(b),
                try @field(SysAudio, @tagName(b)).connect(allocator, options),
            );
        } else {
            var first_err: ConnectError!void = {};

            inline for (std.meta.fields(Backend)) |b, i| {
                if (@field(SysAudio, b.name).connect(allocator, options) catch |err| fblk: {
                    if (i == 0) first_err = err;
                    break :fblk null;
                }) |d| {
                    break :blk @unionInit(BackendData, b.name, d);
                }
            }

            try first_err;
            unreachable;
        }
    };

    current_backend = std.meta.activeTag(data);
    return .{ .data = data };
}

pub fn disconnect(self: SysAudio) void {
    switch (self.data) {
        inline else => |b| b.disconnect(),
    }
    current_backend = null;
}

pub const FlushError = error{
    OutOfMemory,
    OpeningDevice,
    SystemResources,
};

pub fn flush(self: SysAudio) FlushError!void {
    return switch (self.data) {
        inline else => |b| b.flush(),
    };
}

pub fn wait(self: SysAudio) FlushError!void {
    return switch (self.data) {
        inline else => |b| b.wait(),
    };
}

pub fn wakeUp(self: SysAudio) void {
    return switch (self.data) {
        inline else => |b| b.wakeUp(),
    };
}

pub fn devicesList(self: SysAudio) []const Device {
    return switch (self.data) {
        inline else => |b| b.devices_info.list.items,
    };
}

pub fn getDevice(self: SysAudio, aim: Device.Aim, index: ?usize) ?Device {
    return switch (self.data) {
        inline else => |b| b.devices_info.get(index orelse return b.devices_info.default(aim)),
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
    writeFn: Player.WriteFn,
    format: ?Format = null,
    sample_rate: u32 = default_sample_rate,
    userdata: ?*anyopaque = null,
};

pub fn createPlayer(self: SysAudio, device: Device, options: PlayerOptions) CreateStreamError!Player {
    var player = Player{
        .backend_data = undefined,
        .writeFn = options.writeFn,
        .userdata = options.userdata,
        .device = device,
        .format = blk: {
            if (options.format) |format| {
                for (device.formats) |dfmt| {
                    if (format == dfmt) {
                        break :blk dfmt;
                    }
                }
                return error.IncompatibleDevice;
            }

            break :blk device.preferredFormat();
        },
        .sample_rate = device.sample_rate.clamp(options.sample_rate),
    };
    switch (self.data) {
        inline else => |b| try b.openPlayer(&player, device),
    }
    return player;
}

pub const Player = struct {
    // TODO: `*Player` instead `*anyopaque`
    // https://github.com/ziglang/zig/issues/12325
    pub const WriteError = error{WriteFailed};
    pub const WriteFn = *const fn (self: *anyopaque, err: WriteError!void, frame_count_max: usize) void;

    writeFn: WriteFn,
    userdata: ?*anyopaque,
    device: Device,
    format: Format,
    /// samples per second
    sample_rate: u32,

    backend_data: PlayerBackendData(),

    fn PlayerBackendData() type {
        var fields: [std.meta.fields(BackendData).len]std.builtin.Type.UnionField = undefined;
        for (std.meta.fields(BackendData)) |b, i| {
            fields[i] = std.builtin.Type.UnionField{
                .name = b.name,
                .field_type = @field(SysAudio, b.name).PlayerData,
                .alignment = @alignOf(@field(SysAudio, b.name).PlayerData),
            };
        }
        return @Type(.{ .Union = .{
            .layout = .Auto,
            .tag_type = Backend,
            .fields = &fields,
            .decls = &.{},
        } });
    }

    pub fn deinit(self: *Player) void {
        return switch (current_backend.?) {
            inline else => |b| @field(SysAudio, @tagName(b)).playerDeinit(self),
        };
    }

    pub const StartError = error{
        CannotPlay,
        OutOfMemory,
        SystemResources,
    };

    pub fn start(self: *Player) StartError!void {
        return switch (current_backend.?) {
            inline else => |b| @field(SysAudio, @tagName(b)).playerStart(self),
        };
    }

    pub const PlayError = error{
        CannotPlay,
    };

    pub fn play(self: *Player) PlayError!void {
        return switch (current_backend.?) {
            inline else => |b| @field(SysAudio, @tagName(b)).playerPlay(self),
        };
    }

    pub const PauseError = error{
        CannotPause,
    };

    pub fn pause(self: *Player) PauseError!void {
        return switch (current_backend.?) {
            inline else => |b| @field(SysAudio, @tagName(b)).playerPause(self),
        };
    }

    pub fn paused(self: *Player) bool {
        return switch (current_backend.?) {
            inline else => |b| @field(SysAudio, @tagName(b)).playerPaused(self),
        };
    }

    pub const SetVolumeError = error{
        CannotSetVolume,
    };

    // confidence interval (±) depends on the device
    pub fn setVolume(self: *Player, vol: f32) SetVolumeError!void {
        std.debug.assert(vol <= 1.0);
        return switch (current_backend.?) {
            inline else => |b| @field(SysAudio, @tagName(b)).playerSetVolume(self, vol),
        };
    }

    pub const GetVolumeError = error{
        CannotGetVolume,
    };

    // confidence interval (±) depends on the device
    pub fn volume(self: *Player) GetVolumeError!f32 {
        return switch (current_backend.?) {
            inline else => |b| @field(SysAudio, @tagName(b)).playerVolume(self),
        };
    }

    pub fn bytesPerFrame(self: Player) u8 {
        return self.format.bytesPerFrame(@intCast(u5, self.device.channels.len));
    }

    pub fn bytesPerSample(self: Player) u4 {
        return self.format.bytesPerSample();
    }

    pub fn writeAll(self: *Player, frame: usize, value: anytype) void {
        for (self.device.channels) |_, i|
            self.write(i, frame, value);
    }

    pub fn write(self: *Player, channel: usize, frame: usize, sample: anytype) void {
        switch (@TypeOf(sample)) {
            u8 => self.writeu8(channel, frame, sample),
            i16 => self.writei16(channel, frame, sample),
            i24 => self.writei24(channel, frame, sample),
            i32 => self.writei32(channel, frame, sample),
            f32 => self.writef32(channel, frame, sample),
            f64 => self.writef64(channel, frame, sample),
            else => @compileError(
                \\invalid sample type. supported types are:
                \\u8, i8, i16, i24, i32, f32, f32, f64
            ),
        }
    }

    pub fn writeRaw(self: *Player, channel: usize, frame: usize, sample: anytype) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        std.mem.bytesAsValue(@TypeOf(sample), ptr[0..@sizeOf(@TypeOf(sample))]).* = sample;
    }

    pub inline fn writeu8(self: *Player, channel: usize, frame: usize, sample: u8) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, sample),
            .i8 => self.writeRaw(channel, frame, unsignedToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, unsignedToSigned(i16, sample)),
            .i24 => self.writeRaw(channel, frame, unsignedToSigned(i24, sample)),
            .i24_3b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, unsignedToSigned(i32, sample)),
            .f32 => self.writeRaw(channel, frame, unsignedToFloat(f32, sample)),
            .f64 => self.writeRaw(channel, frame, unsignedToFloat(f64, sample)),
        }
    }

    fn unsignedToSigned(comptime T: type, sample: anytype) T {
        const half = 1 << (@bitSizeOf(@TypeOf(sample)) - 1);
        const trunc = @bitSizeOf(T) - @bitSizeOf(@TypeOf(sample));
        return @intCast(T, sample -% half) << trunc;
    }

    fn unsignedToFloat(comptime T: type, sample: anytype) T {
        const max_int = std.math.maxInt(@TypeOf(sample)) + 1.0;
        return (@intToFloat(T, sample) - max_int) * 1.0 / max_int;
    }

    pub inline fn writei16(self: *Player, channel: usize, frame: usize, sample: i16) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, signedToUnsigned(u8, sample)),
            .i8 => self.writeRaw(channel, frame, signedToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, sample),
            .i24 => self.writeRaw(channel, frame, sample),
            .i24_3b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, sample),
            .f32 => self.writeRaw(channel, frame, signedToFloat(f32, sample)),
            .f64 => self.writeRaw(channel, frame, signedToFloat(f64, sample)),
        }
    }

    pub inline fn writei24(self: *Player, channel: usize, frame: usize, sample: i24) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, signedToUnsigned(u8, sample)),
            .i8 => self.writeRaw(channel, frame, signedToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, signedToSigned(i16, sample)),
            .i24 => self.writeRaw(channel, frame, sample),
            .i24_3b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, sample),
            .f32 => self.writeRaw(channel, frame, signedToFloat(f32, sample)),
            .f64 => self.writeRaw(channel, frame, signedToFloat(f64, sample)),
        }
    }

    pub inline fn writei32(self: *Player, channel: usize, frame: usize, sample: i32) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, signedToUnsigned(u8, sample)),
            .i8 => self.writeRaw(channel, frame, signedToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, signedToSigned(i16, sample)),
            .i24 => self.writeRaw(channel, frame, signedToSigned(i24, sample)),
            .i24_3b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, sample),
            .f32 => self.writeRaw(channel, frame, signedToFloat(f32, sample)),
            .f64 => self.writeRaw(channel, frame, signedToFloat(f64, sample)),
        }
    }

    fn signedToSigned(comptime T: type, sample: anytype) T {
        const trunc = @bitSizeOf(@TypeOf(sample)) - @bitSizeOf(T);
        return @intCast(T, sample >> trunc);
    }

    fn signedToUnsigned(comptime T: type, sample: anytype) T {
        const half = 1 << (@bitSizeOf(T) - 1);
        const trunc = @bitSizeOf(@TypeOf(sample)) - @bitSizeOf(T);
        return @intCast(T, (sample >> trunc) + half);
    }

    fn signedToFloat(comptime T: type, sample: anytype) T {
        const max_int = std.math.maxInt(@TypeOf(sample)) + 1.0;
        return @intToFloat(T, sample) * 1.0 / max_int;
    }

    pub inline fn writef32(self: *Player, channel: usize, frame: usize, sample: f32) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, floatToUnsigned(u8, sample)),
            .i8 => self.writeRaw(channel, frame, floatToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, floatToSigned(i16, sample)),
            .i24 => self.writeRaw(channel, frame, floatToSigned(i24, sample)),
            .i24_3b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, floatToSigned(i32, sample)),
            .f32 => self.writeRaw(channel, frame, sample),
            .f64 => self.writeRaw(channel, frame, sample),
        }
    }

    pub inline fn writef64(self: *Player, channel: usize, frame: usize, sample: f64) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, floatToUnsigned(u8, sample)),
            .i8 => self.writeRaw(channel, frame, floatToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, floatToSigned(i16, sample)),
            .i24 => self.writeRaw(channel, frame, floatToSigned(i24, sample)),
            .i24_3b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, floatToSigned(i32, sample)),
            .f32 => self.writeRaw(channel, frame, sample),
            .f64 => self.writeRaw(channel, frame, sample),
        }
    }

    fn floatToSigned(comptime T: type, sample: f64) T {
        return @floatToInt(T, sample * std.math.maxInt(T));
    }

    fn floatToUnsigned(comptime T: type, sample: f64) T {
        const half = 1 << @bitSizeOf(T) - 1;
        return @floatToInt(T, sample * (half - 1) + half);
    }

    // TODO: must be tested
    // fn f32Toi24_3b(sample: f32) i32 {
    //     const scaled = sample *  std.math.maxInt(i32);
    //     if (builtin.cpu.arch.endian() == .Little) {
    //         return @floatToInt(i32, scaled);
    //     } else {
    //         var res: [4]u8 = undefined;
    //         std.mem.writeIntSliceBig(i32, &res, @floatToInt(i32, res));
    //         return @bitCast(i32, res);
    //     }
    // }
};

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
    sample_rate: Range(u32),

    pub fn deinit(self: Device, allocator: std.mem.Allocator) void {
        return switch (current_backend.?) {
            inline else => |b| @field(SysAudio, @tagName(b)).deviceDeinit(self, allocator),
        };
    }

    pub fn preferredFormat(self: Device) Format {
        var best: Format = self.formats[0];
        for (self.formats) |fmt| {
            if (fmt.bytesPerSample() >= best.bytesPerSample()) {
                if (fmt == .i24_3b and best == .i24)
                    continue;
                best = fmt;
            }
        }
        return best;
    }
};

pub const DevicesInfo = struct {
    list: std.ArrayListUnmanaged(Device),
    default_output: ?usize,
    default_input: ?usize,

    pub fn init() DevicesInfo {
        return .{
            .list = .{},
            .default_output = null,
            .default_input = null,
        };
    }

    pub fn deinit(self: *DevicesInfo, allocator: std.mem.Allocator) void {
        for (self.list.items) |device|
            device.deinit(allocator);
        self.list.deinit(allocator);
    }

    pub fn clear(self: *DevicesInfo, allocator: std.mem.Allocator) void {
        self.default_output = null;
        self.default_input = null;
        for (self.list.items) |device|
            device.deinit(allocator);
        self.list.clearAndFree(allocator);
    }

    pub fn get(self: DevicesInfo, i: usize) Device {
        return self.list.items[i];
    }

    pub fn default(self: DevicesInfo, aim: Device.Aim) ?Device {
        return self.get(self.defaultIndex(aim) orelse return null);
    }

    pub fn setDefault(self: *DevicesInfo, aim: Device.Aim, i: usize) void {
        switch (aim) {
            .playback => self.default_output = i,
            .capture => self.default_input = i,
        }
    }

    pub fn defaultIndex(self: DevicesInfo, aim: Device.Aim) ?usize {
        return switch (aim) {
            .playback => self.default_output,
            .capture => self.default_input,
        };
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
    i24_3b,
    i32,
    f32,
    f64,

    pub fn bytesPerSample(self: Format) u4 {
        return switch (self) {
            .u8, .i8 => 1,
            .i16 => 2,
            .i24 => 3,
            .i24_3b,
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

pub fn Range(comptime T: type) type {
    return struct {
        const Self = @This();

        min: T,
        max: T,

        pub fn clamp(self: Self, val: T) T {
            return std.math.clamp(val, self.min, self.max);
        }
    };
}
