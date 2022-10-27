const std = @import("std");
const soundio = @import("soundio");

test "reference" {
    return error.SkipZigTest;
}

test "jack" {
    var a = try soundio.connect(.jack, std.testing.allocator, .{ .shutdownFn = shutdownFn });
    defer a.deinit();
}

fn shutdownFn(_: ?*anyopaque) void {
    std.os.exit(1);
}

test "flush events" {
    var a = try soundio.connect(null, std.testing.allocator, .{});
    defer a.deinit();
    try a.flushEvents();
    try std.testing.expect(a.devicesList(.output).len > 0);
}

test "sine wave" {
    var a = try soundio.connect(null, std.testing.allocator, .{});
    defer a.deinit();
    try a.flushEvents();
    const device = a.getDevice(.output, null);
    var o = try a.createOutstream(device, .{ .writeFn = writeCallback });
    defer o.deinit();
    try o.start();

    var v: f64 = 1.0;
    while (v > 0.3) : (v -= 0.001) {
        try o.setVolume(v);
        std.time.sleep(std.time.ns_per_ms * 1);
    }
    const volume = try o.volume();
    try std.testing.expect(volume >= 0.3 and volume < 0.31);
}

var seconds_offset: f32 = 0;
fn writeCallback(self_any: *anyopaque, _: usize, frame_count_max: usize) void {
    var self = @ptrCast(*soundio.Outstream, @alignCast(@alignOf(*soundio.Outstream), self_any));
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

test "wait events" {
    if (true) return error.SkipZigTest;
    var a = try soundio.connect(null, std.testing.allocator, .{});
    defer a.deinit();
    var wait: u2 = 2;
    while (wait > 0) : (wait -= 1)
        try a.waitEvents();
}

test "init deinit" {
    var a = try soundio.connect(null, std.testing.allocator, .{});
    // TODO
    // try a.flushEvents();
    // const ad = a.getDevice(.output, null);
    // var ao = try a.createOutstream(ad, .{ .writeFn = undefined });
    // defer ao.deinit();
    a.deinit();

    var b = try soundio.connect(null, std.testing.allocator, .{});
    b.deinit();

    var c = try soundio.connect(null, std.testing.allocator, .{});
    c.deinit();
}
