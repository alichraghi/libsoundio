const std = @import("std");

// test {
//     var x: [1024]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
//     _ = @ptrCast(*std.os.linux.inotify_event, x[0..@sizeOf(std.os.linux.inotify_event)]);
// }
const backends = @import("backends.zig");

pub const SoundIO = struct {
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SoundIO {
        return .{
            .lock = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    pub fn connect(self: SoundIO, backend: ?backends.Backend) !void {
        if (backend) |b| {
            _ = try @field(backends, std.meta.tagName(b)).connect(self.allocator);
        } else {
            inline for (std.meta.fields(backends.Backend)) |f| {
                if (try @field(backends, f.name).connect(self.allocator)) {
                    break;
                } else |_| {}
            }
        }
    }
};

test {
    std.testing.refAllDeclsRecursive(@This());
    var s = SoundIO.init(std.testing.allocator);
    try s.connect(null);
}
