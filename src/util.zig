const std = @import("std");
const testing = std.testing;

pub fn hasFlag(int: anytype, flags: @TypeOf(int)) bool {
    return if (int & flags == flags)
        true
    else
        false;
}

test "hasFlag()" {
    const bits = 0b00100001;
    try testing.expect(hasFlag(bits, 0b00100000));
}
