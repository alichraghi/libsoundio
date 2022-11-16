const std = @import("std");
const soundio = @import("soundio");

test "Alsa connect()" {
    var a = try soundio.connect(.Alsa, std.testing.allocator, .{});
    defer a.deinit();
    try a.flushEvents();
    try std.testing.expect(a.devicesList().len > 0);
}

test "PulseAudio connect()" {
    var a = try soundio.connect(.PulseAudio, std.testing.allocator, .{});
    defer a.deinit();
    try a.flushEvents();
    try std.testing.expect(a.devicesList().len > 0);
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

test "Alsa SineWave" {
    var a = try soundio.connect(.Alsa, std.testing.allocator, .{});
    defer a.deinit();
    try a.flushEvents();
    const device = a.getDevice(.playback, null) orelse return error.SkipZigTest;
    var p = try a.createPlayer(device, .{ .writeFn = writeCallback });
    defer p.deinit();
    try p.start();

    try p.setVolume(1.0);
    std.time.sleep(std.time.ns_per_ms * 3000);
    // var v: f64 = 0.7;
    // while (v > 0.15) : (v -= 0.0005) {
    //     try o.setVolume(v);
    //     std.time.sleep(std.time.ns_per_ms * 5);
    // }
    // const volume = try o.volume();
    // try std.testing.expect(volume > 0.1499 and volume <= 0.15);
}

test "PulseAudio SineWave" {
    var a = try soundio.connect(.PulseAudio, std.testing.allocator, .{});
    defer a.deinit();
    try a.flushEvents();
    const device = a.getDevice(.playback, null) orelse return error.SkipZigTest;
    var p = try a.createPlayer(device, .{ .writeFn = writeCallback });
    defer p.deinit();
    try p.start();

    try p.setVolume(1.0);
    std.time.sleep(std.time.ns_per_ms * 3000);
    // var v: f64 = 0.7;
    // while (v > 0.15) : (v -= 0.0005) {
    //     try o.setVolume(v);
    //     std.time.sleep(std.time.ns_per_ms * 5);
    // }
    // const volume = try o.volume();
    // try std.testing.expect(volume > 0.1499 and volume <= 0.15);
}

const pitch = 440.0;
const radians_per_second = pitch * 2.0 * std.math.pi;
var seconds_offset: f32 = 0.0;
fn writeCallback(self_opaque: *anyopaque, err: soundio.Player.WriteError!void, areas: []const soundio.ChannelArea, n_frame: usize) void {
    err catch unreachable;
    const self = @ptrCast(*const soundio.Player, @alignCast(@alignOf(soundio.Player), self_opaque));
    // _ = self_opaque;
    // var r = std.rand.DefaultPrng.init(@intCast(u64, std.time.timestamp()));
    // var frame: usize = 0;
    // while (frame < n_frame) : (frame += 1) {
    //     const sample: f32 = 4.0 * r.random().float(f32);
    //     for (areas) |area| {
    //         area.write(sample, frame);
    //     }
    // }

    const seconds_per_frame = 1.0 / @intToFloat(f32, self.sample_rate);
    var frame: usize = 0;
    while (frame < n_frame) : (frame += 1) {
        const sample = std.math.sin((seconds_offset + @intToFloat(f32, frame) * seconds_per_frame) * radians_per_second);
        for (areas) |area| {
            area.write(sample, frame);
        }
    }
    seconds_offset = @mod(seconds_offset + seconds_per_frame * @intToFloat(f32, n_frame), 1.0);
}
