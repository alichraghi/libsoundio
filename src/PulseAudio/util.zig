const c = @import("c.zig");
const ChannelArray = @import("../main.zig").ChannelArray;
const ChannelId = @import("../main.zig").ChannelId;
const Format = @import("../main.zig").Format;

const is_little = @import("builtin").cpu.arch.endian() == .Little;

pub const supported_formats = &[_]Format{
    .u8,  .i16,
    .i24, .i24_3b,
    .i32, .f32,
};

pub fn fromPAChannelMap(map: c.pa_channel_map) !ChannelArray {
    var channels = try ChannelArray.init(map.channels);
    for (channels.slice()) |*ch, i|
        ch.*.id = fromPAChannelPos(map.map[i]);
    return channels;
}

fn fromPAChannelPos(pos: c.pa_channel_position_t) ChannelId {
    return switch (pos) {
        c.PA_CHANNEL_POSITION_MONO => .front_center,
        c.PA_CHANNEL_POSITION_FRONT_LEFT => .front_left, // PA_CHANNEL_POSITION_LEFT
        c.PA_CHANNEL_POSITION_FRONT_RIGHT => .front_right, // PA_CHANNEL_POSITION_RIGHT
        c.PA_CHANNEL_POSITION_FRONT_CENTER => .front_center, // PA_CHANNEL_POSITION_CENTER
        c.PA_CHANNEL_POSITION_REAR_CENTER => .back_center,
        c.PA_CHANNEL_POSITION_REAR_LEFT => .back_left,
        c.PA_CHANNEL_POSITION_REAR_RIGHT => .back_right,
        c.PA_CHANNEL_POSITION_LFE => .lfe, // PA_CHANNEL_POSITION_SUBWOOFER
        c.PA_CHANNEL_POSITION_FRONT_LEFT_OF_CENTER => .front_left_center,
        c.PA_CHANNEL_POSITION_FRONT_RIGHT_OF_CENTER => .front_right_center,
        c.PA_CHANNEL_POSITION_SIDE_LEFT => .side_left,
        c.PA_CHANNEL_POSITION_SIDE_RIGHT => .side_right,

        c.PA_CHANNEL_POSITION_AUX0 => .aux0,
        c.PA_CHANNEL_POSITION_AUX1 => .aux1,
        c.PA_CHANNEL_POSITION_AUX2 => .aux2,
        c.PA_CHANNEL_POSITION_AUX3 => .aux3,
        c.PA_CHANNEL_POSITION_AUX4 => .aux4,
        c.PA_CHANNEL_POSITION_AUX5 => .aux5,
        c.PA_CHANNEL_POSITION_AUX6 => .aux6,
        c.PA_CHANNEL_POSITION_AUX7 => .aux7,
        c.PA_CHANNEL_POSITION_AUX8 => .aux8,
        c.PA_CHANNEL_POSITION_AUX9 => .aux9,
        c.PA_CHANNEL_POSITION_AUX10 => .aux10,
        c.PA_CHANNEL_POSITION_AUX11 => .aux11,
        c.PA_CHANNEL_POSITION_AUX12 => .aux12,
        c.PA_CHANNEL_POSITION_AUX13 => .aux13,
        c.PA_CHANNEL_POSITION_AUX14 => .aux14,
        c.PA_CHANNEL_POSITION_AUX15 => .aux15,

        // let's keep this unreachable for now, since i don't see why someone should use > 15 AUX
        c.PA_CHANNEL_POSITION_AUX16,
        c.PA_CHANNEL_POSITION_AUX17,
        c.PA_CHANNEL_POSITION_AUX18,
        c.PA_CHANNEL_POSITION_AUX19,
        c.PA_CHANNEL_POSITION_AUX20,
        c.PA_CHANNEL_POSITION_AUX21,
        c.PA_CHANNEL_POSITION_AUX22,
        c.PA_CHANNEL_POSITION_AUX23,
        c.PA_CHANNEL_POSITION_AUX24,
        c.PA_CHANNEL_POSITION_AUX25,
        c.PA_CHANNEL_POSITION_AUX26,
        c.PA_CHANNEL_POSITION_AUX27,
        c.PA_CHANNEL_POSITION_AUX28,
        c.PA_CHANNEL_POSITION_AUX29,
        c.PA_CHANNEL_POSITION_AUX30,
        c.PA_CHANNEL_POSITION_AUX31,
        => unreachable,

        c.PA_CHANNEL_POSITION_TOP_CENTER => .top_center,
        c.PA_CHANNEL_POSITION_TOP_FRONT_LEFT => .top_front_left,
        c.PA_CHANNEL_POSITION_TOP_FRONT_RIGHT => .top_front_right,
        c.PA_CHANNEL_POSITION_TOP_FRONT_CENTER => .top_front_center,
        c.PA_CHANNEL_POSITION_TOP_REAR_LEFT => .top_back_left,
        c.PA_CHANNEL_POSITION_TOP_REAR_RIGHT => .top_back_right,
        c.PA_CHANNEL_POSITION_TOP_REAR_CENTER => .top_back_center,

        else => unreachable,
    };
}

pub fn toPAFormat(format: Format) !c.pa_sample_format_t {
    return switch (format) {
        .u8 => c.PA_SAMPLE_U8,
        .i16 => if (is_little) c.PA_SAMPLE_S16LE else c.PA_SAMPLE_S16BE,
        .i24 => if (is_little) c.PA_SAMPLE_S24LE else c.PA_SAMPLE_S24LE,
        .i24_3b => if (is_little) c.PA_SAMPLE_S24_32LE else c.PA_SAMPLE_S24_32BE,
        .i32 => if (is_little) c.PA_SAMPLE_S32LE else c.PA_SAMPLE_S32BE,
        .f32 => if (is_little) c.PA_SAMPLE_FLOAT32LE else c.PA_SAMPLE_FLOAT32BE,

        .i8,
        .u16,
        .u24,
        .u24_3b,
        .u32,
        .f64,
        => error.IncompatibleBackend,
    };
}

pub fn toPAChannelMap(channels: ChannelArray) !c.pa_channel_map {
    var channel_map: c.pa_channel_map = undefined;
    channel_map.channels = @intCast(u5, channels.len);
    for (channels.slice()) |ch, i|
        channel_map.map[i] = try toPAChannelPos(ch.id);
    return channel_map;
}

fn toPAChannelPos(channel_id: ChannelId) !c.pa_channel_position_t {
    return switch (channel_id) {
        .front_left => c.PA_CHANNEL_POSITION_FRONT_LEFT,
        .front_right => c.PA_CHANNEL_POSITION_FRONT_RIGHT,
        .front_center => c.PA_CHANNEL_POSITION_FRONT_CENTER,
        .lfe => c.PA_CHANNEL_POSITION_LFE,
        .back_left => c.PA_CHANNEL_POSITION_REAR_LEFT,
        .back_right => c.PA_CHANNEL_POSITION_REAR_RIGHT,
        .front_left_center => c.PA_CHANNEL_POSITION_FRONT_LEFT_OF_CENTER,
        .front_right_center => c.PA_CHANNEL_POSITION_FRONT_RIGHT_OF_CENTER,
        .back_center => c.PA_CHANNEL_POSITION_REAR_CENTER,
        .side_left => c.PA_CHANNEL_POSITION_SIDE_LEFT,
        .side_right => c.PA_CHANNEL_POSITION_SIDE_RIGHT,
        .top_center => c.PA_CHANNEL_POSITION_TOP_CENTER,
        .top_front_left => c.PA_CHANNEL_POSITION_TOP_FRONT_LEFT,
        .top_front_center => c.PA_CHANNEL_POSITION_TOP_FRONT_CENTER,
        .top_front_right => c.PA_CHANNEL_POSITION_TOP_FRONT_RIGHT,
        .top_back_left => c.PA_CHANNEL_POSITION_TOP_REAR_LEFT,
        .top_back_center => c.PA_CHANNEL_POSITION_TOP_REAR_CENTER,
        .top_back_right => c.PA_CHANNEL_POSITION_TOP_REAR_RIGHT,

        .aux0 => c.PA_CHANNEL_POSITION_AUX0,
        .aux1 => c.PA_CHANNEL_POSITION_AUX1,
        .aux2 => c.PA_CHANNEL_POSITION_AUX2,
        .aux3 => c.PA_CHANNEL_POSITION_AUX3,
        .aux4 => c.PA_CHANNEL_POSITION_AUX4,
        .aux5 => c.PA_CHANNEL_POSITION_AUX5,
        .aux6 => c.PA_CHANNEL_POSITION_AUX6,
        .aux7 => c.PA_CHANNEL_POSITION_AUX7,
        .aux8 => c.PA_CHANNEL_POSITION_AUX8,
        .aux9 => c.PA_CHANNEL_POSITION_AUX9,
        .aux10 => c.PA_CHANNEL_POSITION_AUX10,
        .aux11 => c.PA_CHANNEL_POSITION_AUX11,
        .aux12 => c.PA_CHANNEL_POSITION_AUX12,
        .aux13 => c.PA_CHANNEL_POSITION_AUX13,
        .aux14 => c.PA_CHANNEL_POSITION_AUX14,
        .aux15 => c.PA_CHANNEL_POSITION_AUX15,

        else => error.IncompatibleBackend,
    };
}

// based on pulseaudio v16.0
pub const RawError = error{
    AccessFailure,
    // UnknownCommand,
    // InvalidArgument,
    EntityExists,
    NoSuchEntity,
    ConnectionRefused,
    ProtocolError,
    Timeout,
    NoAuthenticationKey,
    InternalError,
    ConnectionTerminated,
    EntityKilled,
    InvalidServer,
    ModuleInitializationFailed,
    // BadState,
    NoData,
    IncompatibleProtocolVersion,
    DataTooLarge,
    OperationNotSupported,
    Unknown,
    NoExtension,
    // Obsolete,
    NotImplemented,
    // Forked,
    InputOutput,
    BusyResource,
};

pub fn getError(ctx: *c.pa_context) RawError {
    return switch (c.pa_context_errno(ctx)) {
        c.PA_OK => unreachable,
        c.PA_ERR_ACCESS => error.AccessFailure,
        c.PA_ERR_COMMAND => unreachable, // Unexpected
        c.PA_ERR_INVALID => unreachable, // Unexpected
        c.PA_ERR_EXIST => error.EntityExists,
        c.PA_ERR_NOENTITY => error.NoSuchEntity,
        c.PA_ERR_CONNECTIONREFUSED => error.ConnectionRefused,
        c.PA_ERR_PROTOCOL => error.ProtocolError,
        c.PA_ERR_TIMEOUT => error.Timeout,
        c.PA_ERR_AUTHKEY => error.NoAuthenticationKey,
        c.PA_ERR_INTERNAL => error.InternalError,
        c.PA_ERR_CONNECTIONTERMINATED => error.ConnectionTerminated,
        c.PA_ERR_KILLED => error.EntityKilled,
        c.PA_ERR_INVALIDSERVER => error.InvalidServer,
        c.PA_ERR_MODINITFAILED => error.ModuleInitializationFailed,
        c.PA_ERR_BADSTATE => unreachable, // Unexpected
        c.PA_ERR_NODATA => error.NoData,
        c.PA_ERR_VERSION => error.IncompatibleProtocolVersion,
        c.PA_ERR_TOOLARGE => error.DataTooLarge,
        c.PA_ERR_NOTSUPPORTED => error.OperationNotSupported,
        c.PA_ERR_UNKNOWN => error.Unknown,
        c.PA_ERR_NOEXTENSION => error.NoExtension,
        c.PA_ERR_OBSOLETE => unreachable, // Unexpected
        c.PA_ERR_NOTIMPLEMENTED => error.NotImplemented,
        c.PA_ERR_FORKED => unreachable, // Unexpected
        c.PA_ERR_IO => error.InputOutput,
        c.PA_ERR_BUSY => error.BusyResource,
        else => unreachable, // Unexpected
    };
}
