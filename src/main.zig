const builtin = @import("builtin");
const std = @import("std");
const channel_layout = @import("channel_layout.zig");
const PulseAudio = @import("PulseAudio.zig");
const Alsa = @import("Alsa.zig");
const Jack = @import("Jack.zig");

comptime {
    std.testing.refAllDeclsRecursive(channel_layout);
    std.testing.refAllDeclsRecursive(PulseAudio);
    std.testing.refAllDeclsRecursive(Alsa);
    std.testing.refAllDeclsRecursive(Jack);
    std.testing.refAllDeclsRecursive(@import("util.zig"));
}

pub const max_channels = 24;
pub const min_sample_rate = 8000;
pub const max_sample_rate = 5644800;

var current_backend: ?Backend = null;

pub const Backend = enum {
    PulseAudio,
    Alsa,
    Jack,
};
const BackendData = union(Backend) {
    PulseAudio: *PulseAudio,
    Alsa: *Alsa,
    Jack: *Jack,
};

const SoundIO = @This();

data: BackendData,

pub const ConnectError = error{
    OutOfMemory,
    Disconnected,
    InvalidServer,
    ConnectionRefused,
    ConnectionTerminated,
    InitAudioBackend,
    SystemResources,
    NoSuchClient,
    IncompatibleBackend,
    InvalidFormat,
    Interrupted,
    AccessDenied,
};

pub const ShutdownFn = *const fn (userdata: ?*anyopaque) void;
pub const ConnectOptions = struct {
    /// not called in PulseAudio Backend
    shutdownFn: ?ShutdownFn = null,
    /// only useful when `shutdownFn` is used
    userdata: ?*anyopaque = null,
};

/// must be called in the main thread
pub fn connect(comptime backend: ?Backend, allocator: std.mem.Allocator, options: ConnectOptions) ConnectError!SoundIO {
    std.debug.assert(current_backend == null);
    var data: BackendData = undefined;
    if (backend) |b| {
        data = @unionInit(
            BackendData,
            @tagName(b),
            switch (b) {
                .Jack, .Alsa => try @field(@This(), @tagName(b)).connect(allocator, options),
                inline else => try @field(@This(), @tagName(b)).connect(allocator),
            },
        );
    } else {
        switch (builtin.os.tag) {
            .linux, .freebsd => {
                if (PulseAudio.connect(allocator)) |res| {
                    data = res;
                } else |err| {
                    Alsa.connect(allocator, options) catch return err;
                }
            },
            .macos, .ios, .watchos, .tvos => @panic("TODO: CoreAudio"),
            .windows => @panic("TODO: WASAPI"),
            else => @compileError("Unsupported OS"),
        }
    }
    current_backend = std.meta.activeTag(data);
    return .{
        .data = data,
    };
}

pub fn deinit(self: SoundIO) void {
    switch (self.data) {
        inline else => |b| b.deinit(),
    }
    current_backend = null;
}

pub const FlushEventsError = error{
    OutOfMemory,
    Interrupted,
    Disconnected,
    IncompatibleBackend,
    InvalidFormat,
    OpeningDevice,
    SystemResources,
};

pub fn flushEvents(self: SoundIO) FlushEventsError!void {
    return switch (self.data) {
        inline else => |b| b.flushEvents(),
    };
}

pub fn waitEvents(self: SoundIO) FlushEventsError!void {
    return switch (self.data) {
        inline else => |b| b.waitEvents(),
    };
}

pub fn wakeUp(self: SoundIO) void {
    return switch (self.data) {
        inline else => |b| b.wakeUp(),
    };
}

pub fn devicesList(self: SoundIO) []const Device {
    return switch (self.data) {
        inline else => |b| b.devices_info.list.items,
    };
}

pub fn getDevice(self: SoundIO, aim: Device.Aim, index: ?usize) ?Device {
    switch (self.data) {
        inline else => |b| {
            return b.devices_info.get(index orelse return b.devices_info.default(aim));
        },
    }
}

pub const CreateStreamError = error{
    OutOfMemory,
    Interrupted,
    IncompatibleBackend,
    IncompatibleDevice,
    StreamDisconnected,
    SystemResources,
    OpeningDevice,
};

pub const OutstreamOptions = struct {
    writeFn: Outstream.WriteFn,
    name: [:0]const u8 = "SoundIoOutstream",
    latency: f64 = 0.0,
    sample_rate: u32 = 48000,
    format: Format = Format.toNativeEndian(.float32le),
    userdata: ?*anyopaque = null,
};

pub fn createOutstream(self: SoundIO, device: Device, options: OutstreamOptions) CreateStreamError!Outstream {
    var fmt_found = false;
    for (device.formats) |fmt| {
        if (options.format == fmt) {
            fmt_found = true;
        }
    }
    if (!fmt_found) return error.IncompatibleDevice;
    var outstream = Outstream{
        .backend_data = undefined,
        .writeFn = options.writeFn,
        .userdata = options.userdata,
        .name = options.name,
        .layout = device.layout,
        .latency = options.latency,
        .sample_rate = device.nearestSampleRate(options.sample_rate),
        .format = options.format,
        .bytes_per_frame = options.format.bytesPerFrame(@intCast(u5, device.layout.channels.len)),
        .bytes_per_sample = options.format.bytesPerSample(),
        .paused = false,
    };
    switch (self.data) {
        inline else => |b| try b.openOutstream(&outstream, device),
    }
    return outstream;
}

pub const OpenStreamError = error{
    OutOfMemory,
    Interrupted,
    IncompatibleBackend,
    StreamDisconnected,
    OpeningDevice,
};

pub const StreamError = error{StreamDisconnected};
pub const StartStreamError = error{ StreamDisconnected, OutOfMemory, SystemResources };

pub const Outstream = struct {
    // TODO: `*Outstream` instead `*anyopaque`
    // https://github.com/ziglang/zig/issues/12325
    pub const WriteFn = *const fn (self: *anyopaque, areas: []const ChannelArea, frame_count_max: usize) void;

    writeFn: WriteFn,
    userdata: ?*anyopaque,
    name: [:0]const u8,
    layout: ChannelLayout,
    latency: f64,
    sample_rate: u32,
    format: Format,
    bytes_per_frame: u32,
    bytes_per_sample: u32,
    paused: bool,

    backend_data: OutstreamBackendData,
    const OutstreamBackendData = union(Backend) {
        PulseAudio: PulseAudio.OutstreamData,
        Alsa: Alsa.OutstreamData,
        Jack: void,
    };

    pub fn deinit(self: *Outstream) void {
        return switch (current_backend.?) {
            inline else => |b| @field(SoundIO, @tagName(b)).outstreamDeinit(self),
        };
    }

    pub fn start(self: *Outstream) StartStreamError!void {
        return switch (current_backend.?) {
            inline else => |b| @field(SoundIO, @tagName(b)).outstreamStart(self),
        };
    }

    pub fn clearBuffer(self: *Outstream) StreamError!void {
        return switch (current_backend.?) {
            inline else => |b| @field(SoundIO, @tagName(b)).outstreamClearBuffer(self),
        };
    }

    pub fn getLatency(self: *Outstream) StreamError!f64 {
        return switch (current_backend.?) {
            inline else => |b| @field(SoundIO, @tagName(b)).outstreamGetLatency(self),
        };
    }

    pub fn pause(self: *Outstream) StreamError!void {
        switch (current_backend.?) {
            inline else => |b| try @field(SoundIO, @tagName(b)).outstreamPausePlay(self, true),
        }
        self.paused = true;
    }

    pub fn play(self: *Outstream) StreamError!void {
        if (!self.paused) return;
        switch (current_backend.?) {
            inline else => |b| try @field(SoundIO, @tagName(b)).outstreamPausePlay(self, false),
        }
        self.paused = false;
    }

    pub fn setVolume(self: *Outstream, vol: f64) StreamError!void {
        std.debug.assert(vol <= 1.0);
        return switch (current_backend.?) {
            inline else => |b| @field(SoundIO, @tagName(b)).outstreamSetVolume(self, vol),
        };
    }

    pub const GetVolumeError = error{
        Interrupted,
        OutOfMemory,
    };

    pub fn volume(self: *Outstream) GetVolumeError!f64 {
        return switch (current_backend.?) {
            inline else => |b| @field(SoundIO, @tagName(b)).outstreamVolume(self),
        };
    }
};

pub const Device = struct {
    pub const Aim = enum {
        output,
        input,
    };

    id: [:0]const u8,
    name: [:0]const u8,
    aim: Aim,
    is_raw: bool,
    layout: ChannelLayout,
    formats: []const Format,
    sample_rate: Range(u32),
    latency: Range(f64),

    pub fn deinit(self: Device, allocator: std.mem.Allocator) void {
        return switch (current_backend.?) {
            inline else => |b| @field(SoundIO, @tagName(b)).deviceDeinit(self, allocator),
        };
    }

    pub fn nearestSampleRate(self: Device, sample_rate: u32) u32 {
        return std.math.clamp(sample_rate, self.sample_rate.min, self.sample_rate.max);
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
            .output => self.default_output = i,
            .input => self.default_input = i,
        }
    }

    pub fn defaultIndex(self: DevicesInfo, aim: Device.Aim) ?usize {
        return switch (aim) {
            .output => self.default_output,
            .input => self.default_input,
        };
    }
};

pub const ChannelLayout = struct {
    pub const Array = std.BoundedArray(ChannelId, max_channels);

    name: []const u8,
    channels: Array,

    pub fn eql(a: ChannelLayout, b_channels: []const ChannelId) bool {
        if (a.channels.len != b_channels.len) return false;
        for (a.channels.slice()) |_, i| {
            if (a.channels.get(i) != b_channels[i])
                return false;
        }
        return true;
    }
};

pub const ChannelArea = struct {
    ptr: [*]u8,
    step: u32,

    pub fn write(self: ChannelArea, value: anytype, frame_index: usize) void {
        @ptrCast(
            *@TypeOf(value),
            @alignCast(@alignOf(@TypeOf(value)), &self.ptr[self.step * frame_index]),
        ).* = value;
    }

    pub fn read(self: ChannelArea, comptime T: type, frame_index: usize) T {
        return @ptrCast(*T, @alignCast(@alignOf(T), &self.ptr[self.step * frame_index])).*;
    }
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
    s8,
    u8,
    s16le,
    s16be,
    u16le,
    u16be,
    s24le,
    s24be,
    u24le,
    u24be,
    s24_32le,
    s24_32be,
    u24_32le,
    u24_32be,
    s32le,
    s32be,
    u32le,
    u32be,
    /// -1.0<->1.0
    float32le,
    float32be,
    float64le,
    float64be,

    pub fn toNativeEndian(self: Format) Format {
        if (builtin.cpu.arch.endian() == .Little) {
            return switch (self) {
                .s16be => .s16le,
                .u16be => .u16le,
                .s24be => .s24le,
                .u24be => .u24le,
                .s24_32be => .s24_32le,
                .u24_32be => .u24_32le,
                .s32be => .s32le,
                .u32be => .u32le,
                .float32be => .float32le,
                .float64be => .float64le,
                else => self,
            };
        } else {
            return switch (self) {
                .s16le => .s16be,
                .u16le => .u16be,
                .s24le => .s24be,
                .u24le => .u24be,
                .s24_32le => .s24_32be,
                .u24_32le => .u24_32be,
                .s32le => .s32be,
                .u32le => .u32be,
                .float32le => .float32be,
                .float64le => .float64be,
                else => self,
            };
        }
    }

    pub fn bytesPerSample(self: Format) u5 {
        return switch (self) {
            .s8, .u8 => 1,
            .s16le, .s16be, .u16le, .u16be => 2,
            .s24le, .s24be, .u24le, .u24be => 3,
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
            => 4,
            .float64le, .float64be => 8,
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

        pub fn in(self: Self, num: T) bool {
            return if (num >= self.min and num <= self.max) true else false;
        }
    };
}
