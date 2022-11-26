const std = @import("std");
const sysaudio = @import("sysaudio");

test "connect()" {
    std.debug.print("\n", .{});
    inline for (&[_]sysaudio.Backend{ .Alsa, .PulseAudio }) |backend| {
        std.debug.print("{s} connect()\n", .{@tagName(backend)});
        var a = try sysaudio.connect(backend, std.testing.allocator, .{});
        defer a.deinit();
        try a.flushEvents();
        try std.testing.expect(a.devicesList().len > 0);
    }
}

test "wakeUp()" {
    std.debug.print("\n", .{});
    inline for (&[_]sysaudio.Backend{ .Alsa, .PulseAudio }) |backend| {
        std.debug.print("{s} wakeUp()\n", .{@tagName(backend)});
        var a = try sysaudio.connect(backend, std.testing.allocator, .{});
        defer a.deinit();
        var wait: usize = 4;
        while (wait > 0) : (wait -= 1) {
            try a.wakeUp();
            try a.waitEvents();
        }
    }
}

test "waitEvents()" {
    if (true) return error.SkipZigTest;

    std.debug.print("\n", .{});
    inline for (&[_]sysaudio.Backend{ .Alsa, .PulseAudio }) |backend| {
        std.debug.print("{s} waitEvents()\n", .{@tagName(backend)});
        var a = try sysaudio.connect(backend, std.testing.allocator, .{});
        defer a.deinit();
        var wait: usize = 4;
        while (wait > 0) : (wait -= 1) {
            try a.waitEvents();
            std.debug.print("finished\n", .{});
        }
    }
}

test "Sine Wave (pause, play, volume)" {
    std.debug.print("\n", .{});
    inline for (&[_]sysaudio.Backend{ .Alsa, .PulseAudio }) |backend| {
        std.debug.print("{s} Sine Wave", .{@tagName(backend)});
        var a = try sysaudio.connect(backend, std.testing.allocator, .{});
        defer a.deinit();
        try a.flushEvents();
        const device = a.getDevice(.playback, null) orelse return error.SkipZigTest;

        var p = try a.createPlayer(device, .{ .writeFn = writeCallback, .format = .i16 });
        defer p.deinit();
        try p.start();
        try p.setVolume(0.7);
        std.time.sleep(std.time.ns_per_s);

        try p.pause();
        std.time.sleep(std.time.ns_per_s);
        try std.testing.expect(p.paused());
        try p.play();
        try std.testing.expect(!p.paused());

        try p.setVolume(0.5);
        std.time.sleep(std.time.ns_per_s);

        try p.setVolume(0.3);
        std.time.sleep(std.time.ns_per_s);

        try p.setVolume(0.12);
        const volume = try p.volume();
        try std.testing.expect(volume >= 0.11);

        std.debug.print("{d}\n", .{volume});
    }
}

const pitch = 440.0;
const radians_per_second = pitch * 2.0 * std.math.pi;
var seconds_offset: f32 = 0.0;
fn writeCallback(self_opaque: *anyopaque, err: sysaudio.Player.WriteError!void, n_frame: usize) void {
    err catch unreachable;
    var self = @ptrCast(*sysaudio.Player, @alignCast(@alignOf(sysaudio.Player), self_opaque));

    // var frame: usize = 0;
    // var r = std.rand.DefaultPrng.init(@intCast(u64, std.time.timestamp()));
    // while (frame < n_frame) : (frame += 1) {
    //     const sample = r.random().int(i16);
    //     self.writeAll(frame, sample);
    // }

    const seconds_per_frame = 1.0 / @intToFloat(f32, self.sample_rate);
    var frame: usize = 0;
    while (frame < n_frame) : (frame += 1) {
        const sample = std.math.sin((seconds_offset + @intToFloat(f32, frame) * seconds_per_frame) * radians_per_second);
        self.writeAll(frame, sample);
    }
    seconds_offset = @mod(seconds_offset + seconds_per_frame * @intToFloat(f32, n_frame), 1.0);
}
