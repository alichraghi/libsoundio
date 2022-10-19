const std = @import("std");
const soundio = @import("soundio");

test "flush events" {
    var a = try soundio.connect(std.testing.allocator);
    defer a.deinit();
    try a.flushEvents();
    try std.testing.expect(a.devicesList(.output).len > 0);
}

test "wait events" {
    var a = try soundio.connect(std.testing.allocator);
    defer a.deinit();
    var wait: u2 = 2;
    while (wait > 0) : (wait -= 1) {
        try a.waitEvents();
    }
}
