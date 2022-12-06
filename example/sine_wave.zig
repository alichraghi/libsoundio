const std = @import("std");
const SysAudio = @import("sysaudio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var a = try SysAudio.connect(.Dummy, allocator, .{ .deviceChangeFn = deviceChange });
    defer a.disconnect();
    try a.refresh();
    const device = a.defaultDevice(.playback) orelse return error.NoDevice;

    var p = try a.createPlayer(device, writeCallback, .{});
    defer p.deinit();
    try p.start();

    try p.setVolume(1.0);
    // try a.wait();
    // while (true) {}
    std.time.sleep(1 * std.time.ns_per_s);
}

const pitch = 440.0;
const radians_per_second = pitch * 2.0 * std.math.pi;
var seconds_offset: f32 = 0.0;
fn writeCallback(self_opaque: *const anyopaque, n_frame: usize) void {
    var self = @ptrCast(*const SysAudio.Player, @alignCast(@alignOf(SysAudio.Player), self_opaque));

    const seconds_per_frame = 1.0 / @intToFloat(f32, self.sample_rate);
    var frame: usize = 0;
    while (frame < n_frame) : (frame += 1) {
        const sample = std.math.sin((seconds_offset + @intToFloat(f32, frame) * seconds_per_frame) * radians_per_second);
        self.writeAll(frame, sample);
    }
    seconds_offset = @mod(seconds_offset + seconds_per_frame * @intToFloat(f32, n_frame), 1.0);
}

fn deviceChange(self: ?*anyopaque) void {
    _ = self;
    std.debug.print("Device change detected!\n", .{});
}
