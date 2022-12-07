const std = @import("std");
const builtin = @import("builtin");

pub const PulseAudio = if (isUnix()) @import("PulseAudio.zig") else void;
pub const Alsa = if (isUnix()) @import("Alsa.zig") else void;
pub const WASApi = if (isWindows()) @import("WASApi.zig") else void;
pub const Dummy = @import("Dummy.zig");

pub const Backend = std.meta.Tag(BackendData);
pub const BackendData = if (isUnix()) union(enum) {
    PulseAudio: *PulseAudio,
    Alsa: *Alsa,
    Dummy: *Dummy,
} else if (isApple()) union(enum) {
    Dummy: *Dummy,
} else if (isWindows()) union(enum) {
    WASApi: *WASApi,
    Dummy: *Dummy,
} else union(enum) {
    Dummy: *Dummy,
};

// ignores macos, ios, ...
fn isUnix() bool {
    return switch (builtin.os.tag) {
        .linux,
        .dragonfly,
        .freebsd,
        .kfreebsd,
        .netbsd,
        .openbsd,
        .minix,
        .fuchsia,
        .solaris,
        => true,
        else => false,
    };
}

fn isApple() bool {
    return switch (builtin.os.tag) {
        .macos,
        .ios,
        .watchos,
        .tvos,
        => true,
        else => false,
    };
}

fn isWindows() bool {
    return builtin.os.tag == .windows;
}
