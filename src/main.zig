const std = @import("std");
const backends = @import("backends.zig");

const max_channels = 24;

pub const ChannelLayout = struct {
    name: []const u8,
    channel_count: usize,
    channels: [max_channels]ChannelId,
};

pub const ChannelId = enum {
    invalid,

    /// more commonly supported ids.
    front_left,
    front_right,
    front_center,
    lfe,
    back_left,
    back_right,
    front_left_center,
    front_right_center,
    back_center,
    side_left,
    side_right,
    top_center,
    top_front_left,
    top_front_center,
    top_front_right,
    top_back_left,
    top_backc_enter,
    top_back_right,

    /// less commonly supported ids.
    back_left_center,
    back_right_center,
    front_left_wide,
    front_right_wide,
    front_left_high,
    front_center_high,
    front_right_high,
    top_front_left_center,
    top_front_right_center,
    top_side_left,
    top_side_right,
    left_lfe,
    right_lfe,
    lfe2,
    bottom_center,
    bottom_left_center,
    bottom_right_center,

    /// Mid/side recording
    msmid,
    msside,

    /// first order ambisonic channels
    ambisonic_w,
    ambisonic_x,
    ambisonic_y,
    ambisonic_z,

    /// X-Y Recording
    xyx,
    xyy,

    /// other channel ids
    headphones_left,
    headphones_right,
    click_track,
    foreign_language,
    hearing_impaired,
    narration,
    haptic,
    dialog_centric_mix,

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
    invalid,
    /// Signed 8 bit
    s8,
    /// Unsigned 8 bit
    u8,
    /// Signed 16 bit Little Endian
    s16le,
    /// Signed 16 bit Big Endian
    s16be,
    /// Unsigned 16 bit Little Endian
    u16le,
    /// Unsigned 16 bit Big Endian
    u16be,
    /// Signed 24 bit Little Endian using low three bytes in 32-bit word
    s24le,
    /// Signed 24 bit Big Endian using low three bytes in 32-bit word
    s24be,
    /// Unsigned 24 bit Little Endian using low three bytes in 32-bit word
    u24le,
    /// Unsigned 24 bit Big Endian using low three bytes in 32-bit word
    u24be,
    /// Signed 32 bit Little Endian
    s32le,
    /// Signed 32 bit Big Endian
    s32be,
    /// Unsigned 32 bit Little Endian
    u32le,
    /// Unsigned 32 bit Big Endian
    u32be,
    /// Float 32 bit Little Endian, Range -1.0 to 1.0
    float32le,
    /// Float 32 bit Big Endian, Range -1.0 to 1.0
    float32be,
    /// Float 64 bit Little Endian, Range -1.0 to 1.0
    float64le,
    /// Float 64 bit Big Endian, Range -1.0 to 1.0
    float64be,
};

pub const SampleRateRange = struct {
    min: usize,
    max: usize,
};

pub const Device = struct {
    pub const Aim = enum {
        Output,
        Input,
    };

    id: []const u8,
    name: []const u8,
    aim: Aim,
    layouts: []const ChannelLayout,
    current_layout: *const ChannelLayout,
    formats: []const Format,
    current_format: *const Format,
    sample_rates: []const SampleRateRange,
    current_sample_rate: *const SampleRateRange,
    software_latency_min: f64,
    software_latency_max: f64,
    current_software_latency: f64,
    is_raw: bool,
};

pub const DevicesInfo = struct {
    input_devices: std.ArrayList(Device),
    output_devices: std.ArrayList(Device),
    default_output_index: usize,
    default_input_index: usize,
};

test {
    std.testing.refAllDeclsRecursive(@This());
    var a = try backends.pulseaudio.connect(std.testing.allocator, .{});
    while (true) {
        switch ((a.flushWaitEvents(true) catch |err| {
            std.debug.print("err: {s}!\n", .{@errorName(err)});
            continue;
        }) orelse continue) {
            .devices_changed => std.debug.print("changed!\n", .{}),
            // .shutdown => |err| std.debug.print("err: {s}!\n", .{@errorName(err)}),
            // .shutdown => |err| {
            //     std.debug.print("an error acurred ({s})!\n", .{@errorName(err)});
            //     a.deinit();
            //     break;
            // },
            // else => {},
        }
    }
}
