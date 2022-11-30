const builtin = @import("builtin");
const std = @import("std");
const channel_layout = @import("channel_layout.zig");
const bytesAsValue = std.mem.bytesAsValue;

const PulseAudio = if (builtin.os.tag == .linux) @import("PulseAudio.zig") else void;
const Alsa = if (builtin.os.tag == .linux) @import("Alsa.zig") else void;
const WASApi = if (builtin.os.tag == .windows) @import("WASApi.zig") else void;
const Dummy = @import("Dummy.zig");

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const SysAudio = @This();

pub const max_channels = 32;
pub const min_sample_rate = 8_000; // Hz
pub const max_sample_rate = 5_644_800; // Hz
pub const default_sample_rate = 44_100; // Hz
pub const default_latency = 500 * std.time.us_per_ms; // μs

var current_backend: ?Backend = null;

pub const Backend = std.meta.Tag(BackendType);
pub const BackendType = switch (builtin.os.tag) {
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

data: BackendType,

pub const ConnectError = error{
    OutOfMemory,
    SystemResources,
    AccessDenied,
    ConnectionRefused,
};

pub const ConnectOptions = struct {
    app_name: [:0]const u8 = "Mach Game",
};

/// must be called in the main thread
pub fn connect(comptime backend: ?Backend, allocator: std.mem.Allocator, options: ConnectOptions) ConnectError!SysAudio {
    std.debug.assert(current_backend == null);
    var data: ?BackendType = null;

    if (backend) |b| {
        data = @unionInit(
            BackendType,
            @tagName(b),
            try @field(SysAudio, @tagName(b)).connect(allocator, options),
        );
    } else {
        var first_err: ConnectError!void = {};

        inline for (std.meta.fields(Backend)) |b, i| {
            if (@field(SysAudio, b.name).connect(allocator, options) catch |err| blk: {
                if (i == 0) first_err = err;
                break :blk null;
            }) |d| {
                data = @unionInit(BackendType, b.name, d);
                break;
            }
        }

        if (data == null)
            try first_err;
    }

    current_backend = std.meta.activeTag(data.?);
    return .{ .data = data.? };
}

pub fn disconnect(self: SysAudio) void {
    switch (self.data) {
        inline else => |b| b.disconnect(),
    }
    current_backend = null;
}

pub const EventsError = error{
    OutOfMemory,
    OpeningDevice,
    SystemResources,
};

pub fn flushEvents(self: SysAudio) EventsError!void {
    return switch (self.data) {
        inline else => |b| b.flushEvents(),
    };
}

pub fn waitEvents(self: SysAudio) EventsError!void {
    return switch (self.data) {
        inline else => |b| b.waitEvents(),
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
    switch (self.data) {
        inline else => |b| {
            return b.devices_info.get(index orelse return b.devices_info.default(aim));
        },
    }
}

pub const CreateStreamError = error{
    OutOfMemory,
    SystemResources,
    IncompatibleBackend,
    IncompatibleDevice,
    OpeningDevice,
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
        .sample_rate = device.rate_range.clamp(options.sample_rate),
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
    sample_rate: u32,

    backend_data: PlayerBackendData(),

    fn PlayerBackendData() type {
        var fields: [std.meta.fields(BackendType).len]std.builtin.Type.UnionField = undefined;
        for (std.meta.fields(BackendType)) |b, i| {
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
            i8 => self.writei8(channel, frame, sample),
            u8 => self.writeu8(channel, frame, sample),
            i16 => self.writei16(channel, frame, sample),
            u16 => self.writeu16(channel, frame, sample),
            i24 => self.writei24(channel, frame, sample),
            u24 => self.writeu24(channel, frame, sample),
            i32 => self.writei32(channel, frame, sample),
            u32 => self.writeu32(channel, frame, sample),
            f32 => self.writef32(channel, frame, sample),
            f64 => self.writef64(channel, frame, sample),
            else => @compileError("invalid sample type"),
        }
    }

    pub inline fn writei8(self: *Player, channel: usize, frame: usize, sample: i8) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        switch (self.format) {
            .i8 => bytesAsValue(i8, ptr[0..@sizeOf(i8)]).* = sample,
            .u8 => @panic("TODO"),
            .i16 => bytesAsValue(i16, ptr[0..@sizeOf(i16)]).* = sample,
            .u16 => @panic("TODO"),
            .i24 => bytesAsValue(i24, ptr[0..@sizeOf(i24)]).* = sample,
            .u24 => @panic("TODO"),
            .i24_3b => bytesAsValue(i32, ptr[0..@sizeOf(i32)]).* = sample,
            .u24_3b => @panic("TODO"),
            .i32 => bytesAsValue(i32, ptr[0..@sizeOf(i32)]).* = sample,
            .u32 => @panic("TODO"),
            .f32 => @panic("TODO"),
            .f64 => @panic("TODO"),
        }
    }

    pub inline fn writeu8(self: *Player, channel: usize, frame: usize, sample: u8) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        switch (self.format) {
            .i8 => @panic("TODO"),
            .u8 => bytesAsValue(u8, ptr[0..@sizeOf(u8)]).* = sample,
            .i16 => @panic("TODO"),
            .u16 => bytesAsValue(u16, ptr[0..@sizeOf(u16)]).* = sample,
            .i24 => @panic("TODO"),
            .u24 => bytesAsValue(u24, ptr[0..@sizeOf(u24)]).* = sample,
            .i24_3b => @panic("TODO"),
            .u24_3b => bytesAsValue(u32, ptr[0..@sizeOf(u32)]).* = sample,
            .i32 => @panic("TODO"),
            .u32 => bytesAsValue(u32, ptr[0..@sizeOf(u32)]).* = sample,
            .f32 => @panic("TODO"),
            .f64 => @panic("TODO"),
        }
    }

    pub inline fn writei16(self: *Player, channel: usize, frame: usize, sample: i16) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        switch (self.format) {
            .i8 => @panic("TODO"),
            .u8 => @panic("TODO"),
            .i16 => bytesAsValue(i16, ptr[0..@sizeOf(i16)]).* = sample,
            .u16 => @panic("TODO"),
            .i24 => bytesAsValue(i24, ptr[0..@sizeOf(i24)]).* = sample,
            .u24 => @panic("TODO"),
            .i24_3b => bytesAsValue(i32, ptr[0..@sizeOf(i32)]).* = sample,
            .u24_3b => @panic("TODO"),
            .i32 => bytesAsValue(i32, ptr[0..@sizeOf(i32)]).* = sample,
            .u32 => @panic("TODO"),
            .f32 => @panic("TODO"),
            .f64 => @panic("TODO"),
        }
    }

    pub inline fn writeu16(self: *Player, channel: usize, frame: usize, sample: u16) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        switch (self.format) {
            .i8 => @panic("TODO"),
            .u8 => @panic("TODO"),
            .i16 => @panic("TODO"),
            .u16 => bytesAsValue(u16, ptr[0..@sizeOf(u16)]).* = sample,
            .i24 => @panic("TODO"),
            .u24 => bytesAsValue(u24, ptr[0..@sizeOf(u24)]).* = sample,
            .i24_3b => @panic("TODO"),
            .u24_3b => bytesAsValue(u32, ptr[0..@sizeOf(u32)]).* = sample,
            .i32 => @panic("TODO"),
            .u32 => bytesAsValue(u32, ptr[0..@sizeOf(u32)]).* = sample,
            .f32 => @panic("TODO"),
            .f64 => @panic("TODO"),
        }
    }

    pub inline fn writei24(self: *Player, channel: usize, frame: usize, sample: i24) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        switch (self.format) {
            .i8 => @panic("TODO"),
            .u8 => @panic("TODO"),
            .i16 => @panic("TODO"),
            .u16 => @panic("TODO"),
            .i24 => bytesAsValue(i24, ptr[0..@sizeOf(i24)]).* = sample,
            .u24 => @panic("TODO"),
            .i24_3b => bytesAsValue(i32, ptr[0..@sizeOf(i32)]).* = sample,
            .u24_3b => @panic("TODO"),
            .i32 => bytesAsValue(i32, ptr[0..@sizeOf(i32)]).* = sample,
            .u32 => @panic("TODO"),
            .f32 => @panic("TODO"),
            .f64 => @panic("TODO"),
        }
    }

    pub inline fn writeu24(self: *Player, channel: usize, frame: usize, sample: u24) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        switch (self.format) {
            .i8 => @panic("TODO"),
            .u8 => @panic("TODO"),
            .i16 => @panic("TODO"),
            .u16 => @panic("TODO"),
            .i24 => @panic("TODO"),
            .u24 => bytesAsValue(u24, ptr[0..@sizeOf(u24)]).* = sample,
            .i24_3b => @panic("TODO"),
            .u24_3b => bytesAsValue(u32, ptr[0..@sizeOf(u32)]).* = sample,
            .i32 => @panic("TODO"),
            .u32 => bytesAsValue(u32, ptr[0..@sizeOf(u32)]).* = sample,
            .f32 => @panic("TODO"),
            .f64 => @panic("TODO"),
        }
    }

    pub inline fn writei32(self: *Player, channel: usize, frame: usize, sample: i32) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        switch (self.format) {
            .i8 => @panic("TODO"),
            .u8 => @panic("TODO"),
            .i16 => @panic("TODO"),
            .u16 => @panic("TODO"),
            .i24 => @panic("TODO"),
            .u24 => @panic("TODO"),
            .i24_3b => @panic("TODO"),
            .u24_3b => @panic("TODO"),
            .i32 => bytesAsValue(i32, ptr[0..@sizeOf(i32)]).* = sample,
            .u32 => @panic("TODO"),
            .f32 => @panic("TODO"),
            .f64 => @panic("TODO"),
        }
    }

    pub inline fn writeu32(self: *Player, channel: usize, frame: usize, sample: u32) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        switch (self.format) {
            .i8 => @panic("TODO"),
            .u8 => @panic("TODO"),
            .i16 => @panic("TODO"),
            .u16 => @panic("TODO"),
            .i24 => @panic("TODO"),
            .u24 => @panic("TODO"),
            .i24_3b => @panic("TODO"),
            .u24_3b => @panic("TODO"),
            .i32 => @panic("TODO"),
            .u32 => bytesAsValue(u32, ptr[0..@sizeOf(u32)]).* = sample,
            .f32 => @panic("TODO"),
            .f64 => @panic("TODO"),
        }
    }

    pub inline fn writef32(self: *Player, channel: usize, frame: usize, sample: f32) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        switch (self.format) {
            .i8 => bytesAsValue(i8, ptr[0..@sizeOf(i8)]).* = f32ToSigned(i8, sample),
            .u8 => @panic("TODO"),
            .i16 => bytesAsValue(i16, ptr[0..@sizeOf(i16)]).* = f32ToSigned(i16, sample),
            .u16 => @panic("TODO"),
            .i24 => bytesAsValue(i24, ptr[0..@sizeOf(i24)]).* = f32ToSigned(i24, sample),
            .u24 => @panic("TODO"),
            .i24_3b => bytesAsValue(i32, ptr[0..@sizeOf(i32)]).* = f32ToSigned(i24, sample),
            .u24_3b => @panic("TODO"),
            .i32 => bytesAsValue(i32, ptr[0..@sizeOf(i32)]).* = f32ToSigned(i32, sample),
            .u32 => @panic("TODO"),
            .f32 => bytesAsValue(f32, ptr[0..@sizeOf(f32)]).* = sample,
            .f64 => bytesAsValue(f64, ptr[0..@sizeOf(f64)]).* = sample,
        }
    }

    pub inline fn writef64(self: *Player, channel: usize, frame: usize, sample: f64) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        switch (self.format) {
            .i8 => @panic("TODO"),
            .u8 => @panic("TODO"),
            .i16 => @panic("TODO"),
            .u16 => @panic("TODO"),
            .i24 => @panic("TODO"),
            .u24 => @panic("TODO"),
            .i24_3b => @panic("TODO"),
            .u24_3b => @panic("TODO"),
            .i32 => @panic("TODO"),
            .u32 => @panic("TODO"),
            .f32 => @panic("TODO"),
            .f64 => bytesAsValue(f64, ptr[0..@sizeOf(f64)]).* = sample,
        }
    }

    fn f32ToSigned(comptime T: type, sample: f32) T {
        const range = @intToFloat(f64, std.math.maxInt(T) - std.math.minInt(T));
        return @floatToInt(T, sample * range / 2.0);
    }
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
    rate_range: Range(u32),

    pub fn deinit(self: Device, allocator: std.mem.Allocator) void {
        return switch (current_backend.?) {
            inline else => |b| @field(SysAudio, @tagName(b)).deviceDeinit(self, allocator),
        };
    }

    pub fn preferredFormat(self: Device) Format {
        var best: Format = self.formats[0];
        for (self.formats) |fmt| {
            if (fmt.bytesPerSample() > best.bytesPerSample()) {
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
    front_right,
    front_left,
    front_right_center,
    front_left_center,
    front_right_wide,
    front_left_wide,
    front_center_high,
    front_right_high,
    front_left_high,
    back_center,
    back_right,
    back_left,
    side_right,
    side_left,
    top_center,
    top_front_center,
    top_front_right,
    top_front_left,
    top_back_center,
    top_back_right,
    top_back_left,
    back_right_center,
    back_left_center,
    top_front_right_center,
    top_front_left_center,
    top_side_right,
    top_side_left,
    right_lfe,
    left_lfe,
    lfe,
    lfe2,
    bottom_center,
    bottom_left_center,
    bottom_right_center,
    // Mid/side recording
    msmid,
    msside,
    // first order ambisonic channels
    ambisonic_w,
    ambisonic_x,
    ambisonic_y,
    ambisonic_z,
    // X-Y Recording
    xyx,
    xyy,
    // other channel ids
    headphones_right,
    headphones_left,
    click_track,
    foreign_language,
    hearing_impaired,
    narration,
    haptic,
    dialog_centric_mix,
    // AUX
    aux,
    aux0,
    aux1,
    aux2,
    aux3,
    aux4,
    aux5,
    aux6,
    aux7,
    aux8,
    aux9,
    aux10,
    aux11,
    aux12,
    aux13,
    aux14,
    aux15,
};

pub const Format = enum {
    i8,
    u8,
    i16,
    u16,
    i24,
    u24,
    i24_3b,
    u24_3b,
    i32,
    u32,
    f32,
    f64,

    pub fn bytesPerSample(self: Format) u4 {
        return switch (self) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i24, .u24 => 3,
            .i24_3b,
            .u24_3b,
            .i32,
            .u32,
            .f32,
            => 4,
            .f64 => 8,
        };
    }

    pub fn bytesPerFrame(self: Format, channel_count: u5) u8 {
        return self.bytesPerSample() * channel_count;
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
