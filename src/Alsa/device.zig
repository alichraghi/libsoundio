const std = @import("std");
const c = @import("c.zig");
const util = @import("util.zig");
const Device = @import("../main.zig").Device;
const DevicesInfo = @import("../main.zig").DevicesInfo;
const Format = @import("../main.zig").Format;
const ChannelsArray = @import("../main.zig").ChannelsArray;
const max_channels = @import("../main.zig").max_channels;

pub fn queryDevices(devices_info: *DevicesInfo, allocator: std.mem.Allocator) !void {
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
        _ = switch (c.snd_ctl_open(&ctl, card_id.ptr, c.SND_PCM_ASYNC)) {
            0 => {},
            -@intCast(i16, @enumToInt(std.os.linux.E.NOENT)) => break,
            else => return error.OpeningDevice,
        };
        defer _ = c.snd_ctl_close(ctl);

        if (c.snd_ctl_card_info(ctl, card_info) < 0)
            return error.SystemResources;
        const card_name = c.snd_ctl_card_info_get_name(card_info);

        var device_index: c_int = -1;
        if (c.snd_ctl_pcm_next_device(ctl, &device_index) < 0)
            return error.SystemResources;
        if (device_index < 0) break;

        c.snd_pcm_info_set_device(pcm_info, @intCast(c_uint, device_index));
        c.snd_pcm_info_set_subdevice(pcm_info, 0);
        const device_name = c.snd_pcm_info_get_name(pcm_info);

        for (&[_]Device.Aim{ .playback, .capture }) |aim| {
            const snd_stream = util.aimToStream(aim);
            c.snd_pcm_info_set_stream(pcm_info, snd_stream);
            const err = c.snd_ctl_pcm_info(ctl, pcm_info);
            if (err < 0) {
                switch (std.os.linux.getErrno(@intCast(usize, -err))) {
                    .SUCCESS => {},
                    .NOENT,
                    .NXIO,
                    .NODEV,
                    => break,
                    else => return error.SystemResources,
                }
            }

            var buf: [8]u8 = undefined; // max card|device is 99
            const id = std.fmt.bufPrintZ(&buf, "hw:{d},{d}", .{ card_index, device_index }) catch continue;

            var pcm: ?*c.snd_pcm_t = null;
            if (c.snd_pcm_open(&pcm, id.ptr, snd_stream, c.SND_PCM_NONBLOCK) < 0)
                continue;
            defer _ = c.snd_pcm_close(pcm);

            var hw_params: ?*c.snd_pcm_hw_params_t = null;
            _ = c.snd_pcm_hw_params_malloc(&hw_params);
            defer c.snd_pcm_hw_params_free(hw_params);
            if (c.snd_pcm_hw_params_any(pcm, hw_params) < 0)
                continue;

            const device = Device{
                .aim = aim,
                .is_raw = true,
                .channels = blk: {
                    const chmap = c.snd_pcm_query_chmaps(pcm);
                    if (chmap) |_| {
                        defer c.snd_pcm_free_chmaps(chmap);
                        if (chmap[0] == null or chmap[0][0].map.channels <= 0) continue;
                        var channels = ChannelsArray.init(std.math.min(max_channels, chmap[0][0].map.channels)) catch unreachable;
                        for (channels.slice()) |*pos, i|
                            pos.*.id = util.fromAlsaChmapPos(chmap[0][0].map.pos()[i]);
                        break :blk channels;
                    } else {
                        continue;
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
                        continue;
                    if (c.snd_pcm_hw_params_get_rate_max(hw_params, &rate_max, null) < 0)
                        continue;
                    break :blk .{
                        .min = rate_min,
                        .max = rate_max,
                    };
                },
                .id = try allocator.dupeZ(u8, id),
                .name = try std.fmt.allocPrintZ(allocator, "{s} {s}", .{ card_name, device_name }),
            };

            try devices_info.list.append(allocator, device);

            if (devices_info.default(aim) == null and
                c.snd_pcm_hw_params_can_pause(hw_params) == 1 and
                device_index == 0)
                devices_info.setDefault(aim, devices_info.list.items.len - 1);
        }

        if (c.snd_card_next(&card_index) < 0)
            return error.SystemResources;
    }

    // if null, set first device to default
    // TODO: a better pattern
    for (&[_]Device.Aim{ .playback, .capture }) |aim| {
        if (devices_info.default(aim) == null) {
            for (devices_info.list.items) |d, i| {
                if (d.aim == aim and std.mem.endsWith(u8, d.id, ",0")) {
                    devices_info.setDefault(aim, i);
                    break;
                }
            }
        }

        if (devices_info.default(aim) == null) {
            for (devices_info.list.items) |d, i| {
                if (d.aim == aim) {
                    devices_info.setDefault(aim, i);
                    break;
                }
            }
        }
    }
}
