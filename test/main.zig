const std = @import("std");
const sysaudio = @import("sysaudio");

test "connect()" {
    std.debug.print("\n", .{});
    inline for (&[_]sysaudio.Backend{ .Alsa, .PulseAudio, .Dummy }) |backend| {
        std.debug.print("{s} connect()\n", .{@tagName(backend)});
        var a = try sysaudio.connect(backend, std.testing.allocator, .{});
        defer a.disconnect();
        try a.flushEvents();
        try std.testing.expect(a.devicesList().len > 0);
    }
}

test "wakeUp()" {
    std.debug.print("\n", .{});
    inline for (&[_]sysaudio.Backend{ .Alsa, .PulseAudio, .Dummy }) |backend| {
        std.debug.print("{s} wakeUp()\n", .{@tagName(backend)});
        var a = try sysaudio.connect(backend, std.testing.allocator, .{});
        defer a.disconnect();
        var wait: usize = 4;
        while (wait > 0) : (wait -= 1) {
            a.wakeUp();
            try a.waitEvents();
        }
    }
}

test "waitEvents()" {
    if (true) return error.SkipZigTest;

    std.debug.print("\n", .{});
    inline for (&[_]sysaudio.Backend{ .Alsa, .PulseAudio, .Dummy }) |backend| {
        std.debug.print("{s} waitEvents()\n", .{@tagName(backend)});
        var a = try sysaudio.connect(backend, std.testing.allocator, .{});
        defer a.disconnect();
        var wait: usize = 4;
        while (wait > 0) : (wait -= 1) {
            try a.waitEvents();
            std.debug.print("finished\n", .{});
        }
    }
}
