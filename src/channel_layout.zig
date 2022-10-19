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

pub fn getLayout(id: ChannelLayoutId) ChannelLayout {
    return builtin_channel_layouts[@enumToInt(id)];
}
