const std = @import("std");
const c = @cImport({
    @cInclude("spa/param/audio/format-utils.h");
    @cInclude("pipewire/pipewire.h");
});
const DevicesInfo = @import("main.zig").DevicesInfo;
const Device = @import("main.zig").Device;
const Format = @import("main.zig").Format;
const ChannelLayout = @import("main.zig").ChannelLayout;
const ChannelId = @import("main.zig").ChannelId;
const ChannelArea = @import("main.zig").ChannelArea;
const Outstream = @import("main.zig").Outstream;
const max_channels = @import("main.zig").max_channels;
const min_sample_rate = @import("main.zig").min_sample_rate;
const max_sample_rate = @import("main.zig").max_sample_rate;
const getLayoutByChannels = @import("channel_layout.zig").getLayoutByChannels;

const PipeWire = @This();

allocator: std.mem.Allocator,
// device_scan_queued: std.atomic.Atomic(bool),
main_loop: *c.pw_main_loop,
builder: *c.spa_pod_builder,
devices_info: DevicesInfo,
default_sink_id: ?[:0]const u8,
default_source_id: ?[:0]const u8,

pub fn connect(allocator: std.mem.Allocator) !*PipeWire {
    var self = try allocator.create(PipeWire);
    var buf: [1024]u8 = undefined; // NOTE: move this to struct?
    var builder: c.spa_pod_builder = .{
        .data = &buf,
        .size = buf.len,
        ._padding = 0,
        .state = .{
            .offset = 0,
            .flags = 0,
            .frame = null,
        },
        .callbacks = .{
            .funcs = null,
            .data = null,
        },
    };
    c.pw_init(null, null);
    self.* = .{
        .allocator = allocator,
        .main_loop = c.pw_main_loop_new(null) orelse return error.OutOfMemory,
        .builder = &builder,
        .devices_info = .{
            .list = .{},
            .default_output_index = 0,
            .default_input_index = 0,
        },
        .default_sink_id = null,
        .default_source_id = null,
    };
    return self;
}

pub fn deinit(self: *PipeWire) void {
    c.pw_main_loop_destroy(self.main_loop);
    c.pw_deinit();
    self.devices_info.list.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn flushEvents(self: *PipeWire) !void {
    _ = self;
}

pub fn waitEvents(self: *PipeWire) !void {
    _ = self;
}

pub fn wakeUp(self: *PipeWire) void {
    _ = self;
}

pub fn devicesList(self: PipeWire) []const Device {
    return self.devices_info.list.items;
}

pub const OutstreamData = struct {
    sipw: *const PipeWire,
    stream: *c.pw_stream,
};
pub fn on_process(arg_userdata: ?*anyopaque) callconv(.C) void {
    _ = arg_userdata;
}
const stream_events: c.struct_pw_stream_events = .{
    .version = c.PW_VERSION_STREAM_EVENTS,
    .destroy = null,
    .state_changed = null,
    .control_info = null,
    .io_changed = null,
    .param_changed = null,
    .add_buffer = null,
    .remove_buffer = null,
    .process = on_process,
    .drained = null,
    .command = null,
    .trigger_done = null,
};
pub fn outstreamOpen(self: *PipeWire, outstream: *Outstream, device: Device) !void {
    _ = device;
    outstream.backend_data = .{
        .pipewire = .{
            .sipw = self,
            .stream = undefined,
        },
    };
    var ospw = &outstream.backend_data.pipewire;
    ospw.stream = c.pw_stream_new_simple(
        c.pw_main_loop_get_loop(self.main_loop),
        "audio-src",
        c.pw_properties_new(
            c.PW_KEY_MEDIA_TYPE,
            "Audio",
            c.PW_KEY_MEDIA_CATEGORY,
            "Playback",
            c.PW_KEY_MEDIA_ROLE,
            "Music",
            @intToPtr(?*anyopaque, 0),
        ),
        &stream_events,
        outstream,
    ) orelse unreachable;
    var arg_info: c.spa_audio_info_raw = .{
        .format = c.SPA_AUDIO_FORMAT_F32, // SPA_AUDIO_FORMAT_S16
        .flags = 0,
        .rate = 44100,
        .channels = 2,
        .position = std.mem.zeroes([64]u32),
    };
    var params = &[_][*c]const c.spa_pod{spa_format_audio_raw_build(
        self.builder,
        c.SPA_PARAM_EnumFormat,
        &arg_info,
    )};
    _ = c.pw_stream_connect(
        ospw.stream,
        c.PW_DIRECTION_OUTPUT,
        c.PW_ID_ANY,
        c.PW_STREAM_FLAG_AUTOCONNECT |
            c.PW_STREAM_FLAG_MAP_BUFFERS |
            c.PW_STREAM_FLAG_RT_PROCESS,
        params,
        params.len,
    );
}

pub fn outstreamDeinit(self: *Outstream) void {
    c.pw_stream_destroy(self.backend_data.pipewire.stream);
}

pub fn outstreamStart(self: *Outstream) !void {
    _ = c.pw_main_loop_run(self.backend_data.pipewire.sipw.main_loop);
    std.debug.print("GG\n", .{});
}

pub fn outstreamBeginWrite(self: *Outstream, frame_count: *usize) ![]const ChannelArea {
    var ospw = &self.backend_data.pipewire;
    var b = c.pw_stream_dequeue_buffer(ospw.stream);
    const stride = @sizeOf(u16) * 2;
    frame_count.* = b.*.buffer.*.datas[0].maxsize / stride;
    std.debug.print("\n\n{d}\n\n", .{frame_count.*});
    return undefined;
}

pub fn outstreamEndWrite(self: *Outstream) !void {
    _ = self;
}

pub fn outstreamClearBuffer(self: *Outstream) void {
    _ = self;
}

pub fn outstreamPausePlay(self: *Outstream, pause: bool) !void {
    _ = self;
    _ = pause;
}

pub fn outstreamGetLatency(self: *Outstream) !f64 {
    _ = self;
}

pub fn outstreamSetVolume(self: *Outstream, volume: f64) !void {
    _ = self;
    _ = volume;
}

pub fn outstreamVolume(self: *Outstream) error{}!f64 {
    _ = self;
    return undefined;
}

pub fn deviceDeinit(self: Device, allocator: std.mem.Allocator) void {
    _ = self;
    _ = allocator;
    // allocator.free(self.id);
    // allocator.free(self.name);
}

fn refreshDevices(self: *PipeWire) !void {
    _ = self;
}

//////////// C

extern fn spa_pod_builder_add(builder: [*c]c.struct_spa_pod_builder, ...) c_int;
// TODO: fill an issue for this
fn spa_format_audio_raw_build(arg_builder: [*c]c.struct_spa_pod_builder, arg_id: u32, arg_info: [*c]c.struct_spa_audio_info_raw) callconv(.C) [*c]c.struct_spa_pod {
    var builder = arg_builder;
    var id = arg_id;
    var info = arg_info;
    var f: c.struct_spa_pod_frame = undefined;
    _ = c.spa_pod_builder_push_object(builder, &f, @bitCast(u32, c.SPA_TYPE_OBJECT_Format), id);
    _ = spa_pod_builder_add(builder, c.SPA_FORMAT_mediaType, "I", c.SPA_MEDIA_TYPE_audio, c.SPA_FORMAT_mediaSubtype, "I", c.SPA_MEDIA_SUBTYPE_raw, @as(c_int, 0));
    if (info.*.format != @bitCast(c_uint, c.SPA_AUDIO_FORMAT_UNKNOWN)) {
        _ = spa_pod_builder_add(builder, c.SPA_FORMAT_AUDIO_format, "I", info.*.format, @as(c_int, 0));
    }
    if (info.*.rate != @bitCast(c_uint, @as(c_int, 0))) {
        _ = spa_pod_builder_add(builder, c.SPA_FORMAT_AUDIO_rate, "i", info.*.rate, @as(c_int, 0));
    }
    if (info.*.channels != @bitCast(c_uint, @as(c_int, 0))) {
        _ = spa_pod_builder_add(builder, c.SPA_FORMAT_AUDIO_channels, "i", info.*.channels, @as(c_int, 0));
        if (!((info.*.flags & @bitCast(c_uint, @as(c_int, 1) << @intCast(std.math.Log2Int(c_int), 0))) == @bitCast(c_uint, @as(c_int, 1) << @intCast(std.math.Log2Int(c_int), 0)))) {
            _ = spa_pod_builder_add(builder, c.SPA_FORMAT_AUDIO_position, "a", @intCast(u32, @sizeOf(u32)), c.SPA_TYPE_Id, info.*.channels, @ptrCast([*c]u32, @alignCast(std.meta.alignment([*c]u32), &info.*.position)), @as(c_int, 0));
        }
    }
    return @ptrCast([*c]c.struct_spa_pod, @alignCast(std.meta.alignment([*c]c.struct_spa_pod), spa_pod_builder_pop(builder, &f)));
}

fn spa_pod_builder_pop(arg_builder: [*c]c.struct_spa_pod_builder, arg_frame: [*c]c.struct_spa_pod_frame) callconv(.C) ?*anyopaque {
    var builder = arg_builder;
    var frame = arg_frame;
    var pod: [*c]c.struct_spa_pod = undefined;
    if ((builder.*.state.flags & @bitCast(c_uint, @as(c_int, 1) << @intCast(std.math.Log2Int(c_int), 1))) == @bitCast(c_uint, @as(c_int, 1) << @intCast(std.math.Log2Int(c_int), 1))) {
        const p: c.struct_spa_pod = c.struct_spa_pod{
            .size = @bitCast(u32, @as(c_int, 0)),
            .@"type" = @bitCast(u32, c.SPA_TYPE_None),
        };
        _ = c.spa_pod_builder_raw(builder, @ptrCast(?*const anyopaque, &p), @bitCast(u32, @truncate(c_uint, @sizeOf(c.struct_spa_pod))));
    }
    if ((blk: {
        const tmp = spa_pod_builder_frame(builder, frame);
        pod = tmp;
        break :blk tmp;
    }) != @ptrCast([*c]c.struct_spa_pod, @alignCast(std.meta.alignment([*c]c.struct_spa_pod), @intToPtr(?*anyopaque, @as(c_int, 0))))) {
        pod.* = frame.*.pod;
    }
    builder.*.state.frame = frame.*.parent;
    builder.*.state.flags = frame.*.flags;
    _ = c.spa_pod_builder_pad(builder, builder.*.state.offset);
    return @ptrCast(?*anyopaque, pod);
}

// TODO: fill an issue for this
pub fn spa_pod_builder_frame(arg_builder: [*c]c.struct_spa_pod_builder, arg_frame: [*c]c.struct_spa_pod_frame) callconv(.C) [*c]c.struct_spa_pod {
    var builder = arg_builder;
    var frame = arg_frame;
    if ((@bitCast(c_ulong, @as(c_ulong, frame.*.offset)) +% (@intCast(u64, @sizeOf(c.struct_spa_pod)) +% @bitCast(c_ulong, @as(c_ulong, (&frame.*.pod).*.size)))) <= @bitCast(c_ulong, @as(c_ulong, builder.*.size))) return @intToPtr([*c]c.struct_spa_pod, @intCast(usize, @ptrToInt(builder.*.data)) +% @bitCast(c_ulong, @bitCast(c.ptrdiff_t, @as(c_ulong, frame.*.offset))));
    return null;
}
