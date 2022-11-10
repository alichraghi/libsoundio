const std = @import("std");
const c = @cImport(@cInclude("jack/jack.h"));
const Device = @import("main.zig").Device;
const Outstream = @import("main.zig").Outstream;
const ChannelLayout = @import("main.zig").ChannelLayout;
const ChannelArea = @import("main.zig").ChannelArea;
const ConnectOptions = @import("main.zig").ConnectOptions;
const ShutdownFn = @import("main.zig").ShutdownFn;
const DevicesInfo = @import("main.zig").DevicesInfo;
const Range = @import("main.zig").Range;
const Format = @import("main.zig").Format;
const min_sample_rate = @import("main.zig").min_sample_rate;
const max_sample_rate = @import("main.zig").max_sample_rate;
const getLayoutByChannels = @import("channel_layout.zig").getLayoutByChannels;
const parseChannelId = @import("channel_layout.zig").parseChannelId;

const Jack = @This();

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex,
cond: std.Thread.Condition,
shutdown_emmited: bool, // TODO: make this atomic
shutdownFn: ?ShutdownFn,
userdata: ?*anyopaque,
devices_info: DevicesInfo,
client: *c.jack_client_t,
device_scan_queued: std.atomic.Atomic(bool),
sample_rate: u32,
period_size: u32,
devices_latency_range: std.ArrayListUnmanaged(Range(u32)),

pub fn connect(allocator: std.mem.Allocator, options: ConnectOptions) !*Jack {
    c.jack_set_error_function(emptyMsgCallback);
    c.jack_set_info_function(emptyMsgCallback);

    var status: c.jack_status_t = 0;
    var self = try allocator.create(Jack);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .mutex = std.Thread.Mutex{},
        .cond = std.Thread.Condition{},
        .shutdown_emmited = false,
        .shutdownFn = options.shutdownFn,
        .userdata = options.userdata,
        .devices_info = .{
            .list = .{},
            .default_output_index = 0,
            .default_input_index = 0,
        },
        .client = c.jack_client_open("SoundIO", c.JackNoStartServer, &status) orelse {
            std.debug.assert(status & c.JackInvalidOption == 0);
            return if (status & c.JackShmFailure != 0)
                error.SystemResources
            else if (status & c.JackNoSuchClient != 0)
                error.NoSuchClient
            else
                error.InitAudioBackend;
        },
        .device_scan_queued = std.atomic.Atomic(bool).init(false),
        .sample_rate = undefined,
        .period_size = undefined,
        .devices_latency_range = .{},
    };

    if (c.jack_set_buffer_size_callback(self.client, bufferSizeCallback, self) != 0 or
        c.jack_set_sample_rate_callback(self.client, sampleRateCallback, self) != 0 or
        c.jack_set_port_registration_callback(self.client, portRegistrationCallback, self) != 0 or
        c.jack_set_port_rename_callback(self.client, portRenameCalllback, self) != 0)
        return error.InitAudioBackend;

    if (options.shutdownFn != null)
        c.jack_on_shutdown(self.client, shutdownCallback, self);

    self.period_size = c.jack_get_buffer_size(self.client);
    self.sample_rate = c.jack_get_sample_rate(self.client);

    if (c.jack_activate(self.client) != 0)
        return error.InitAudioBackend;

    try self.refreshDevices();
    return self;
}

pub fn refreshDevices(self: *Jack) !void {
    self.devices_info.list.clearAndFree(self.allocator);
    self.devices_latency_range.clearAndFree(self.allocator);

    var max_try: u3 = 5;
    intr: while (max_try > 0) : (max_try -= 1) {
        if (self.shutdown_emmited)
            return error.Disconnected;

        const client_port_names = c.jack_get_ports(self.client, null, null, 0) orelse
            return error.OutOfMemory; // TODO better error name
        defer c.jack_free(@ptrCast(?*anyopaque, client_port_names));

        var i: usize = 0;
        while (client_port_names[i] != null) : (i += 1) {
            const port = c.jack_port_by_name(self.client, client_port_names[i]) orelse continue :intr; // scan is already outdated. let's start again

            const port_type = c.jack_port_type(port)[0..@intCast(usize, c.jack_port_type_size())];
            if (!std.mem.eql(u8, port_type, c.JACK_DEFAULT_AUDIO_TYPE))
                continue; // we don't know how to support such a port

            var cpniter = std.mem.split(u8, std.mem.span(client_port_names[i]), ":");
            const client_name = cpniter.first();
            const port_name = cpniter.rest();

            const flags = c.jack_port_flags(port);
            const aim: Device.Aim = if (flags & c.JackPortIsInput != 0) .input else .output;
            const channel_name = std.mem.trimLeft(u8, std.mem.trimLeft(u8, std.mem.trimLeft(u8, std.mem.trimLeft(u8, port_name, "capture_"), "output_"), "playback_"), "monitor_");

            var found = false;
            for (self.devices_info.list.items) |*d| {
                if (std.mem.eql(u8, d.id, client_name) and d.aim == aim) {
                    found = true;
                    // we hit the channel limit, skip the leftovers
                    d.layout.channels.append(parseChannelId(channel_name) orelse break) catch break;
                    break;
                }
            }

            if (!found) {
                var device: Device = undefined;
                device.id = try self.allocator.dupeZ(u8, client_name);
                errdefer _ = self.allocator.free(device.id);
                device.name = device.id;

                device.aim = aim;
                device.is_raw = flags & c.JackPortIsPhysical != 0;
                device.layout.channels.append(parseChannelId(channel_name) orelse continue) catch continue;
                device.sample_rate = .{
                    .min = std.math.clamp(self.sample_rate, min_sample_rate, max_sample_rate),
                    .max = std.math.clamp(self.sample_rate, min_sample_rate, max_sample_rate),
                };
                device.latency = .{
                    .min = @intToFloat(f64, self.period_size) / @intToFloat(f64, self.sample_rate),
                    .max = @intToFloat(f64, self.period_size) / @intToFloat(f64, self.sample_rate),
                };

                var latency: c.jack_latency_range_t = undefined;
                const latency_mode = @intCast(c_uint, if (device.aim == .output) c.JackPlaybackLatency else c.JackCaptureLatency);
                c.jack_port_get_latency_range(port, latency_mode, &latency);
                try self.devices_latency_range.append(self.allocator, .{ .min = latency.min, .max = latency.max });

                try self.devices_info.list.append(self.allocator, device);
                errdefer _ = self.devices_latency_range.pop();
            }
        }
        std.debug.assert(i > 0);

        for (self.devices_info.list.items) |*device| {
            device.layout = getLayoutByChannels(device.layout.channels.slice()) orelse {
                device.layout.name = "unknown"; // TODO: fallback to getLayoutByChannelCount
                continue;
            };
        }

        return;
    }
}

fn emptyMsgCallback(_: [*c]const u8) callconv(.C) void {}

fn bufferSizeCallback(nframes: c.jack_nframes_t, arg: ?*anyopaque) callconv(.C) c_int {
    var self = @ptrCast(*Jack, @alignCast(@alignOf(*Jack), arg.?));
    self.mutex.lock();
    defer self.mutex.unlock();
    self.period_size = nframes;
    notifyDevicesChange(self);
    return 0;
}

fn sampleRateCallback(nframes: c.jack_nframes_t, arg: ?*anyopaque) callconv(.C) c_int {
    var self = @ptrCast(*Jack, @alignCast(@alignOf(*Jack), arg.?));
    self.mutex.lock();
    defer self.mutex.unlock();
    self.sample_rate = nframes;
    notifyDevicesChange(self);
    return 0;
}

fn portRegistrationCallback(_: c.jack_port_id_t, _: c_int, arg: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*Jack, @alignCast(@alignOf(*Jack), arg.?));
    self.mutex.lock();
    defer self.mutex.unlock();
    notifyDevicesChange(self);
}

fn portRenameCalllback(_: c.jack_port_id_t, _: [*c]const u8, _: [*c]const u8, arg: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*Jack, @alignCast(@alignOf(*Jack), arg.?));
    self.mutex.lock();
    defer self.mutex.unlock();
    notifyDevicesChange(self);
}

fn notifyDevicesChange(self: *Jack) void {
    self.device_scan_queued.storeUnchecked(true);
    self.cond.signal();
}

fn shutdownCallback(arg: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*Jack, @alignCast(@alignOf(*Jack), arg.?));
    self.mutex.lock();
    defer self.mutex.unlock();

    self.shutdown_emmited = true;
    self.shutdownFn.?(self.userdata);
}

pub fn deinit(self: *Jack) void {
    for (self.devices_info.list.items) |device| {
        deviceDeinit(device, self.allocator);
    }
    self.devices_info.list.deinit(self.allocator);
    self.devices_latency_range.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn flushEvents(self: *Jack) !void {
    try self.refreshDevices();
}

pub fn waitEvents(self: *Jack) !void {
    while (!self.device_scan_queued.loadUnchecked())
        self.cond.wait(&self.mutex);

    defer self.device_scan_queued.storeUnchecked(false);
    try self.refreshDevices();
}

pub fn wakeUp(self: *Jack) void {
    _ = self;
}

const OpenStreamError = error{
    OutOfMemory,
    IncompatibleBackend,
    StreamDisconnected,
    OpeningDevice,
};

pub fn openOutstream(self: *Jack, outstream: *Outstream, device: Device) !void {
    _ = self;
    _ = outstream;
    _ = device;
    return undefined;
}

pub fn outstreamDeinit(self: *Outstream) void {
    _ = self;
}

pub fn outstreamStart(self: *Outstream) !void {
    _ = self;
}

pub fn outstreamBeginWrite(self: *Outstream, frame_count: *usize) ![]const ChannelArea {
    _ = self;
    _ = frame_count;
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
    allocator.free(self.id);
}
