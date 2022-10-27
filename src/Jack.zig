const std = @import("std");
const c = @cImport(@cInclude("jack/jack.h"));
const Device = @import("main.zig").Device;
const Outstream = @import("main.zig").Outstream;
const ChannelArea = @import("main.zig").ChannelArea;

const Jack = @This();

allocator: std.mem.Allocator,
client: *c.jack_client_t,
mutex: std.Thread.Mutex,
cond: std.Thread.Condition,
refresh_devices: std.atomic.Atomic(bool),
sample_rate: u32,
period_size: u32,

const DeviceQueryError = error{
    OutOfMemory,
    IncompatibleBackend,
    InvalidFormat,
    InvalidChannelPos,
};

const StreamError = error{
    StreamDisconnected,
};

const ConnectError = error{
    OutOfMemory,
    Disconnected,
    InvalidServer,
};

pub fn connect(allocator: std.mem.Allocator) ConnectError!*Jack {
    _ = allocator;
    return undefined;
}

pub fn deinit(self: *Jack) void {
    _ = self;
}

const RefreshDevicesError = error{
    OutOfMemory,
    Interrupted,
    IncompatibleBackend,
    InvalidFormat,
    InvalidChannelPos,
};

pub fn flushEvents(self: *Jack) RefreshDevicesError!void {
    _ = self;
}

pub fn waitEvents(self: *Jack) RefreshDevicesError!void {
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

pub fn outstreamStart(self: *Outstream) StreamError!void {
    _ = self;
}

pub fn outstreamBeginWrite(self: *Outstream, frame_count: *usize) StreamError![]const ChannelArea {
    _ = self;
    _ = frame_count;
    return undefined;
}

pub fn outstreamEndWrite(self: *Outstream) StreamError!void {
    _ = self;
}

pub fn outstreamClearBuffer(self: *Outstream) void {
    _ = self;
}

pub fn outstreamPausePlay(self: *Outstream, pause: bool) StreamError!void {
    _ = self;
    _ = pause;
}

pub fn outstreamGetLatency(self: *Outstream) StreamError!f64 {
    _ = self;
}

pub fn outstreamSetVolume(self: *Outstream, volume: f64) StreamError!void {
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
