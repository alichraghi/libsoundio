const std = @import("std");
const backends = @import("backends.zig");
const Device = @import("main.zig").Device;
const Format = @import("main.zig").Format;

pub const Player = struct {
    // TODO: `Player` instead `* anyopaque`
    // https://github.com/ziglang/zig/issues/12325
    pub const WriteFn = *const fn (self: *const anyopaque, frame_count_max: usize) void;

    writeFn: WriteFn,
    userdata: ?*anyopaque,
    device: Device,
    format: Format,
    /// samples per second
    sample_rate: u32,

    data: BackendData(),

    pub fn BackendData() type {
        var fields: [std.meta.fields(backends.BackendData).len]std.builtin.Type.UnionField = undefined;
        for (std.meta.fields(backends.BackendData)) |b, i| {
            fields[i] = std.builtin.Type.UnionField{
                .name = b.name,
                .field_type = @typeInfo(b.field_type).Pointer.child.Player,
                .alignment = @alignOf(@typeInfo(b.field_type).Pointer.child.Player),
            };
        }
        return @Type(.{ .Union = .{
            .layout = .Auto,
            .tag_type = backends.Backend,
            .fields = &fields,
            .decls = &.{},
        } });
    }

    pub fn deinit(self: *Player) void {
        return switch (self.data) {
            inline else => |*b| b.deinit(),
        };
    }

    pub const StartError = error{
        CannotPlay,
        OutOfMemory,
        SystemResources,
    };

    pub fn start(self: *Player) StartError!void {
        return switch (self.data) {
            inline else => |*b| b.start(),
        };
    }

    pub const PlayError = error{
        CannotPlay,
    };

    pub fn play(self: *Player) PlayError!void {
        return switch (self.data) {
            inline else => |*b| b.play(),
        };
    }

    pub const PauseError = error{
        CannotPause,
    };

    pub fn pause(self: *Player) PauseError!void {
        return switch (self.data) {
            inline else => |*b| b.pause(),
        };
    }

    pub fn paused(self: *Player) bool {
        return switch (self.data) {
            inline else => |*b| b.paused(),
        };
    }

    pub const SetVolumeError = error{
        CannotSetVolume,
    };

    // confidence interval (±) depends on the device
    pub fn setVolume(self: *Player, vol: f32) SetVolumeError!void {
        std.debug.assert(vol <= 1.0);
        return switch (self.data) {
            inline else => |*b| b.setVolume(vol),
        };
    }

    pub const GetVolumeError = error{
        CannotGetVolume,
    };

    // confidence interval (±) depends on the device
    pub fn volume(self: *Player) GetVolumeError!f32 {
        return switch (self.data) {
            inline else => |*b| b.volume(),
        };
    }

    pub fn bytesPerFrame(self: Player) u8 {
        return self.format.bytesPerFrame(@intCast(u5, self.device.channels.len));
    }

    pub fn bytesPerSample(self: Player) u4 {
        return self.format.bytesPerSample();
    }

    pub fn writeAll(self: Player, frame: usize, value: anytype) void {
        for (self.device.channels) |_, i|
            self.write(i, frame, value);
    }

    pub fn write(self: Player, channel: usize, frame: usize, sample: anytype) void {
        switch (@TypeOf(sample)) {
            u8 => self.writeU8(channel, frame, sample),
            i16 => self.writeI16(channel, frame, sample),
            i24 => self.writeI24(channel, frame, sample),
            i32 => self.writeI32(channel, frame, sample),
            f32 => self.writeF32(channel, frame, sample),
            f64 => self.writeF64(channel, frame, sample),
            else => @compileError(
                \\invalid sample type. supported types are:
                \\u8, i8, i16, i24, i32, f32, f32, f64
            ),
        }
    }

    pub inline fn writeRaw(self: Player, channel: usize, frame: usize, sample: anytype) void {
        var ptr = self.device.channels[channel].ptr + self.bytesPerFrame() * frame;
        std.mem.bytesAsValue(@TypeOf(sample), ptr[0..@sizeOf(@TypeOf(sample))]).* = sample;
    }

    pub fn writeU8(self: Player, channel: usize, frame: usize, sample: u8) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, sample),
            .i8 => self.writeRaw(channel, frame, unsignedToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, unsignedToSigned(i16, sample)),
            .i24 => self.writeRaw(channel, frame, unsignedToSigned(i24, sample)),
            .i24_4b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, unsignedToSigned(i32, sample)),
            .f32 => self.writeRaw(channel, frame, unsignedToFloat(f32, sample)),
            .f64 => self.writeRaw(channel, frame, unsignedToFloat(f64, sample)),
        }
    }

    fn unsignedToSigned(comptime T: type, sample: anytype) T {
        const half = 1 << (@bitSizeOf(@TypeOf(sample)) - 1);
        const trunc = @bitSizeOf(T) - @bitSizeOf(@TypeOf(sample));
        return @intCast(T, sample -% half) << trunc;
    }

    fn unsignedToFloat(comptime T: type, sample: anytype) T {
        const max_int = std.math.maxInt(@TypeOf(sample)) + 1.0;
        return (@intToFloat(T, sample) - max_int) * 1.0 / max_int;
    }

    pub fn writeI16(self: Player, channel: usize, frame: usize, sample: i16) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, signedToUnsigned(u8, sample)),
            .i8 => self.writeRaw(channel, frame, signedToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, sample),
            .i24 => self.writeRaw(channel, frame, sample),
            .i24_4b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, sample),
            .f32 => self.writeRaw(channel, frame, signedToFloat(f32, sample)),
            .f64 => self.writeRaw(channel, frame, signedToFloat(f64, sample)),
        }
    }

    pub fn writeI24(self: Player, channel: usize, frame: usize, sample: i24) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, signedToUnsigned(u8, sample)),
            .i8 => self.writeRaw(channel, frame, signedToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, signedToSigned(i16, sample)),
            .i24 => self.writeRaw(channel, frame, sample),
            .i24_4b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, sample),
            .f32 => self.writeRaw(channel, frame, signedToFloat(f32, sample)),
            .f64 => self.writeRaw(channel, frame, signedToFloat(f64, sample)),
        }
    }

    pub fn writeI32(self: Player, channel: usize, frame: usize, sample: i32) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, signedToUnsigned(u8, sample)),
            .i8 => self.writeRaw(channel, frame, signedToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, signedToSigned(i16, sample)),
            .i24 => self.writeRaw(channel, frame, signedToSigned(i24, sample)),
            .i24_4b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, sample),
            .f32 => self.writeRaw(channel, frame, signedToFloat(f32, sample)),
            .f64 => self.writeRaw(channel, frame, signedToFloat(f64, sample)),
        }
    }

    fn signedToSigned(comptime T: type, sample: anytype) T {
        const trunc = @bitSizeOf(@TypeOf(sample)) - @bitSizeOf(T);
        return @intCast(T, sample >> trunc);
    }

    fn signedToUnsigned(comptime T: type, sample: anytype) T {
        const half = 1 << (@bitSizeOf(T) - 1);
        const trunc = @bitSizeOf(@TypeOf(sample)) - @bitSizeOf(T);
        return @intCast(T, (sample >> trunc) + half);
    }

    fn signedToFloat(comptime T: type, sample: anytype) T {
        const max_int = std.math.maxInt(@TypeOf(sample)) + 1.0;
        return @intToFloat(T, sample) * 1.0 / max_int;
    }

    pub fn writeF32(self: Player, channel: usize, frame: usize, sample: f32) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, floatToUnsigned(u8, sample)),
            .i8 => self.writeRaw(channel, frame, floatToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, floatToSigned(i16, sample)),
            .i24 => self.writeRaw(channel, frame, floatToSigned(i24, sample)),
            .i24_4b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, floatToSigned(i32, sample)),
            .f32 => self.writeRaw(channel, frame, sample),
            .f64 => self.writeRaw(channel, frame, sample),
        }
    }

    pub fn writeF64(self: Player, channel: usize, frame: usize, sample: f64) void {
        switch (self.format) {
            .u8 => self.writeRaw(channel, frame, floatToUnsigned(u8, sample)),
            .i8 => self.writeRaw(channel, frame, floatToSigned(i8, sample)),
            .i16 => self.writeRaw(channel, frame, floatToSigned(i16, sample)),
            .i24 => self.writeRaw(channel, frame, floatToSigned(i24, sample)),
            .i24_4b => @panic("TODO"),
            .i32 => self.writeRaw(channel, frame, floatToSigned(i32, sample)),
            .f32 => self.writeRaw(channel, frame, sample),
            .f64 => self.writeRaw(channel, frame, sample),
        }
    }

    fn floatToSigned(comptime T: type, sample: f64) T {
        return @floatToInt(T, sample * std.math.maxInt(T));
    }

    fn floatToUnsigned(comptime T: type, sample: f64) T {
        const half = 1 << @bitSizeOf(T) - 1;
        return @floatToInt(T, sample * (half - 1) + half);
    }

    // TODO: must be tested
    // fn f32Toi24_4b(sample: f32) i32 {
    //     const scaled = sample *  std.math.maxInt(i32);
    //     if (builtin.cpu.arch.endian() == .Little) {
    //         return @floatToInt(i32, scaled);
    //     } else {
    //         var res: [4]u8 = undefined;
    //         std.mem.writeIntSliceBig(i32, &res, @floatToInt(i32, res));
    //         return @bitCast(i32, res);
    //     }
    // }
};
