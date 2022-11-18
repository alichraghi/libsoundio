const std = @import("std");
const soundio = @import("soundio");

test "connect()" {
    std.debug.print("\n", .{});
    inline for (&[_]soundio.Backend{ .Alsa, .PulseAudio }) |backend| {
        std.debug.print("{s} connect()\n", .{@tagName(backend)});
        var a = try soundio.connect(.Alsa, std.testing.allocator);
        defer a.deinit();
        try a.flushEvents();
        try std.testing.expect(a.devicesList().len > 0);
    }
}

test "waitEvents()" {
    std.debug.print("\n", .{});
    inline for (&[_]soundio.Backend{ .Alsa, .PulseAudio }) |backend| {
        std.debug.print("{s} waitEvents()\n", .{@tagName(backend)});
        var a = try soundio.connect(.Alsa, std.testing.allocator);
        defer a.deinit();
        var wait: u4 = 0;
        while (wait < 4) : (wait += 1) {
            a.wakeUp();
            try a.waitEvents();
        }
    }
}

test "Sine Wave (pause, play)" {
    std.debug.print("\n", .{});
    inline for (&[_]soundio.Backend{ .Alsa, .PulseAudio }) |backend| {
        std.debug.print("{s} Sine Wave", .{@tagName(backend)});
        var a = try soundio.connect(backend, std.testing.allocator);
        defer a.deinit();
        try a.flushEvents();
        const device = a.getDevice(.playback, null) orelse {
            std.debug.print(": No default device found (SKIPPING)\n", .{});
            break;
        };
        for (a.devicesList()) |d|
            std.debug.print("- {s}\n", .{d.id});
        for (device.formats) |d|
            std.debug.print("- {s}\n", .{@tagName(d)});
        var p = try a.createPlayer(device, .{ .writeFn = writeCallback, .format = .float32le });
        defer p.deinit();
        try p.start();

        try p.setVolume(1.0);
        std.time.sleep(std.time.ns_per_ms * 500);
        try p.pause();
        std.time.sleep(std.time.ns_per_ms * 500);
        try p.play();
        std.time.sleep(std.time.ns_per_ms * 500);
        try p.pause();
        std.time.sleep(std.time.ns_per_ms * 500);
        try p.play();
        std.time.sleep(std.time.ns_per_ms * 500);
        // var v: f64 = 0.7;
        // while (v > 0.15) : (v -= 0.0005) {
        //     try o.setVolume(v);
        //     std.time.sleep(std.time.ns_per_ms * 5);
        // }
        // const volume = try o.volume();
        // try std.testing.expect(volume > 0.1499 and volume <= 0.15);
        std.debug.print("\n", .{});
    }
}

const pitch = 440.0;
const radians_per_second = pitch * 2.0 * std.math.pi;
var seconds_offset: f32 = 0.0;
fn writeCallback(self_opaque: *anyopaque, err: soundio.Player.WriteError!void, n_frame: usize) void {
    err catch unreachable;

    // _ = self_opaque;
    // var frame: usize = 0;
    // var r = std.rand.DefaultPrng.init(@intCast(u64, std.time.timestamp()));
    // while (frame < n_frame) : (frame += 1) {
    //     const sample = r.random().int(i32);
    //     for (areas) |area| {
    //         area.write(sample, frame);
    //     }
    // }

    var self = @ptrCast(*soundio.Player, @alignCast(@alignOf(soundio.Player), self_opaque));
    const seconds_per_frame = 1.0 / @intToFloat(f32, self.sample_rate);
    var frame: usize = 0;
    while (frame < n_frame) : (frame += 1) {
        const sample = std.math.sin((seconds_offset + @intToFloat(f32, frame) * seconds_per_frame) * radians_per_second);
        for (self.layout.channels.slice()) |_, i| {
            self.write(i, frame, sample);
        }
    }
    seconds_offset = @mod(seconds_offset + seconds_per_frame * @intToFloat(f32, n_frame), 1.0);
}
