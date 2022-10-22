const std = @import("std");
const soundio = @import("soundio");

test "flush events" {
    var a = try soundio.connect(std.testing.allocator);
    defer a.deinit();
    try a.flushEvents();
    try std.testing.expect(a.devicesList(.output).len > 0);
}

test "sine wave" {
    var a = try soundio.connect(std.testing.allocator);
    defer a.deinit();
    try a.flushEvents();
    const device = a.getDevice(.output, null);
    var o = try a.createOutstream(device, .{ .writeFn = writeCallback });
    defer o.deinit();
    try o.start();

    std.time.sleep(std.time.ns_per_ms * 200);
    try o.pause();
    std.time.sleep(std.time.ns_per_ms * 200);
    try o.play();
}

var seconds_offset: f32 = 0;
fn writeCallback(self_any: *anyopaque, _: usize, frame_count_max: usize) anyerror!void {
    var self = @ptrCast(*soundio.Outstream, @alignCast(@alignOf(*soundio.Outstream), self_any));
    const seconds_per_frame = 1.0 / @intToFloat(f32, self.sample_rate);
    const pitch = 440.0;
    const radians_per_second = pitch * 2.0 * std.math.pi;
    var frames_left = frame_count_max;

    while (frames_left > 0) {
        var fpb = frames_left; // frames per buffer
        const areas = try self.beginWrite(&fpb);
        for (@as([*]void, undefined)[0..fpb]) |_, i| {
            const sample = std.math.sin((seconds_offset + seconds_per_frame * @intToFloat(f32, i)) * radians_per_second);
            for (areas) |area|
                area.write(sample, i);
        }
        seconds_offset += seconds_per_frame * @intToFloat(f32, fpb);
        try self.endWrite();
        frames_left -= fpb;
    }
}

test "wait events" {
    if (true) return error.SkipZigTest;
    var a = try soundio.connect(std.testing.allocator);
    defer a.deinit();
    var wait: u2 = 2;
    while (wait > 0) : (wait -= 1) {
        try a.waitEvents();
    }
}
