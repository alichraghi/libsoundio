const is_little = @import("builtin").cpu.arch.endian() == .Little;
const c = @import("c.zig");
const Device = @import("../main.zig").Device;
const ChannelId = @import("../main.zig").ChannelId;
const Format = @import("../main.zig").Format;

pub const supported_formats = &[_]Format{
    .s8,
    .u8,
    .s16,
    .u16,
    .s24,
    .u24,
    .s24_32,
    .u24_32,
    .s32,
    .u32,
    .f32,
    .f64,
};

pub fn aimToStream(aim: Device.Aim) c_uint {
    return switch (aim) {
        .playback => c.SND_PCM_STREAM_PLAYBACK,
        .capture => c.SND_PCM_STREAM_CAPTURE,
    };
}

pub fn toAlsaFormat(format: Format) !c.snd_pcm_format_t {
    return switch (format) {
        .s8 => c.SND_PCM_FORMAT_S8,
        .u8 => c.SND_PCM_FORMAT_U8,
        .s16 => if (is_little) c.SND_PCM_FORMAT_S16_LE else c.SND_PCM_FORMAT_S16_BE,
        .u16 => if (is_little) c.SND_PCM_FORMAT_U16_LE else c.SND_PCM_FORMAT_U16_BE,
        .s24 => if (is_little) c.SND_PCM_FORMAT_S24_3LE else c.SND_PCM_FORMAT_S24_3BE,
        .u24 => if (is_little) c.SND_PCM_FORMAT_U24_3LE else c.SND_PCM_FORMAT_U24_3BE,
        .s24_32 => if (is_little) c.SND_PCM_FORMAT_S24_LE else c.SND_PCM_FORMAT_S24_BE,
        .u24_32 => if (is_little) c.SND_PCM_FORMAT_U24_LE else c.SND_PCM_FORMAT_U24_BE,
        .s32 => if (is_little) c.SND_PCM_FORMAT_S32_LE else c.SND_PCM_FORMAT_S32_BE,
        .u32 => if (is_little) c.SND_PCM_FORMAT_U32_LE else c.SND_PCM_FORMAT_U32_BE,
        .f32 => if (is_little) c.SND_PCM_FORMAT_FLOAT_LE else c.SND_PCM_FORMAT_FLOAT_BE,
        .f64 => if (is_little) c.SND_PCM_FORMAT_FLOAT64_LE else c.SND_PCM_FORMAT_FLOAT64_BE,
    };
}

pub fn fromAlsaChmapPos(pos: c_uint) ChannelId {
    return switch (pos) {
        c.SND_CHMAP_UNKNOWN, c.SND_CHMAP_NA => unreachable, // TODO
        c.SND_CHMAP_MONO, c.SND_CHMAP_FC => .front_center,
        c.SND_CHMAP_FL => .front_left,
        c.SND_CHMAP_FR => .front_right,
        c.SND_CHMAP_RL => .back_left,
        c.SND_CHMAP_RR => .back_right,
        c.SND_CHMAP_LFE => .lfe,
        c.SND_CHMAP_SL => .side_left,
        c.SND_CHMAP_SR => .side_right,
        c.SND_CHMAP_RC => .back_center,
        c.SND_CHMAP_FLC => .front_left_center,
        c.SND_CHMAP_FRC => .front_right_center,
        c.SND_CHMAP_RLC => .back_left_center,
        c.SND_CHMAP_RRC => .back_right_center,
        c.SND_CHMAP_FLW => .front_left_wide,
        c.SND_CHMAP_FRW => .front_right_wide,
        c.SND_CHMAP_FLH => .front_left_high,
        c.SND_CHMAP_FCH => .front_center_high,
        c.SND_CHMAP_FRH => .front_right_high,
        c.SND_CHMAP_TC => .top_center,
        c.SND_CHMAP_TFL => .top_front_left,
        c.SND_CHMAP_TFR => .top_front_right,
        c.SND_CHMAP_TFC => .top_front_center,
        c.SND_CHMAP_TRL => .top_back_left,
        c.SND_CHMAP_TRR => .top_back_right,
        c.SND_CHMAP_TRC => .top_back_center,
        c.SND_CHMAP_TFLC => .top_front_left_center,
        c.SND_CHMAP_TFRC => .top_front_right_center,
        c.SND_CHMAP_TSL => .top_side_left,
        c.SND_CHMAP_TSR => .top_side_right,
        c.SND_CHMAP_LLFE => .left_lfe,
        c.SND_CHMAP_RLFE => .right_lfe,
        c.SND_CHMAP_BC => .bottom_center,
        c.SND_CHMAP_BLC => .bottom_left_center,
        c.SND_CHMAP_BRC => .bottom_right_center,

        else => unreachable,
    };
}

pub fn toAlsaChmapPos(pos: ChannelId) c_uint {
    return switch (pos) {
        .front_center => c.SND_CHMAP_FC,
        .front_left => c.SND_CHMAP_FL,
        .front_right => c.SND_CHMAP_FR,
        .back_left => c.SND_CHMAP_RL,
        .back_right => c.SND_CHMAP_RR,
        .lfe => c.SND_CHMAP_LFE,
        .side_left => c.SND_CHMAP_SL,
        .side_right => c.SND_CHMAP_SR,
        .back_center => c.SND_CHMAP_RC,
        .front_left_center => c.SND_CHMAP_FLC,
        .front_right_center => c.SND_CHMAP_FRC,
        .back_left_center => c.SND_CHMAP_RLC,
        .back_right_center => c.SND_CHMAP_RRC,
        .front_left_wide => c.SND_CHMAP_FLW,
        .front_right_wide => c.SND_CHMAP_FRW,
        .front_left_high => c.SND_CHMAP_FLH,
        .front_center_high => c.SND_CHMAP_FCH,
        .front_right_high => c.SND_CHMAP_FRH,
        .top_center => c.SND_CHMAP_TC,
        .top_front_left => c.SND_CHMAP_TFL,
        .top_front_right => c.SND_CHMAP_TFR,
        .top_front_center => c.SND_CHMAP_TFC,
        .top_back_left => c.SND_CHMAP_TRL,
        .top_back_right => c.SND_CHMAP_TRR,
        .top_back_center => c.SND_CHMAP_TRC,
        .top_front_left_center => c.SND_CHMAP_TFLC,
        .top_front_right_center => c.SND_CHMAP_TFRC,
        .top_side_left => c.SND_CHMAP_TSL,
        .top_side_right => c.SND_CHMAP_TSR,
        .left_lfe => c.SND_CHMAP_LLFE,
        .right_lfe => c.SND_CHMAP_RLFE,
        .bottom_center => c.SND_CHMAP_BC,
        .bottom_left_center => c.SND_CHMAP_BLC,
        .bottom_right_center => c.SND_CHMAP_BRC,

        else => unreachable,
    };
}
