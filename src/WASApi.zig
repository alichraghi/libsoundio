const std = @import("std");
const win32 = struct {
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").devices.function_discovery;
    usingnamespace @import("win32").media.audio;
    usingnamespace @import("win32").media.audio.direct_music;
    usingnamespace @import("win32").media.kernel_streaming;
    usingnamespace @import("win32").media.multimedia;
    usingnamespace @import("win32").storage.structured_storage;
    usingnamespace @import("win32").system.com;
    usingnamespace @import("win32").system.com.structured_storage;
    usingnamespace @import("win32").ui.shell.properties_system;
    usingnamespace @import("win32").zig;
};
const util = @import("util.zig");
const Channel = @import("main.zig").Channel;
const ChannelId = @import("main.zig").ChannelId;
const ConnectOptions = @import("main.zig").ConnectOptions;
const Device = @import("main.zig").Device;
const DevicesInfo = @import("main.zig").DevicesInfo;
const Format = @import("main.zig").Format;
const Player = @import("main.zig").Player;
const default_latency = @import("main.zig").default_latency;
const min_sample_rate = @import("main.zig").min_sample_rate;
const max_sample_rate = @import("main.zig").max_sample_rate;

const WASApi = @This();

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex,
cond: std.Thread.Condition,
scan_queued: std.atomic.Atomic(bool),
devices_info: DevicesInfo,

pub fn connect(allocator: std.mem.Allocator, options: ConnectOptions) !*WASApi {
    _ = options;

    _ = win32.COINIT.initFlags(.{ .APARTMENTTHREADED = 1, .DISABLE_OLE1DDE = 1 });
    if (win32.FAILED(win32.CoInitialize(null)))
        unreachable;

    var self = try allocator.create(WASApi);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .mutex = .{},
        .cond = .{},
        .scan_queued = .{ .value = false },
        .devices_info = DevicesInfo.init(),
    };
    return self;
}

pub fn disconnect(self: *WASApi) void {
    self.devices_info.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn flushEvents(self: *WASApi) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.scan_queued.store(false, .Release);
    try self.refreshDevices();
}

pub fn waitEvents(self: *WASApi) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (!self.scan_queued.load(.Acquire))
        self.cond.wait(&self.mutex);

    self.scan_queued.store(false, .Release);
    try self.refreshDevices();
}

fn refreshDevices(self: *WASApi) !void {
    var hr: win32.HRESULT = win32.SUCCESS;

    var enumerator: ?*win32.IMMDeviceEnumerator = null;
    hr = win32.CoCreateInstance(
        win32.CLSID_MMDeviceEnumerator,
        null,
        win32.CLSCTX_ALL,
        win32.IID_IMMDeviceEnumerator,
        @ptrCast(*?*anyopaque, &enumerator),
    );
    switch (hr) {
        win32.S_OK => {},
        win32.CLASS_E_NOAGGREGATION => return error.SystemResources,
        win32.REGDB_E_CLASSNOTREG => unreachable,
        win32.E_NOINTERFACE => unreachable,
        win32.E_POINTER => unreachable,
        else => unreachable,
    }
    defer _ = enumerator.?.IUnknown_Release();

    var collection: ?*win32.IMMDeviceCollection = null;
    hr = enumerator.?.IMMDeviceEnumerator_EnumAudioEndpoints(
        win32.EDataFlow.eAll,
        win32.DEVICE_STATE_ACTIVE,
        &collection,
    );
    switch (hr) {
        win32.S_OK => {},
        win32.E_OUTOFMEMORY => return error.OutOfMemory,
        win32.E_POINTER => unreachable,
        win32.E_INVALIDARG => unreachable,
        else => return error.OpeningDevice,
    }
    defer _ = collection.?.IUnknown_Release();

    var device_count: u32 = 0;
    hr = collection.?.IMMDeviceCollection_GetCount(&device_count);
    switch (hr) {
        win32.S_OK => {},
        win32.E_POINTER => unreachable,
        else => return error.OpeningDevice,
    }

    var i: u32 = 0;
    while (i < device_count) : (i += 1) {
        var imm_device: ?*win32.IMMDevice = null;
        hr = collection.?.IMMDeviceCollection_Item(i, &imm_device);
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            win32.E_INVALIDARG => unreachable,
            else => return error.OpeningDevice,
        }
        defer _ = imm_device.?.IUnknown_Release();

        var property_store: ?*win32.IPropertyStore = null;
        var variant: win32.PROPVARIANT = undefined;
        hr = imm_device.?.IMMDevice_OpenPropertyStore(win32.STGM_READ, &property_store);
        switch (hr) {
            win32.S_OK => {},
            win32.E_OUTOFMEMORY => return error.OutOfMemory,
            win32.E_POINTER => unreachable,
            win32.E_INVALIDARG => unreachable,
            else => return error.OpeningDevice,
        }
        defer _ = property_store.?.IUnknown_Release();

        hr = property_store.?.IPropertyStore_GetValue(&win32.PKEY_AudioEngine_DeviceFormat, &variant);
        switch (hr) {
            win32.S_OK, win32.INPLACE_S_TRUNCATED => {},
            else => return error.OpeningDevice,
        }
        var wf = @ptrCast(
            *WAVEFORMATEXTENSIBLE,
            variant.Anonymous.Anonymous.Anonymous.blob.pBlobData,
        );
        defer win32.CoTaskMemFree(variant.Anonymous.Anonymous.Anonymous.blob.pBlobData);

        var device = Device{
            .aim = blk: {
                var endpoint: ?*win32.IMMEndpoint = null;
                hr = imm_device.?.IUnknown_QueryInterface(win32.IID_IMMEndpoint, @ptrCast(?*?*anyopaque, &endpoint));
                switch (hr) {
                    win32.S_OK => {},
                    win32.E_NOINTERFACE => unreachable,
                    win32.E_POINTER => unreachable,
                    else => unreachable,
                }

                var dataflow: win32.EDataFlow = undefined;
                hr = endpoint.?.IMMEndpoint_GetDataFlow(&dataflow);
                switch (hr) {
                    win32.S_OK => {},
                    win32.E_POINTER => unreachable,
                    else => return error.OpeningDevice,
                }

                break :blk switch (dataflow) {
                    .eRender => .playback,
                    .eCapture => .capture,
                    else => unreachable,
                };
            },
            .channels = blk: {
                var chn_arr = std.ArrayList(Channel).init(self.allocator);
                var channel = win32.SPEAKER_FRONT_LEFT;
                while (channel < win32.SPEAKER_RESERVED) : (channel <<= 1) {
                    if (util.hasFlag(wf.dwChannelMask, channel))
                        try chn_arr.append(.{ .id = fromWASApiChannel(channel) });
                }
                break :blk chn_arr.toOwnedSlice();
            },
            .rate_range = .{
                .min = wf.Format.nSamplesPerSec,
                .max = wf.Format.nSamplesPerSec,
            },
            .formats = blk: {
                var audio_client: ?*win32.IAudioClient = null;
                hr = imm_device.?.IMMDevice_Activate(win32.IID_IAudioClient, @enumToInt(win32.CLSCTX_ALL), null, @ptrCast(?*?*anyopaque, &audio_client));
                switch (hr) {
                    win32.S_OK => {},
                    win32.E_OUTOFMEMORY => return error.OutOfMemory,
                    win32.E_NOINTERFACE => unreachable,
                    win32.E_POINTER => unreachable,
                    win32.E_INVALIDARG => unreachable,
                    win32.AUDCLNT_E_DEVICE_INVALIDATED => unreachable,
                    else => return error.OpeningDevice,
                }

                var fmt_arr = std.ArrayList(Format).init(self.allocator);
                var closest_match: ?*win32.WAVEFORMATEX = null;
                for (std.meta.tags(Format)) |format| {
                    setWaveFormatFormat(wf, format) catch continue;
                    if (audio_client.?.IAudioClient_IsFormatSupported(
                        .SHARED,
                        @ptrCast(?*const win32.WAVEFORMATEX, @alignCast(@alignOf(*win32.WAVEFORMATEX), wf)),
                        &closest_match,
                    ) == win32.S_OK) {
                        try fmt_arr.append(format);
                    }
                }

                break :blk fmt_arr.toOwnedSlice();
            },
            .id = blk: {
                var id_u16: ?[*:0]u16 = undefined;
                hr = imm_device.?.IMMDevice_GetId(&id_u16);
                switch (hr) {
                    win32.S_OK => {},
                    win32.E_OUTOFMEMORY => return error.OutOfMemory,
                    win32.E_POINTER => unreachable,
                    else => return error.OpeningDevice,
                }

                break :blk std.unicode.utf16leToUtf8AllocZ(self.allocator, std.mem.span(id_u16.?)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                };
            },
            .name = blk: {
                hr = property_store.?.IPropertyStore_GetValue(&win32.PKEY_Device_FriendlyName, &variant);
                switch (hr) {
                    win32.S_OK, win32.INPLACE_S_TRUNCATED => {},
                    else => return error.OpeningDevice,
                }
                defer win32.CoTaskMemFree(variant.Anonymous.Anonymous.Anonymous.pwszVal);

                break :blk std.unicode.utf16leToUtf8AllocZ(
                    self.allocator,
                    std.mem.span(variant.Anonymous.Anonymous.Anonymous.pwszVal.?),
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                };
            },
        };

        for (device.channels) |ch| {
            std.debug.print("{s}\n", .{@tagName(ch.id)});
        }
        for (device.formats) |ch| {
            std.debug.print("{s}\n", .{@tagName(ch)});
        }
        std.debug.print("\n", .{});

        try self.devices_info.list.append(self.allocator, device);
    }
}

fn fromWASApiChannel(speaker: u32) ChannelId {
    return switch (speaker) {
        win32.SPEAKER_FRONT_LEFT => .front_left,
        win32.SPEAKER_FRONT_RIGHT => .front_right,
        win32.SPEAKER_FRONT_CENTER => .front_center,
        win32.SPEAKER_LOW_FREQUENCY => .lfe,
        win32.SPEAKER_BACK_LEFT => .back_left,
        win32.SPEAKER_BACK_RIGHT => .back_right,
        win32.SPEAKER_FRONT_LEFT_OF_CENTER => .front_left_center,
        win32.SPEAKER_FRONT_RIGHT_OF_CENTER => .front_right_center,
        win32.SPEAKER_BACK_CENTER => .back_center,
        win32.SPEAKER_SIDE_LEFT => .side_left,
        win32.SPEAKER_SIDE_RIGHT => .side_right,
        win32.SPEAKER_TOP_CENTER => .top_center,
        win32.SPEAKER_TOP_FRONT_LEFT => .top_front_left,
        win32.SPEAKER_TOP_FRONT_CENTER => .top_front_center,
        win32.SPEAKER_TOP_FRONT_RIGHT => .top_front_right,
        win32.SPEAKER_TOP_BACK_LEFT => .top_back_left,
        win32.SPEAKER_TOP_BACK_CENTER => .top_back_center,
        win32.SPEAKER_TOP_BACK_RIGHT => .top_back_right,
        else => unreachable,
    };
}

fn setWaveFormatFormat(wf: *WAVEFORMATEXTENSIBLE, format: Format) !void {
    switch (format) {
        .u8 => {
            wf.SubFormat = win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM.*;
            wf.Format.wBitsPerSample = 8;
            wf.Samples.wValidBitsPerSample = 8;
        },
        .i16 => {
            wf.SubFormat = win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM.*;
            wf.Format.wBitsPerSample = 16;
            wf.Samples.wValidBitsPerSample = 16;
        },
        .i24 => {
            wf.SubFormat = win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM.*;
            wf.Format.wBitsPerSample = 24;
            wf.Samples.wValidBitsPerSample = 24;
        },
        .i24_3b => {
            wf.SubFormat = win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM.*;
            wf.Format.wBitsPerSample = 32;
            wf.Samples.wValidBitsPerSample = 24;
        },
        .i32 => {
            wf.SubFormat = win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM.*;
            wf.Format.wBitsPerSample = 32;
            wf.Samples.wValidBitsPerSample = 32;
        },
        .f32 => {
            wf.SubFormat = win32.CLSID_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT.*;
            wf.Format.wBitsPerSample = 32;
            wf.Samples.wValidBitsPerSample = 32;
        },
        .f64 => {
            wf.SubFormat = win32.CLSID_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT.*;
            wf.Format.wBitsPerSample = 64;
            wf.Samples.wValidBitsPerSample = 64;
        },
        else => return error.InvalidFormat,
    }
}

pub fn wakeUp(self: *WASApi) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.scan_queued.store(true, .Release);
    self.cond.signal();
}

pub const PlayerData = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    aborted: std.atomic.Atomic(bool),
    paused: std.atomic.Atomic(bool),
    volume: f32,
};

pub fn openPlayer(self: *WASApi, player: *Player, device: Device) !void {
    _ = device;
    player.backend_data = .{
        .WASApi = .{
            .allocator = self.allocator,
            .mutex = .{},
            .cond = .{},
            .aborted = .{ .value = false },
            .paused = .{ .value = false },
            .volume = 1.0,
            .thread = undefined,
        },
    };
}

pub fn playerDeinit(self: *Player) void {
    var bd = &self.backend_data.WASApi;

    bd.aborted.store(true, .Unordered);
    bd.cond.signal();
    bd.thread.join();
}

pub fn playerStart(self: *Player) !void {
    var bd = &self.backend_data.WASApi;

    bd.thread = std.Thread.spawn(.{}, playerLoop, .{self}) catch |err| switch (err) {
        error.ThreadQuotaExceeded,
        error.SystemResources,
        error.LockedMemoryLimitExceeded,
        => return error.SystemResources,
        error.OutOfMemory => return error.OutOfMemory,
        error.Unexpected => unreachable,
    };
}

fn playerLoop(self: *Player) void {
    var bd = &self.backend_data.WASApi;

    const buf_size = @as(u11, 1024);
    const bps = buf_size / self.bytesPerSample();
    var buf: [1024]u8 = undefined;

    self.device.channels[0].ptr = &buf;

    while (!bd.aborted.load(.Unordered)) {
        bd.mutex.lock();
        defer bd.mutex.unlock();
        bd.cond.timedWait(&bd.mutex, default_latency * std.time.ns_per_us) catch {};
        if (bd.paused.load(.Unordered))
            continue;
        self.writeFn(self, {}, bps);
    }
}

pub fn playerPlay(self: *Player) !void {
    var bd = &self.backend_data.WASApi;
    bd.mutex.lock();
    defer bd.mutex.unlock();
    bd.paused.store(false, .Unordered);
    bd.cond.signal();
}

pub fn playerPause(self: *Player) !void {
    const bd = &self.backend_data.WASApi;
    bd.mutex.lock();
    defer bd.mutex.unlock();
    bd.paused.store(true, .Unordered);
}

pub fn playerPaused(self: *Player) bool {
    const bd = &self.backend_data.WASApi;
    bd.mutex.lock();
    defer bd.mutex.unlock();
    return bd.paused.load(.Unordered);
}

pub fn playerSetVolume(self: *Player, volume: f32) !void {
    var bd = &self.backend_data.WASApi;
    bd.volume = volume;
}

pub fn playerVolume(self: *Player) !f32 {
    var bd = &self.backend_data.WASApi;

    return bd.volume;
}

pub fn deviceDeinit(self: Device, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
}

pub const WAVEFORMATEX = extern struct {
    wFormatTag: u16 align(1),
    nChannels: u16 align(1),
    nSamplesPerSec: u32 align(1),
    nAvgBytesPerSec: u32 align(1),
    nBlockAlign: u16 align(1),
    wBitsPerSample: u16 align(1),
    cbSize: u16 align(1),
};

pub const WAVEFORMATEXTENSIBLE = extern struct {
    Format: WAVEFORMATEX align(1),
    Samples: packed union {
        wValidBitsPerSample: u16 align(1),
        wSamplesPerBlock: u16 align(1),
        wReserved: u16 align(1),
    },
    dwChannelMask: u32 align(1),
    SubFormat: win32.Guid align(1),
};
