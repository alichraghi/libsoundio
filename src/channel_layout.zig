const std = @import("std");
const ChannelLayout = @import("main.zig").ChannelLayout;
const ChannelId = @import("main.zig").ChannelId;

pub const builtin_channel_layouts = &[_]ChannelLayout{
    .{
        .name = "Mono",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_center,
        }) catch unreachable,
    },
    .{
        .name = "Stereo",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
        }) catch unreachable,
    },
    .{
        .name = "2.1",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .lfe,
        }) catch unreachable,
    },
    .{
        .name = "3.0",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
        }) catch unreachable,
    },
    .{
        .name = "3.0 (back)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .back_center,
        }) catch unreachable,
    },
    .{
        .name = "3.1",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .lfe,
        }) catch unreachable,
    },
    .{
        .name = "4.0",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .back_center,
        }) catch unreachable,
    },
    .{
        .name = "Quad",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .back_left,
            .back_right,
        }) catch unreachable,
    },
    .{
        .name = "Quad (side)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .side_left,
            .side_right,
        }) catch unreachable,
    },
    .{
        .name = "4.1",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .back_center,
            .lfe,
        }) catch unreachable,
    },
    .{
        .name = "5.0 (back)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .back_left,
            .back_right,
        }) catch unreachable,
    },
    .{
        .name = "5.0 (side)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .side_left,
            .side_right,
        }) catch unreachable,
    },
    .{
        .name = "5.1",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .side_left,
            .side_right,
            .lfe,
        }) catch unreachable,
    },
    .{
        .name = "5.1 (back)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .back_left,
            .back_right,
            .lfe,
        }) catch unreachable,
    },
    .{
        .name = "6.0 (side)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .side_left,
            .side_right,
            .back_center,
        }) catch unreachable,
    },
    .{
        .name = "6.0 (front)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .side_left,
            .side_right,
            .front_left_center,
            .front_right_center,
        }) catch unreachable,
    },
    .{
        .name = "Hexagonal",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .back_left,
            .back_right,
            .back_center,
        }) catch unreachable,
    },
    .{
        .name = "6.1",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .side_left,
            .side_right,
            .back_center,
            .lfe,
        }) catch unreachable,
    },
    .{
        .name = "6.1 (back)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .back_left,
            .back_right,
            .back_center,
            .lfe,
        }) catch unreachable,
    },
    .{
        .name = "6.1 (front)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .side_left,
            .side_right,
            .front_left_center,
            .front_right_center,
            .lfe,
        }) catch unreachable,
    },
    .{
        .name = "7.0",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .side_left,
            .side_right,
            .back_left,
            .back_right,
        }) catch unreachable,
    },
    .{
        .name = "7.0 (front)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .side_left,
            .side_right,
            .front_left_center,
            .front_right_center,
        }) catch unreachable,
    },
    .{
        .name = "7.1",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .side_left,
            .side_right,
            .back_left,
            .back_right,
            .lfe,
        }) catch unreachable,
    },
    .{
        .name = "7.1 (wide)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .side_left,
            .side_right,
            .front_left_center,
            .front_right_center,
            .lfe,
        }) catch unreachable,
    },
    .{
        .name = "7.1 (wide) (back)",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .back_left,
            .back_right,
            .front_left_center,
            .front_right_center,
            .lfe,
        }) catch unreachable,
    },
    .{
        .name = "Octagonal",
        .channels = ChannelLayout.Array.fromSlice(&.{
            .front_left,
            .front_right,
            .front_center,
            .side_left,
            .side_right,
            .back_left,
            .back_right,
            .back_center,
        }) catch unreachable,
    },
};

pub const ChannelLayoutId = enum(u5) {
    mono,
    stereo,
    @"2.1",
    @"3.0",
    @"3.0_back",
    @"3.1",
    @"4.0",
    quad,
    quadside,
    @"4.1",
    @"5.0_back",
    @"5.0_side",
    @"5.1",
    @"5.1_back",
    @"6.0_side",
    @"6.0_front",
    hexagonal,
    @"6.1",
    @"6.1_back",
    @"6.1_front",
    @"7.0",
    @"7.0_front",
    @"7.1",
    @"7.1_wide",
    @"7.1_wide_back",
    octagonal,
};

const channel_names: []const struct { tag: ChannelId, names: []const []const u8 } = &.{
    .{ .tag = .front_left, .names = &.{ "Front Left", "FL", "front-left" } },
    .{ .tag = .front_right, .names = &.{ "Front Right", "FR", "front-right" } },
    .{ .tag = .front_center, .names = &.{ "Front Center", "FC", "front-center" } },
    .{ .tag = .lfe, .names = &.{ "LFE", "LFE", "lfe" } },
    .{ .tag = .back_left, .names = &.{ "Back Left", "BL", "rear-left" } },
    .{ .tag = .back_right, .names = &.{ "Back Right", "BR", "rear-right" } },
    .{ .tag = .front_left_center, .names = &.{ "Front Left Center", "FLC", "front-left-of-center" } },
    .{ .tag = .front_right_center, .names = &.{ "Front Right Center", "FRC", "front-right-of-center" } },
    .{ .tag = .back_center, .names = &.{ "Back Center", "BC", "rear-center" } },
    .{ .tag = .side_left, .names = &.{ "Side Left", "SL", "side-left" } },
    .{ .tag = .side_right, .names = &.{ "Side Right", "SR", "side-right" } },
    .{ .tag = .top_center, .names = &.{ "Top Center", "TC", "top-center" } },
    .{ .tag = .top_front_left, .names = &.{ "Top Front Left", "TFL", "top-front-left" } },
    .{ .tag = .top_front_center, .names = &.{ "Top Front Center", "TFC", "top-front-center" } },
    .{ .tag = .top_front_right, .names = &.{ "Top Front Right", "TFR", "top-front-right" } },
    .{ .tag = .top_back_left, .names = &.{ "Top Back Left", "TBL", "top-rear-left" } },
    .{ .tag = .top_back_center, .names = &.{ "Top Back Center", "TBC", "top-rear-center" } },
    .{ .tag = .top_back_right, .names = &.{ "Top Back Right", "TBR", "top-rear-right" } },
    .{ .tag = .back_left_center, .names = &.{"Back Left Center"} },
    .{ .tag = .back_right_center, .names = &.{"Back Right Center"} },
    .{ .tag = .front_left_wide, .names = &.{"Front Left Wide"} },
    .{ .tag = .front_right_wide, .names = &.{"Front Right Wide"} },
    .{ .tag = .front_left_high, .names = &.{"Front Left High"} },
    .{ .tag = .front_center_high, .names = &.{"Front Center High"} },
    .{ .tag = .front_right_high, .names = &.{"Front Right High"} },
    .{ .tag = .top_front_left_center, .names = &.{"Top Front Left Center"} },
    .{ .tag = .top_front_right_center, .names = &.{"Top Front Right Center"} },
    .{ .tag = .top_side_left, .names = &.{"Top Side Left"} },
    .{ .tag = .top_side_right, .names = &.{"Top Side Right"} },
    .{ .tag = .left_lfe, .names = &.{"Left LFE"} },
    .{ .tag = .right_lfe, .names = &.{"Right LFE"} },
    .{ .tag = .lfe2, .names = &.{"LFE 2"} },
    .{ .tag = .bottom_center, .names = &.{"Bottom Center"} },
    .{ .tag = .bottom_left_center, .names = &.{"Bottom Left Center"} },
    .{ .tag = .bottom_right_center, .names = &.{"Bottom Right Center"} },
    .{ .tag = .msmid, .names = &.{"Mid/Side Mid"} },
    .{ .tag = .msside, .names = &.{"Mid/Side Side"} },
    .{ .tag = .ambisonic_w, .names = &.{"Ambisonic W"} },
    .{ .tag = .ambisonic_x, .names = &.{"Ambisonic X"} },
    .{ .tag = .ambisonic_y, .names = &.{"Ambisonic Y"} },
    .{ .tag = .ambisonic_z, .names = &.{"Ambisonic Z"} },
    .{ .tag = .xyx, .names = &.{"X-Y X"} },
    .{ .tag = .xyy, .names = &.{"X-Y Y"} },
    .{ .tag = .headphones_left, .names = &.{"Headphones Left"} },
    .{ .tag = .headphones_right, .names = &.{"Headphones Right"} },
    .{ .tag = .click_track, .names = &.{"Click Track"} },
    .{ .tag = .foreign_language, .names = &.{"Foreign Language"} },
    .{ .tag = .hearing_impaired, .names = &.{"Hearing Impaired"} },
    .{ .tag = .narration, .names = &.{"Narration"} },
    .{ .tag = .haptic, .names = &.{"Haptic"} },
    .{ .tag = .dialog_centric_mix, .names = &.{"Dialog Centric Mix"} },
    .{ .tag = .aux, .names = &.{"Aux"} },
    .{ .tag = .aux0, .names = &.{"Aux 0"} },
    .{ .tag = .aux1, .names = &.{"Aux 1"} },
    .{ .tag = .aux2, .names = &.{"Aux 2"} },
    .{ .tag = .aux3, .names = &.{"Aux 3"} },
    .{ .tag = .aux4, .names = &.{"Aux 4"} },
    .{ .tag = .aux5, .names = &.{"Aux 5"} },
    .{ .tag = .aux6, .names = &.{"Aux 6"} },
    .{ .tag = .aux7, .names = &.{"Aux 7"} },
    .{ .tag = .aux8, .names = &.{"Aux 8"} },
    .{ .tag = .aux9, .names = &.{"Aux 9"} },
    .{ .tag = .aux10, .names = &.{"Aux 10"} },
    .{ .tag = .aux11, .names = &.{"Aux 11"} },
    .{ .tag = .aux12, .names = &.{"Aux 12"} },
    .{ .tag = .aux13, .names = &.{"Aux 13"} },
    .{ .tag = .aux14, .names = &.{"Aux 14"} },
    .{ .tag = .aux15, .names = &.{"Aux 15"} },
};

pub fn getLayout(id: ChannelLayoutId) ChannelLayout {
    return builtin_channel_layouts[@enumToInt(id)];
}

pub fn getLayoutByChannels(channels: []const ChannelId) ?ChannelLayout {
    outer: for (builtin_channel_layouts) |bl| {
        if (channels.len != bl.channels.len) continue;
        inner: for (bl.channels.slice()) |bl_ch| {
            for (channels) |ch|
                if (bl_ch == ch) continue :inner;
            continue :outer;
        }
        return bl;
    }
    return null;
}

test "getLayoutByChannels" {
    const stereo = &.{
        .front_left,
        .front_right,
    };
    const stereo_inverted = &.{
        .front_right,
        .front_left,
    };
    const stereo_dup = &.{
        .front_left,
        .front_left,
        .front_right,
    };
    try std.testing.expectEqual(builtin_channel_layouts[1], getLayoutByChannels(stereo).?);
    try std.testing.expectEqual(builtin_channel_layouts[1], getLayoutByChannels(stereo_inverted).?);
    try std.testing.expect(getLayoutByChannels(stereo_dup) == null);
    try std.testing.expect(getLayoutByChannels(&.{}) == null);
}

pub fn getLayoutByChannelCount(count: u6) ?ChannelLayout {
    for (builtin_channel_layouts) |bl| {
        if (count == bl.channels.len)
            return bl;
    }
    return null;
}

pub fn parseChannelId(str: []const u8) ?ChannelId {
    for (channel_names) |cns| {
        for (cns.names) |cni| {
            if (std.mem.eql(u8, cni, str)) return cns.tag;
        }
    }
    return null;
}
