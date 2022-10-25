const std = @import("std");

pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        const Size = u32; // 0-8195
        const size = 32000;
        buf: [size]T,
        capacity: Size = 0,
        read_off: Size = 0,
        write_off: Size = 0,

        pub fn init(capacity: Size) Self {
            return .{
                .buf = undefined,
                .capacity = capacity,
                .read_off = 0,
                .write_off = 0,
            };
        }

        pub fn writePtr(self: *Self) [*]T {
            return self.buf[self.write_off % self.capacity ..].ptr;
        }

        pub fn advanceWritePtr(self: *Self, count: Size) void {
            self.write_off += count;
            std.debug.assert(self.fillCount() > 0);
        }

        pub fn readPtr(self: *Self) [*]T {
            return self.buf[self.read_off % self.capacity ..].ptr;
        }

        pub fn advanceReadPtr(self: *Self, count: Size) void {
            self.read_off += count;
            std.debug.assert(self.fillCount() > 0);
        }

        pub fn fillCount(self: *Self) Size {
            const count = self.write_off - self.read_off;
            std.debug.assert(count > 0);
            std.debug.assert(count <= self.capacity);
            return count;
        }

        pub fn freeCount(self: *Self) Size {
            return self.capacity - self.fillCount();
        }

        pub fn clear(self: *Self) void {
            self.write_off = self.read_off;
        }
    };
}
