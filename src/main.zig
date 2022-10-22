const builtin = @import("builtin");
const std = @import("std");
const PulseAudio = @import("PulseAudio.zig");
const channel_layout = @import("channel_layout.zig");

pub const max_channels = 24;
pub const min_sample_rate = 8000;
pub const max_sample_rate = 5644800;

var connected = false;
var current_backend: ?Backend = null;

const SoundIO = @This();

pub const Backend = enum {
    pulseaudio,
};
const BackendData = union(Backend) {
    pulseaudio: *PulseAudio,
};

data: BackendData,

pub const AutoConnectError = PulseAudio.ConnectError; // || ...
pub fn connect(allocator: std.mem.Allocator) AutoConnectError!SoundIO {
    std.debug.assert(!connected);
    errdefer connected = false;
    connected = true;
    if (current_backend) |b| {
        return switch (b) {
            .pulseaudio => .{ .data = .{
                .pulseaudio = try PulseAudio.connect(allocator),
            } },
        };
    }
    switch (builtin.os.tag) {
        .linux, .freebsd => {
            current_backend = .pulseaudio;
            return SoundIO{
                .data = .{
                    .pulseaudio = PulseAudio.connect(allocator) catch @panic("TODO: Alsa & Jack"),
                },
            };
        },
        .macos, .ios, .watchos, .tvos => @panic("TODO: CoreAudio"),
        .windows => @panic("TODO: WASAPI"),
        else => @compileError("Unsupported OS"),
    }
}

pub fn ConnectError(comptime backend: Backend) type {
    return switch (backend) {
        .pulseaudio => PulseAudio.ConnectError,
    };
}
fn connectBackend(comptime backend: Backend, allocator: std.mem.Allocator) ConnectError(Backend)!SoundIO {
    return .{ .data = @unionInit(
        Backend,
        @tagName(backend),
        switch (backend) {
            .pulseaudio => try PulseAudio.connect(allocator),
        },
    ) };
}

pub fn deinit(self: SoundIO) void {
    connected = false;
    return switch (self.data) {
        .pulseaudio => |tag| tag.deinit(), // inline else
    };
}

pub fn flushEvents(self: SoundIO) !void {
    return switch (self.data) {
        .pulseaudio => |tag| try tag.flushEvents(), // inline else
    };
}

pub fn waitEvents(self: SoundIO) !void {
    return switch (self.data) {
        .pulseaudio => |tag| try tag.waitEvents(), // inline else
    };
}

pub fn wakeUp(self: SoundIO) void {
    return switch (self.data) {
        .pulseaudio => |tag| tag.wakeUp(self),
    };
}

pub fn devicesList(self: SoundIO, aim: Device.Aim) []const Device {
    return switch (self.data) {
        .pulseaudio => |tag| tag.devicesList(aim), // inline else
    };
}

pub fn getDevice(self: SoundIO, aim: Device.Aim, index: ?usize) Device {
    return switch (self.data) {
        .pulseaudio => |tag| tag.getDevice(aim, index), // inline else
    };
}

pub const OutstreamOptions = struct {
    writeFn: WriteFn,
    underflowFn: ?UnderflowFn = null,
    name: []const u8 = "SoundIoStream",
    software_latency: f64 = 0.0,
    sample_rate: u32 = 48000,
    format: Format = if (builtin.cpu.arch.endian() == .Little) .float32le else .float32be,
    userdata: ?*anyopaque = null,
};
pub fn createOutstream(self: SoundIO, device: Device, options: OutstreamOptions) !Outstream {
    var outstream = Outstream{
        .backend_data = undefined,
        .writeFn = options.writeFn,
        .underflowFn = options.underflowFn,
        .userdata = options.userdata,
        .name = options.name,
        .layout = device.layout,
        .software_latency = options.software_latency,
        .sample_rate = device.nearestSampleRate(options.sample_rate),
        .format = options.format,
        .bytes_per_frame = options.format.bytesPerFrame(@intCast(u5, device.layout.channels.len)),
        .bytes_per_sample = options.format.bytesPerSample(),
        .paused = false,
        .volume = 1.0,
    };
    switch (self.data) {
        .pulseaudio => |tag| try tag.openOutstream(&outstream, device), // inline else
    }
    return outstream;
}

pub const ChannelLayout = struct {
    pub const Array = std.BoundedArray(ChannelId, max_channels);

    name: ?[]const u8,
    channels: Array,

    pub fn eql(a: ChannelLayout, b: ChannelLayout) bool {
        if (a.channels.len != b.channels.len)
            return false;
        for (a.channels.constSlice()) |_, i|
            if (a.channels.get(i) != b.channels.get(i))
                return false;
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
        return @ptrCast(*T, @alignCast(@alignOf(T), &self.ptr[self.step * frame_index]));
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
    s32le,
    s32be,
    u32le,
    u32be,
    // Range -1.0 to 1.0
    float32le,
    float32be,
    float64le,
    float64be,

    pub fn bytesPerSample(self: Format) u5 {
        return switch (self) {
            .s8, .u8 => 1,
            .s16le, .s16be, .u16le, .u16be => 2,
            .s24le, .s24be, .u24le, .u24be, .s32le, .s32be, .u32le, .u32be, .float32le, .float32be => 4,
            .float64le, .float64be => 8,
        };
    }

    pub fn bytesPerFrame(self: Format, channel_count: u5) u8 {
        return self.bytesPerSample() * channel_count;
    }
};

pub const SampleRateRange = struct {
    min: u32,
    max: u32,
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
    current_format: Format,
    sample_rates: std.BoundedArray(SampleRateRange, 16),
    current_sample_rate: u32,
    software_latency_min: ?f64,
    software_latency_max: ?f64,
    current_software_latency: ?f64,

    pub fn deinit(self: Device, allocator: std.mem.Allocator) void {
        return switch (current_backend.?) {
            .pulseaudio => PulseAudio.deviceDeinit(self, allocator),
        };
    }

    pub fn nearestSampleRate(self: Device, sample_rate: u32) u32 {
        var best_rate: u32 = 0;
        var best_delta: u32 = 0;
        for (self.sample_rates.constSlice()) |range| {
            var candidate_rate = std.math.clamp(sample_rate, range.min, range.max);
            if (candidate_rate == sample_rate)
                return candidate_rate;

            var delta = std.math.absCast(@intCast(i32, candidate_rate) - @intCast(i32, sample_rate));
            const best_rate_too_small = best_rate < sample_rate;
            const candidate_rate_too_small = candidate_rate < sample_rate;
            if (best_rate == 0 or
                (best_rate_too_small and !candidate_rate_too_small) or
                ((best_rate_too_small or !candidate_rate_too_small) and delta < best_delta))
            {
                best_rate = candidate_rate;
                best_delta = delta;
            }
        }
        return best_rate;
    }
};

pub const DevicesInfo = struct {
    outputs: std.ArrayListUnmanaged(Device),
    inputs: std.ArrayListUnmanaged(Device),
    default_output_index: usize,
    default_input_index: usize,
};

// TODO: `*Outstream` instead `*anyopaque`
// https://github.com/ziglang/zig/issues/12325
pub const WriteFn = *const fn (self: *anyopaque, frame_count_min: usize, frame_count_max: usize) anyerror!void;
pub const UnderflowFn = *const fn (self: *anyopaque) anyerror!void;

pub const Outstream = struct {
    writeFn: WriteFn,
    underflowFn: ?UnderflowFn,
    userdata: ?*anyopaque,
    name: []const u8,
    layout: ChannelLayout,
    software_latency: f64,
    sample_rate: u32,
    format: Format,
    bytes_per_frame: u32,
    bytes_per_sample: u32,
    paused: bool,
    volume: f64,

    backend_data: OutstreamBackendData,
    const OutstreamBackendData = union {
        pulseaudio: PulseAudio.OutstreamData,
    };

    pub fn deinit(self: *Outstream) void {
        return switch (current_backend.?) {
            .pulseaudio => PulseAudio.outstreamDeinit(self),
        };
    }

    pub fn start(self: *Outstream) !void {
        return switch (current_backend.?) {
            .pulseaudio => PulseAudio.outstreamStart(self),
        };
    }

    pub fn beginWrite(self: *Outstream, frame_count: *usize) error{StreamDisconnected}![]const ChannelArea {
        return switch (current_backend.?) {
            .pulseaudio => PulseAudio.outstreamBeginWrite(self, frame_count),
        };
    }

    pub fn endWrite(self: *Outstream) error{StreamDisconnected}!void {
        return switch (current_backend.?) {
            .pulseaudio => PulseAudio.outstreamEndWrite(self),
        };
    }

    pub fn clearBuffer(self: *Outstream) error{StreamDisconnected}!void {
        return switch (current_backend.?) {
            .pulseaudio => PulseAudio.outstreamClearBuffer(self),
        };
    }

    pub fn getLatency(self: *Outstream) error{StreamDisconnected}!f64 {
        return switch (current_backend.?) {
            .pulseaudio => PulseAudio.outstreamGetLatency(self),
        };
    }

    pub fn pause(self: *Outstream) error{StreamDisconnected}!void {
        return switch (current_backend.?) {
            .pulseaudio => {
                try PulseAudio.outstreamPausePlay(self, true);
                self.paused = true;
            },
        };
    }

    pub fn play(self: *Outstream) error{StreamDisconnected}!void {
        if (!self.paused) return;
        return switch (current_backend.?) {
            .pulseaudio => PulseAudio.outstreamPausePlay(self, false),
        };
    }

    pub fn setVolume(self: *Outstream, volume: f64) error{StreamDisconnected}!void {
        std.debug.assert(volume <= 1.0);
        return switch (current_backend.?) {
            .pulseaudio => PulseAudio.outstreamSetVolume(self, volume),
        };
    }
};
