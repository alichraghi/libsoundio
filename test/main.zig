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
    try o.start();

    std.time.sleep(std.time.ns_per_ms * 500);
}

fn writeCallback(self: *soundio.Outstream, _: usize, frame_count_max: usize) anyerror!void {
    const seconds_per_frame = 1.0 / @intToFloat(f32, self.sample_rate);
    var frames_left = frame_count_max;
    var seconds_offset: f32 = 0;

    while (frames_left > 0) {
        var frame_count = frames_left;

        const areas = self.beginWrite(&frame_count) catch |err|
            std.debug.panic("write failed: {s}", .{@errorName(err)});

        const pitch = 440.0;
        const radians_per_second = pitch * 2.0 * std.math.pi;
        var frame: u32 = 0;
        while (frame < frame_count) : (frame += 1) {
            const sample = std.math.sin(
                (seconds_offset + @intToFloat(f32, frame) * seconds_per_frame) *
                    radians_per_second,
            );
            for (self.layout.channels.constSlice()) |_, channel| {
                const channel_ptr = areas[channel].ptr;
                @ptrCast(
                    *f32,
                    @alignCast(@alignOf(f32), &channel_ptr[areas[channel].step * frame]),
                ).* = sample;
            }
        }
        seconds_offset += seconds_per_frame * @intToFloat(f32, frame_count);
        self.endWrite() catch |err| std.debug.panic("end write failed: {s}", .{@errorName(err)});
        frames_left -= frame_count;
    }
}

// fn writeCallback(self: *soundio.Outstream, _: usize, frame_count_max: usize) anyerror!void {
//     var frame_iter = self.createFrameIterator();
//     const seconds_per_frame = 1.0 / @intToFloat(f32, self.sample_rate);
//     var frames_left = frame_count_max;
//     var seconds_offset: f32 = 0;

//     while (frame_iter.next()) |frame| {
//         const pitch = 440.0;
//         const radians_per_second = pitch * 2.0 * std.math.pi;
//         var frame: u32 = 0;
//         while (frame < frame_count) : (frame += 1) {
//             const sample = std.math.sin(
//                 (seconds_offset + @intToFloat(f32, frame) * seconds_per_frame) *
//                     radians_per_second,
//             );
//             {
//                 for (self.layout.channels.constSlice()) |_, channel| {
//                     const channel_ptr = areas[channel].ptr;
//                     @ptrCast(
//                         *f32,
//                         @alignCast(@alignOf(f32), &channel_ptr[areas[channel].step * frame]),
//                     ).* = sample;
//                 }
//             }
//         }
//         seconds_offset += seconds_per_frame * @intToFloat(f32, frame_count);
//         self.endWrite() catch |err| std.debug.panic("end write failed: {s}", .{@errorName(err)});
//         frames_left -= frame_count;
//     }
// }

test "wait events" {
    if (true) return error.SkipZigTest;
    var a = try soundio.connect(std.testing.allocator);
    defer a.deinit();
    var wait: u2 = 2;
    while (wait > 0) : (wait -= 1) {
        try a.waitEvents();
    }
}
