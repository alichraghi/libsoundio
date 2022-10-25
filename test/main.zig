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

    var v: f64 = 1.0;
    while (v > 0.3) : (v -= 0.001) {
        try o.setVolume(v);
        std.time.sleep(std.time.ns_per_ms * 5);
    }
    const volume = try o.volume();
    try std.testing.expect(volume >= 0.3 and volume < 0.31);
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

var rb: soundio.RingBuffer(f32) = undefined;

fn readCallback(self_any: *anyopaque, frame_count_min: usize, frame_count_max: usize) anyerror!void {
    var self = @ptrCast(*soundio.Instream, @alignCast(@alignOf(*soundio.Instream), self_any));

    var write_ptr = rb.writePtr();
    const free_bytes = rb.freeCount();
    const free_count = free_bytes / self.bytes_per_frame;
    if (frame_count_min > free_count)
        @panic("ring buffer overflow");

    const write_frames = std.math.min(free_count, frame_count_max);
    var frames_left: usize = write_frames;

    while (true) {
        var fpb: usize = frames_left; // frames per buffer
        const areas_or_null = try self.beginRead(&fpb);
        if (fpb == 0) break;
        if (areas_or_null) |areas| {
            for (@as([*]void, undefined)[0..fpb]) |_, i| {
                for (areas) |area| {
                    write_ptr[0] = area.read(f32, i);
                    rb.advanceWritePtr(1);
                }
            }
        } else {
            // Due to an overflow there is a hole. Fill the ring buffer with
            // silence for the size of the hole.
            std.mem.set(f32, write_ptr[0..fpb], 0);
            // fprintf(stderr, "Dropped %d frames due to internal overflow\n", frame_count);
        }
        try self.endRead();
        frames_left -= fpb;
        if (fpb == 0) break;
    }
}

fn writeCallback2(self_any: *anyopaque, frame_count_min: usize, frame_count_max: usize) anyerror!void {
    var self = @ptrCast(*soundio.Outstream, @alignCast(@alignOf(*soundio.Outstream), self_any));
    var frames_left = frame_count_max;

    var read_ptr = rb.readPtr();
    const fill_bytes = rb.fillCount();
    const fill_count = fill_bytes / self.bytes_per_frame;

    if (frame_count_min > fill_count) {
        // Ring buffer does not have enough data, fill with zeroes.
        frames_left = frame_count_min;

        while (true) {
            var fpb = frames_left; // frames per buffer
            if (fpb == 0) break;
            const areas = try self.beginWrite(&fpb);
            if (fpb == 0) break;
            for (@as([*]void, undefined)[0..fpb]) |_, i| {
                for (areas) |area| {
                    area.write(@as(f32, 0.0), i);
                }
            }
            try self.endWrite();
            frames_left -= fpb;
        }
    }

    const read_count = std.math.min(frame_count_max, fill_count);
    frames_left = read_count;

    while (frames_left > 0) {
        var fpb = frames_left; // frames per buffer
        const areas = try self.beginWrite(&fpb);
        if (fpb == 0) break;
        for (@as([*]void, undefined)[0..fpb]) |_, i| {
            for (areas) |area| {
                area.write(@ptrCast(*f32, @alignCast(@alignOf(*f32), read_ptr)).*, i);
                rb.advanceReadPtr(1);
            }
        }
        try self.endWrite();
        frames_left -= fpb;
    }
}

test "microphone" {
    if (true) return error.SkipZigTest;
    const ml = 0.2;
    var a = try soundio.connect(std.testing.allocator);
    defer a.deinit();
    try a.flushEvents();
    const in_device = a.getDevice(.input, 0);
    const out_device = a.getDevice(.output, null);
    var out = try a.createOutstream(out_device, .{ .writeFn = writeCallback2 });
    var in = try a.createInstream(in_device, .{ .readFn = readCallback });
    const cap = @floatToInt(u32, ml * 2 * @intToFloat(f32, in.sample_rate));
    rb = soundio.RingBuffer(f32).init(cap);
    const fill_count = @floatToInt(u32, ml * @intToFloat(f32, out.sample_rate));
    var buf = rb.writePtr();
    std.mem.set(f32, buf[0..fill_count], 0);
    rb.advanceWritePtr(fill_count);
    try in.start();
    try out.start();
    std.time.sleep(std.time.ns_per_s * 5);
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
