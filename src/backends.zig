const std = @import("std");
const builtin = @import("builtin");

pub const PulseAudio = if (builtin.os.tag == .linux) @import("PulseAudio.zig") else void;
pub const Alsa = if (builtin.os.tag == .linux) @import("Alsa.zig") else void;
pub const WASApi = if (builtin.os.tag == .windows) @import("WASApi.zig") else void;
pub const Dummy = @import("Dummy.zig");

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
