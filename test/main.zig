const std = @import("std");
const soundio = @import("soundio");

test "Alsa connect()" {
    var a = try soundio.connect(.Alsa, std.testing.allocator, .{});
    defer a.deinit();
    try a.flushEvents();
    try std.testing.expect(a.devicesList().len > 0);

    std.debug.print("Alsa default: {s}\n", .{a.getDevice(.output, null).?.id});
}

test "PulseAudio connect()" {
    var a = try soundio.connect(.PulseAudio, std.testing.allocator, .{});
    defer a.deinit();
    try a.flushEvents();
    try std.testing.expect(a.devicesList().len > 0);

    std.debug.print("PulseAudio: {d}\n", .{a.devicesList().len});
}

test "Jack connect()" {
    if (true) return error.SkipZigTest;

    var a = try soundio.connect(.Jack, std.testing.allocator, .{ .shutdownFn = shutdownFn });
    defer a.deinit();
    try a.flushEvents();
    try std.testing.expect(a.devicesList().len > 0);
}

fn shutdownFn(_: ?*anyopaque) void {
    std.os.exit(1);
}

test "PulseAudio waitEvents()" {
    var a = try soundio.connect(.PulseAudio, std.testing.allocator, .{});
    defer a.deinit();
    var wait: u4 = 0;
    while (wait < 4) : (wait += 1) {
        a.wakeUp();
        try a.waitEvents();
    }
}

test "Alsa waitEvents()" {
    var a = try soundio.connect(.Alsa, std.testing.allocator, .{});
    defer a.deinit();
    var wait: u4 = 0;
    while (wait < 4) : (wait += 1) {
        a.wakeUp();
        try a.waitEvents();
    }
}

test "PulseAudio SineWave" {
    var a = try soundio.connect(.PulseAudio, std.testing.allocator, .{});
    defer a.deinit();
    try a.flushEvents();
    const device = a.getDevice(.output, null) orelse return error.OhNo;
    var o = try a.createOutstream(device, .{ .writeFn = writeCallback });
    defer o.deinit();
    try o.start();

    try o.setVolume(1.0);
    std.time.sleep(std.time.ns_per_ms * 100);
    // var v: f64 = 0.7;
    // while (v > 0.15) : (v -= 0.0005) {
    //     try o.setVolume(v);
    //     std.time.sleep(std.time.ns_per_ms * 5);
    // }
    // const volume = try o.volume();
    // try std.testing.expect(volume > 0.1499 and volume <= 0.15);
}

const pi_mul = 2.0 * std.math.pi;
var accumulator: f32 = 0;
fn writeCallback(self_opaque: *anyopaque, areas: []const soundio.ChannelArea, n_frame: usize) void {
    const self = @ptrCast(*soundio.Outstream, @alignCast(@alignOf(*soundio.Outstream), self_opaque));
    var i: usize = 0;
    while (i < n_frame) : (i += 1) {
        accumulator += pi_mul * 440.0 / @intToFloat(f32, self.sample_rate);
        if (accumulator >= pi_mul) accumulator -= pi_mul;
        for (areas) |area|
            area.write(std.math.sin(accumulator), i);
    }
}
