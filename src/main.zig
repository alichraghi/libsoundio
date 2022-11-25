const builtin = @import("builtin");
const std = @import("std");
const channel_layout = @import("channel_layout.zig");
const bytesAsValue = std.mem.bytesAsValue;

const PulseAudio = @import("PulseAudio.zig");
const Alsa = @import("Alsa.zig");

const This = @This();
pub usingnamespace SoundIO;

comptime {
    std.testing.refAllDecls(@This());
    std.testing.refAllDeclsRecursive(SoundIO);
    std.testing.refAllDeclsRecursive(Player);
    std.testing.refAllDeclsRecursive(Device);
    std.testing.refAllDeclsRecursive(channel_layout);
    std.testing.refAllDeclsRecursive(PulseAudio);
    std.testing.refAllDeclsRecursive(Alsa);
    std.testing.refAllDeclsRecursive(@import("util.zig"));
}

pub const max_channels = 24;
pub const min_sample_rate = 8_000; // Hz
pub const max_sample_rate = 5_644_800; // Hz
pub const default_latency = 500 * std.time.ms_per_s; // μs

var current_backend: ?Backend = null;

pub const Backend = enum {
    PulseAudio,
    Alsa,
};
const SoundIO = union(Backend) {
    PulseAudio: *PulseAudio,
    Alsa: *Alsa,

    pub const ConnectOptions = struct {
        app_name: [:0]const u8 = "mach/sysaudio",
    };

    pub const ConnectError = error{
        OutOfMemory,
        Disconnected,
        InvalidServer,
        ConnectionRefused,
        ConnectionTerminated,
        SystemResources,
        AccessDenied,
    };

    /// must be called in the main thread
    pub fn connect(comptime backend: ?Backend, allocator: std.mem.Allocator, options: ConnectOptions) ConnectError!SoundIO {
        std.debug.assert(current_backend == null);
        var data: SoundIO = undefined;
        if (backend) |b| {
            data = @unionInit(
                SoundIO,
                @tagName(b),
                switch (b) {
                    .Alsa => try Alsa.connect(allocator),
                    .PulseAudio => try PulseAudio.connect(allocator, options),
                },
            );
        } else {
            switch (builtin.os.tag) {
                .linux, .freebsd => {
                    if (PulseAudio.connect(allocator, options)) |res| {
                        data = .{ .pulseaudio = res };
                    } else |err| {
                        data = .{ .alsa = Alsa.connect(allocator) catch return err };
                    }
                },
                .macos, .ios, .watchos, .tvos => @panic("TODO: CoreAudio"),
                .windows => @panic("TODO: WASAPI"),
                else => @compileError("Unsupported OS"),
            }
        }
        current_backend = std.meta.activeTag(data);
        return data;
    }

    pub fn deinit(self: SoundIO) void {
        switch (self) {
            inline else => |b| b.deinit(),
        }
        current_backend = null;
    }

    pub const EventsError = error{
        OutOfMemory,
        Disconnected,
        IncompatibleBackend,
        InvalidFormat,
        OpeningDevice,
        SystemResources,
    };

    pub fn flushEvents(self: SoundIO) EventsError!void {
        return switch (self) {
            inline else => |b| b.flushEvents(),
        };
    }

    pub fn waitEvents(self: SoundIO) EventsError!void {
        return switch (self) {
            inline else => |b| b.waitEvents(),
        };
    }

    pub const WakeUpError = error{};

    pub fn wakeUp(self: SoundIO) WakeUpError!void {
        return switch (self) {
            inline else => |b| b.wakeUp(),
        };
    }

    pub fn devicesList(self: SoundIO) []const Device {
        return switch (self) {
            inline else => |b| b.devices_info.list.items,
        };
    }

    pub fn getDevice(self: SoundIO, aim: Device.Aim, index: ?usize) ?Device {
        switch (self) {
            inline else => |b| {
                return b.devices_info.get(index orelse return b.devices_info.default(aim));
            },
        }
    }

    pub const CreateStreamError = error{
        OutOfMemory,
        IncompatibleBackend,
        IncompatibleDevice,
        StreamDisconnected,
        SystemResources,
        OpeningDevice,
    };

    pub const PlayerOptions = struct {
        writeFn: Player.WriteFn,
        sample_rate: u32 = 44_100,
        format: ?Format = null,
        userdata: ?*anyopaque = null,
    };

    pub fn createPlayer(self: SoundIO, device: Device, options: PlayerOptions) CreateStreamError!Player {
        var format: ?Format = null;
        if (options.format) |_| {
            for (device.formats) |dfmt| {
                if (options.format.? == dfmt) {
                    format = dfmt;
                    break;
                }
            }
            if (format == null)
                return error.IncompatibleDevice;
        } else {
            format = device.preferredFormat();
        }

        var player = Player{
            .backend_data = undefined,
            .writeFn = options.writeFn,
            .userdata = options.userdata,
            .channels = device.channels,
            .sample_rate = device.rate_range.clamp(options.sample_rate),
            .format = format.?,
            .bytes_per_frame = format.?.bytesPerFrame(@intCast(u5, device.channels.len)),
            .bytes_per_sample = format.?.bytesPerSample(),
            .paused = false,
        };
        switch (self) {
            inline else => |b| try b.openPlayer(&player, device),
        }
        return player;
    }
};

pub const StreamError = error{
    StreamDisconnected,
};
pub const StartStreamError = error{
    StreamDisconnected,
    OutOfMemory,
    SystemResources,
};

pub const ChannelsArray = std.BoundedArray(Channel, max_channels);

pub const Player = struct {
    // TODO: `*Player` instead `*anyopaque`
    // https://github.com/ziglang/zig/issues/12325
    pub const WriteError = error{WriteFailed};
    pub const WriteFn = *const fn (self: *anyopaque, err: WriteError!void, frame_count_max: usize) void;

    writeFn: WriteFn,
    userdata: ?*anyopaque,
    channels: ChannelsArray,
    sample_rate: u32,
    format: Format,
    bytes_per_frame: u32,
    bytes_per_sample: u32,
    paused: bool,

    backend_data: PlayerBackendData,
    const PlayerBackendData = union(Backend) {
        PulseAudio: PulseAudio.PlayerData,
        Alsa: Alsa.PlayerData,
    };

    pub fn deinit(self: *Player) void {
        return switch (current_backend.?) {
            inline else => |b| @field(This, @tagName(b)).playerDeinit(self),
        };
    }

    pub fn start(self: *Player) StartStreamError!void {
        return switch (current_backend.?) {
            inline else => |b| @field(This, @tagName(b)).playerStart(self),
        };
    }

    pub fn pause(self: *Player) (StreamError || error{ CannotPlay, CannotPause })!void {
        switch (current_backend.?) {
            inline else => |b| try @field(This, @tagName(b)).playerPausePlay(self, true),
        }
        self.paused = true;
    }

    pub fn play(self: *Player) (StreamError || error{ CannotPlay, CannotPause })!void {
        if (!self.paused) return;
        switch (current_backend.?) {
            inline else => |b| try @field(This, @tagName(b)).playerPausePlay(self, false),
        }
        self.paused = false;
    }

    pub const SetVolumeError = error{
        CannotSetVolume,
    };

    // confidence interval (±) depends on the device
    pub fn setVolume(self: *Player, vol: f32) SetVolumeError!void {
        std.debug.assert(vol <= 1.0);
        return switch (current_backend.?) {
            inline else => |b| @field(This, @tagName(b)).playerSetVolume(self, vol),
        };
    }

    pub const GetVolumeError = error{
        CannotGetVolume,
    };

    // confidence interval (±) depends on the device
    pub fn volume(self: *Player) GetVolumeError!f32 {
        return switch (current_backend.?) {
            inline else => |b| @field(This, @tagName(b)).playerVolume(self),
        };
    }

    pub fn writeAll(self: *Player, frame: usize, value: anytype) void {
        for (self.channels.slice()) |_, i|
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
        var ptr = self.channels.get(channel).ptr + self.bytes_per_frame * frame;
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
        var ptr = self.channels.get(channel).ptr + self.bytes_per_frame * frame;
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
        var ptr = self.channels.get(channel).ptr + self.bytes_per_frame * frame;
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
        var ptr = self.channels.get(channel).ptr + self.bytes_per_frame * frame;
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
        var ptr = self.channels.get(channel).ptr + self.bytes_per_frame * frame;
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
        var ptr = self.channels.get(channel).ptr + self.bytes_per_frame * frame;
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
        var ptr = self.channels.get(channel).ptr + self.bytes_per_frame * frame;
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
        var ptr = self.channels.get(channel).ptr + self.bytes_per_frame * frame;
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
        var ptr = self.channels.get(channel).ptr + self.bytes_per_frame * frame;
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
        var ptr = self.channels.get(channel).ptr + self.bytes_per_frame * frame;
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
    is_raw: bool,
    channels: ChannelsArray,
    formats: []const Format,
    rate_range: Range(u32),

    pub fn deinit(self: Device, allocator: std.mem.Allocator) void {
        return switch (current_backend.?) {
            inline else => |b| @field(This, @tagName(b)).deviceDeinit(self, allocator),
        };
    }

    pub fn preferredFormat(self: Device) Format {
        var best: u4 = 0;
        for (self.formats) |fmt| {
            if (@enumToInt(fmt) > best) {
                best = @enumToInt(fmt);
            }
        }
        return @intToEnum(Format, best);
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
    ptr: [*]u8,
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

    pub fn bytesPerSample(self: Format) u5 {
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
