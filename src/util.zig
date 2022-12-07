const std = @import("std");
const main = @import("main.zig");
const testing = std.testing;

pub const DevicesInfo = struct {
    list: std.ArrayListUnmanaged(main.Device),
    default_output: ?usize,
    default_input: ?usize,

    pub fn init() DevicesInfo {
        return .{
            .list = .{},
            .default_output = null,
            .default_input = null,
        };
    }

    pub fn clear(self: *DevicesInfo, allocator: std.mem.Allocator) void {
        self.default_output = null;
        self.default_input = null;
        self.list.clearAndFree(allocator);
    }

    pub fn get(self: DevicesInfo, i: usize) main.Device {
        return self.list.items[i];
    }

    pub fn default(self: DevicesInfo, aim: main.Device.Mode) ?main.Device {
        return self.get(self.defaultIndex(aim) orelse return null);
    }

    pub fn setDefault(self: *DevicesInfo, aim: main.Device.Mode, i: usize) void {
        switch (aim) {
            .playback => self.default_output = i,
            .capture => self.default_input = i,
        }
    }

    pub fn defaultIndex(self: DevicesInfo, aim: main.Device.Mode) ?usize {
        return switch (aim) {
            .playback => self.default_output,
            .capture => self.default_input,
        };
    }
};

pub fn Range(comptime T: type) type {
    return struct {
        const Self = @This();

        min: T,
        max: T,

        pub fn clamp(self: Self, val: T) T {
            return std.math.clamp(val, self.min, self.max);
        }
    };
}

pub fn doNothing() callconv(.C) void {}
