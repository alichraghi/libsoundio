const std = @import("std");
const c = @cImport(@cInclude("jack/jack.h"));
const main = @import("main.zig");
const backends = @import("backends.zig");
const util = @import("util.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    devices_info: util.DevicesInfo,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    client: *c.jack_client_t,
    sample_rate: u32,
    period_size: u32,
    watcher: ?DeviceWatcher,

    const DeviceWatcher = struct {
        deviceChangeFn: main.DeviceChangeFn,
        userdata: ?*anyopaque,
        aborted: std.atomic.Atomic(bool),
    };

    pub fn init(allocator: std.mem.Allocator, options: main.Context.Options) !backends.BackendContext {
        c.jack_set_error_function(@ptrCast(?*const fn ([*c]const u8) callconv(.C) void, &util.doNothing));
        c.jack_set_info_function(@ptrCast(?*const fn ([*c]const u8) callconv(.C) void, &util.doNothing));

        var status: c.jack_status_t = 0;
        var self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .devices_info = util.DevicesInfo.init(),
            .mutex = std.Thread.Mutex{},
            .cond = std.Thread.Condition{},
            .client = c.jack_client_open(options.app_name.ptr, c.JackNoStartServer, &status) orelse {
                std.debug.assert(status & c.JackInvalidOption == 0);
                return if (status & c.JackShmFailure != 0)
                    error.SystemResources
                else
                    error.ConnectionRefused;
            },
            .sample_rate = undefined,
            .period_size = undefined,
            .watcher = if (options.deviceChangeFn) |deviceChangeFn| .{
                .deviceChangeFn = deviceChangeFn,
                .userdata = options.userdata,
                .aborted = .{ .value = false },
            } else null,
        };

        self.period_size = c.jack_get_buffer_size(self.client);
        self.sample_rate = c.jack_get_sample_rate(self.client);

        if (options.deviceChangeFn) |_| {
            if (c.jack_set_buffer_size_callback(self.client, bufferSizeCallback, self) != 0 or
                c.jack_set_sample_rate_callback(self.client, sampleRateCallback, self) != 0 or
                c.jack_set_port_registration_callback(self.client, portRegistrationCallback, self) != 0 or
                c.jack_set_port_rename_callback(self.client, portRenameCalllback, self) != 0)
                return error.ConnectionRefused;
        }

        if (c.jack_activate(self.client) != 0)
            return error.ConnectionRefused;

        return .{ .jack = self };
    }

    pub fn deinit(self: *Context) void {
        for (self.devices_info.list.items) |device|
            freeDevice(self.allocator, device);
        self.devices_info.list.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn refresh(self: *Context) !void {
        for (self.devices_info.list.items) |d|
            freeDevice(self.allocator, d);
        self.devices_info.clear(self.allocator);

        const port_names = c.jack_get_ports(self.client, null, null, 0) orelse
            return error.OutOfMemory;
        defer c.jack_free(@ptrCast(?*anyopaque, port_names));

        var i: usize = 0;
        while (port_names[i] != null) : (i += 1) {
            const port = c.jack_port_by_name(self.client, port_names[i]) orelse break;
            const port_type = c.jack_port_type(port)[0..@intCast(usize, c.jack_port_type_size())];
            if (!std.mem.startsWith(u8, port_type, c.JACK_DEFAULT_AUDIO_TYPE))
                continue;

            const flags = c.jack_port_flags(port);
            const mode: main.Device.Mode = if (flags & c.JackPortIsInput != 0) .capture else .playback;
            if (self.devices_info.default(mode) != null) continue;

            const id = std.mem.span(port_names[i]);
            var device = main.Device{
                .id = id,
                .name = id,
                .mode = mode,
                .channels = blk: {
                    const short_name = std.mem.span(c.jack_port_short_name(port));
                    const count_str = std.mem.trimLeft(u8, std.mem.trimLeft(u8, short_name, "playback_"), "capture_");
                    const count = std.fmt.parseInt(u5, count_str, 10) catch continue;
                    var ch_arr = std.ArrayList(main.Channel).init(self.allocator);
                    var j: u5 = 0;
                    while (j < count) : (j += 1)
                        try ch_arr.append(.{ .id = @intToEnum(main.Channel.Id, j) });
                    break :blk ch_arr.toOwnedSlice();
                },
                .formats = &.{.f32},
                .sample_rate = .{
                    .min = std.math.clamp(self.sample_rate, main.min_sample_rate, main.max_sample_rate),
                    .max = std.math.clamp(self.sample_rate, main.min_sample_rate, main.max_sample_rate),
                },
            };

            try self.devices_info.list.append(self.allocator, device);
            self.devices_info.setDefault(device.mode, self.devices_info.list.items.len - 1);
        }
    }

    fn bufferSizeCallback(nframes: c.jack_nframes_t, arg: ?*anyopaque) callconv(.C) c_int {
        var self = @ptrCast(*Context, @alignCast(@alignOf(*Context), arg.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.period_size = nframes;
        self.watcher.?.deviceChangeFn(self.watcher.?.userdata);
        return 0;
    }

    fn sampleRateCallback(nframes: c.jack_nframes_t, arg: ?*anyopaque) callconv(.C) c_int {
        var self = @ptrCast(*Context, @alignCast(@alignOf(*Context), arg.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sample_rate = nframes;
        self.watcher.?.deviceChangeFn(self.watcher.?.userdata);
        return 0;
    }

    fn portRegistrationCallback(_: c.jack_port_id_t, _: c_int, arg: ?*anyopaque) callconv(.C) void {
        var self = @ptrCast(*Context, @alignCast(@alignOf(*Context), arg.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.watcher.?.deviceChangeFn(self.watcher.?.userdata);
    }

    fn portRenameCalllback(_: c.jack_port_id_t, _: [*c]const u8, _: [*c]const u8, arg: ?*anyopaque) callconv(.C) void {
        var self = @ptrCast(*Context, @alignCast(@alignOf(*Context), arg.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.watcher.?.deviceChangeFn(self.watcher.?.userdata);
    }

    pub fn devices(self: *Context) []const main.Device {
        return self.devices_info.list.items;
    }

    pub fn defaultDevice(self: *Context, mode: main.Device.Mode) ?main.Device {
        return self.devices_info.default(mode);
    }

    pub fn createPlayer(self: *Context, player: *main.Player) !void {
        _ = self;
        _ = player;
    }
};

pub fn freeDevice(allocator: std.mem.Allocator, device: main.Device) void {
    allocator.free(device.channels);
}
