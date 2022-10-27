const std = @import("std");
const c = @cImport(@cInclude("jack/jack.h"));
const Device = @import("main.zig").Device;
const Outstream = @import("main.zig").Outstream;
const ChannelArea = @import("main.zig").ChannelArea;
const ConnectOptions = @import("main.zig").ConnectOptions;

const Jack = @This();

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex,
cond: std.Thread.Condition,
options: ConnectOptions,
client: *c.jack_client_t,
device_scan_queued: std.atomic.Atomic(bool),
sample_rate: u32,
period_size: u32,

pub fn connect(allocator: std.mem.Allocator, options: ConnectOptions) !*Jack {
    c.jack_set_error_function(emptyMsgCallback);
    c.jack_set_info_function(emptyMsgCallback);

    var status: c.jack_status_t = 0;
    var self = try allocator.create(Jack);
    self.* = .{
        .allocator = allocator,
        .mutex = std.Thread.Mutex{},
        .cond = std.Thread.Condition{},
        .options = options,
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
    };

    if (c.jack_set_buffer_size_callback(self.client, bufferSizeCallback, self) != 0 or
        c.jack_set_sample_rate_callback(self.client, sampleRateCallback, self) != 0 or
        c.jack_set_port_registration_callback(self.client, portRegistrationCallback, self) != 0 or
        c.jack_set_port_rename_callback(self.client, portRenameCalllback, self) != 0)
        return error.InitAudioBackend;

    if (options.shutdownFn != null)
        c.jack_on_shutdown(self.client, shutdownCallback, &self.options);

    return self;
}

fn emptyMsgCallback(_: [*c]const u8) callconv(.C) void {}

fn bufferSizeCallback(nframes: c.jack_nframes_t, arg: ?*anyopaque) callconv(.C) c_int {
    var self = @ptrCast(*Jack, @alignCast(@alignOf(*Jack), arg.?));
    self.period_size = nframes;
    notifyDevicesChange(self);
    return 0;
}

fn sampleRateCallback(nframes: c.jack_nframes_t, arg: ?*anyopaque) callconv(.C) c_int {
    var self = @ptrCast(*Jack, @alignCast(@alignOf(*Jack), arg.?));
    self.sample_rate = nframes;
    notifyDevicesChange(self);
    return 0;
}

fn portRegistrationCallback(_: c.jack_port_id_t, _: c_int, arg: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*Jack, @alignCast(@alignOf(*Jack), arg.?));
    notifyDevicesChange(self);
}

fn portRenameCalllback(_: c.jack_port_id_t, _: [*c]const u8, _: [*c]const u8, arg: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*Jack, @alignCast(@alignOf(*Jack), arg.?));
    notifyDevicesChange(self);
}

fn notifyDevicesChange(self: *Jack) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.device_scan_queued.storeUnchecked(true);
    self.cond.signal();
}

fn shutdownCallback(arg: ?*anyopaque) callconv(.C) void {
    var options = @ptrCast(*ConnectOptions, @alignCast(@alignOf(*ConnectOptions), arg.?));
    options.shutdownFn.?(options.userdata);
}

pub fn deinit(self: *Jack) void {
    self.allocator.destroy(self);
}

pub fn flushEvents(self: *Jack) !void {
    _ = self;
}

pub fn waitEvents(self: *Jack) !void {
    _ = self;
}

pub fn wakeUp(self: *Jack) void {
    _ = self;
}

pub fn getDevice(self: Jack, aim: Device.Aim, index: ?usize) Device {
    _ = self;
    _ = aim;
    _ = index;
    return undefined;
}

pub fn devicesList(self: Jack, aim: Device.Aim) []const Device {
    _ = self;
    _ = aim;
    return undefined;
}

const OpenStreamError = error{
    OutOfMemory,
    Interrupted,
    IncompatibleBackend,
    StreamDisconnected,
    OpeningDevice,
};

pub fn outstreamOpen(self: *Jack, outstream: *Outstream, device: Device) !void {
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
    allocator.free(self.name);
}
