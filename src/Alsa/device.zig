const std = @import("std");
const c = @import("c.zig");
const util = @import("util.zig");
const Device = @import("../main.zig").Device;
const DevicesInfo = @import("../main.zig").DevicesInfo;
const Format = @import("../main.zig").Format;
const ChannelsArray = @import("../main.zig").ChannelsArray;
const max_channels = @import("../main.zig").max_channels;

pub fn queryCookedDevices(devices_info: *DevicesInfo, alloctaor: std.mem.Allocator) !void {
    var hints: []?*anyopaque = undefined;
    if (c.snd_device_name_hint(-1, "pcm", @ptrCast([*c][*c]?*anyopaque, &hints)) < 0)
        return error.OutOfMemory;
    defer _ = c.snd_device_name_free_hint(hints[0..].ptr);

    var i: usize = 0;
    while (hints[i] != null) : (i += 1) {
        const id = std.mem.span(c.snd_device_name_get_hint(hints[i], "NAME") orelse continue);
        defer std.heap.c_allocator.free(id);

        if (std.mem.eql(u8, id, "null") or
            // the worse device
            std.mem.eql(u8, id, "default") or
            // skip jack backend because of noisy errors
            std.mem.eql(u8, id, "jack") or
            // all these surround devices are clutter
            std.mem.startsWith(u8, id, "front:") or
            std.mem.startsWith(u8, id, "surround21:") or
            std.mem.startsWith(u8, id, "surround40:") or
            std.mem.startsWith(u8, id, "surround41:") or
            std.mem.startsWith(u8, id, "surround50:") or
            std.mem.startsWith(u8, id, "surround51:") or
            std.mem.startsWith(u8, id, "surround71:"))
            continue;

        const name = if (c.snd_device_name_get_hint(hints[i], "DESC")) |d|
            std.mem.span(d)
        else
            id;
        defer std.heap.c_allocator.free(name);

        if (c.snd_device_name_get_hint(hints[i], "IOID")) |io| {
            const io_span = std.mem.span(io);
            defer std.heap.c_allocator.free(io_span);
            if (std.mem.eql(u8, io_span, "Output")) {
                try appendCookedDevice(devices_info, alloctaor, id, name, .playback);
            } else {
                try appendCookedDevice(devices_info, alloctaor, id, name, .capture);
            }
        } else {
            try appendCookedDevice(devices_info, alloctaor, id, name, .playback);
            try appendCookedDevice(devices_info, alloctaor, id, name, .capture);
        }
    }
}

fn appendCookedDevice(devices_info: *DevicesInfo, allocator: std.mem.Allocator, id: [:0]const u8, name: [:0]const u8, aim: Device.Aim) !void {
    const id_alloc = try allocator.dupeZ(u8, id);
    const name_alloc = try allocator.dupeZ(u8, name);
    probeDevice(devices_info, allocator, id_alloc, name_alloc, aim, false) catch |err| {
        allocator.free(id_alloc);
        allocator.free(name_alloc);
        switch (err) {
            error.OpeningDevice => return,
            error.OutOfMemory => return err,
        }
    };

    if (devices_info.default(aim) == null and std.mem.startsWith(u8, id, "sysdefault"))
        devices_info.setDefault(aim, devices_info.list.items.len - 1);
}

pub fn queryRawDevices(devices_info: *DevicesInfo, allocator: std.mem.Allocator) !void {
    var card_info: ?*c.snd_ctl_card_info_t = null;
    _ = c.snd_ctl_card_info_malloc(&card_info);
    defer c.snd_ctl_card_info_free(card_info);

    var pcm_info: ?*c.snd_pcm_info_t = null;
    _ = c.snd_pcm_info_malloc(&pcm_info);
    defer c.snd_pcm_info_free(pcm_info);

    var card_index: c_int = -1;
    if (c.snd_card_next(&card_index) < 0)
        return error.SystemResources;

    while (card_index >= 0) {
        var card_id_buf: [8]u8 = undefined;
        const card_id = std.fmt.bufPrintZ(&card_id_buf, "hw:{d}", .{card_index}) catch break;

        var ctl: ?*c.snd_ctl_t = undefined;
        _ = switch (c.snd_ctl_open(&ctl, card_id.ptr, 0)) {
            0 => {},
            -@intCast(i16, @enumToInt(std.os.linux.E.NOENT)) => break,
            else => return error.OpeningDevice,
        };
        defer _ = c.snd_ctl_close(ctl);

        if (c.snd_ctl_card_info(ctl, card_info) < 0)
            return error.SystemResources;
        const card_name = c.snd_ctl_card_info_get_name(card_info);

        var device_index: c_int = -1;
        while (true) {
            if (c.snd_ctl_pcm_next_device(ctl, &device_index) < 0)
                return error.SystemResources;
            if (device_index < 0) break;

            c.snd_pcm_info_set_device(pcm_info, @intCast(c_uint, device_index));
            c.snd_pcm_info_set_subdevice(pcm_info, 0);
            const device_name = c.snd_pcm_info_get_name(pcm_info);

            for (&[_]Device.Aim{ .playback, .capture }) |aim| {
                const snd_stream = util.aimToStream(aim);
                c.snd_pcm_info_set_stream(pcm_info, snd_stream);
                _ = switch (c.snd_ctl_pcm_info(ctl, pcm_info)) {
                    0 => {},
                    -@intCast(i16, @enumToInt(std.os.linux.E.NOENT)) => break,
                    else => return error.SystemResources,
                };

                const id = try std.fmt.allocPrintZ(allocator, "hw:{d},{d}", .{ card_index, device_index });
                const name = try std.fmt.allocPrintZ(allocator, "{s} {s}", .{ card_name, device_name });

                probeDevice(devices_info, allocator, id, name, aim, true) catch {
                    allocator.free(id);
                    allocator.free(name);
                    continue;
                };

                if (devices_info.default(aim) == null and device_index == 0)
                    devices_info.setDefault(aim, devices_info.list.items.len - 1);
            }
        }

        if (c.snd_card_next(&card_index) < 0)
            return error.SystemResources;
    }
}

fn probeDevice(devices_info: *DevicesInfo, allocator: std.mem.Allocator, id: [:0]const u8, name: [:0]const u8, aim: Device.Aim, is_raw: bool) !void {
    const snd_stream = util.aimToStream(aim);

    var pcm: ?*c.snd_pcm_t = null;
    if (c.snd_pcm_open(&pcm, id.ptr, snd_stream, 0) < 0)
        return error.OpeningDevice;
    defer _ = c.snd_pcm_close(pcm);

    var hw_params: ?*c.snd_pcm_hw_params_t = null;
    _ = c.snd_pcm_hw_params_malloc(&hw_params);
    defer c.snd_pcm_hw_params_free(hw_params);
    if (c.snd_pcm_hw_params_any(pcm, hw_params) < 0)
        return error.OpeningDevice;

    const device = Device{
        .id = id,
        .name = name,
        .aim = aim,
        .is_raw = is_raw,
        .channels = blk: {
            const chmap = c.snd_pcm_query_chmaps(pcm);
            if (chmap) |_| {
                defer c.snd_pcm_free_chmaps(chmap);
                if (chmap[0] == null or chmap[0][0].map.channels <= 0) return error.OpeningDevice;
                var channels = ChannelsArray.init(std.math.min(max_channels, chmap[0][0].map.channels)) catch unreachable;
                for (channels.slice()) |*pos, i|
                    pos.*.id = util.fromAlsaChmapPos(chmap[0][0].map.pos()[i]);
                break :blk channels;
            } else {
                return error.OpeningDevice;
            }
        },
        .formats = blk: {
            var fmt_mask: ?*c.snd_pcm_format_mask_t = null;
            _ = c.snd_pcm_format_mask_malloc(&fmt_mask);
            defer c.snd_pcm_format_mask_free(fmt_mask);
            c.snd_pcm_format_mask_none(fmt_mask);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S8);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U8);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S16_LE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S16_BE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U16_LE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U16_BE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S24_3LE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S24_3BE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U24_3LE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U24_3BE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S24_LE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S24_BE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U24_LE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U24_BE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S32_LE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_S32_BE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U32_LE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_U32_BE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_FLOAT_LE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_FLOAT_BE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_FLOAT64_LE);
            c.snd_pcm_format_mask_set(fmt_mask, c.SND_PCM_FORMAT_FLOAT64_BE);

            c.snd_pcm_hw_params_get_format_mask(hw_params, fmt_mask);

            var fmt_arr = std.ArrayList(Format).init(allocator);
            for (util.supported_formats) |format| {
                if (c.snd_pcm_format_mask_test(fmt_mask, util.toAlsaFormat(format) catch unreachable) != 0)
                    try fmt_arr.append(format);
            }
            break :blk fmt_arr.toOwnedSlice();
        },
        .rate_range = blk: {
            var rate_min: c_uint = 0;
            var rate_max: c_uint = 0;
            if (c.snd_pcm_hw_params_get_rate_min(hw_params, &rate_min, null) < 0)
                return error.OpeningDevice;
            if (c.snd_pcm_hw_params_get_rate_max(hw_params, &rate_max, null) < 0)
                return error.OpeningDevice;
            break :blk .{
                .min = rate_min,
                .max = rate_max,
            };
        },
    };

    try devices_info.list.append(allocator, device);
}
