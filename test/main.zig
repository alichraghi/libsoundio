const std = @import("std");
const soundio = @import("soundio");

test "Jack connect()" {
    if (true) return error.SkipZigTest;

    var a = try soundio.connect(.jack, std.testing.allocator, .{ .shutdownFn = shutdownFn });
    defer a.deinit();
    try std.testing.expect(a.devicesList().len > 0);
}

fn shutdownFn(_: ?*anyopaque) void {
    std.os.exit(1);
}

test "PulseAudio connect()" {
    var a = try soundio.connect(.pulseaudio, std.testing.allocator, .{});
    defer a.deinit();
    try std.testing.expect(a.devicesList().len > 0);
}

test "PipeWire connect()" {
    // if (true) return error.SkipZigTest;

    var a = try soundio.connect(.pipewire, std.testing.allocator, .{});
    var o = try a.createOutstream(undefined, .{ .writeFn = writeCallback2 });
    defer o.deinit();
    try o.start();
    defer a.deinit();
}

test "PulseAudio SineWave" {
    var a = try soundio.connect(.pulseaudio, std.testing.allocator, .{});
    defer a.deinit();
    const device = a.getDevice(.output, null) orelse return error.SkipZigTest;
    var o = try a.createOutstream(device, .{ .writeFn = writeCallback });
    defer o.deinit();
    try o.start();

    var v: f64 = 0.7;
    while (v > 0.15) : (v -= 0.0005) {
        try o.setVolume(v);
        std.time.sleep(std.time.ns_per_ms * 5);
    }
    const volume = try o.volume();
    try std.testing.expect(volume > 0.1499 and volume <= 0.15);
}

fn writeCallback2(self_opaque: *anyopaque, _: usize, frame_count_max: usize) void {
    var self = @ptrCast(*soundio.Outstream, @alignCast(@alignOf(*soundio.Outstream), self_opaque));
    var frames_left = frame_count_max;

    while (frames_left > 0) {
        var fpb = frames_left; // frames per buffer
        _ = self.beginWrite(&fpb) catch unreachable;
        // self.endWrite() catch unreachable;
        frames_left -= fpb;
    }
}

var seconds_offset: f32 = 0;
fn writeCallback(self_opaque: *anyopaque, _: usize, frame_count_max: usize) void {
    var self = @ptrCast(*soundio.Outstream, @alignCast(@alignOf(*soundio.Outstream), self_opaque));
    const seconds_per_frame = 1.0 / @intToFloat(f32, self.sample_rate);
    const pitch = 440.0;
    const radians_per_second = pitch * 2.0 * std.math.pi;
    var frames_left = frame_count_max;

    while (frames_left > 0) {
        var fpb = frames_left; // frames per buffer
        const areas = self.beginWrite(&fpb) catch unreachable;
        for (@as([*]void, undefined)[0..fpb]) |_, i| {
            const sample = std.math.sin((seconds_offset + seconds_per_frame * @intToFloat(f32, i)) * radians_per_second);
            for (areas) |area|
                area.write(sample, i);
        }
        seconds_offset += seconds_per_frame * @intToFloat(f32, fpb);
        self.endWrite() catch unreachable;
        frames_left -= fpb;
    }
}

test "PulseAudio waitEvents()" {
    if (true) return error.SkipZigTest;

    var a = try soundio.connect(null, std.testing.allocator, .{});
    defer a.deinit();
    var wait: u2 = 2;
    while (wait > 0) : (wait -= 1)
        try a.waitEvents();
}

test "PulseAudio connect() deinit()" {
    var a = try soundio.connect(null, std.testing.allocator, .{});
    const ad = a.getDevice(.output, null) orelse return error.SkipZigTest;
    var ao = try a.createOutstream(ad, .{ .writeFn = undefined });
    ao.deinit();
    a.deinit();

    var b = try soundio.connect(null, std.testing.allocator, .{});
    b.deinit();

    var c = try soundio.connect(null, std.testing.allocator, .{});
    c.deinit();
}
