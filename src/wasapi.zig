const std = @import("std");
const win32 = @import("win32");
const main = @import("main.zig");
const backends = @import("backends.zig");
const util = @import("util.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    devices_info: util.DevicesInfo,
    enumerator: ?*win32.IMMDeviceEnumerator,
    watcher: ?Watcher,

    const Watcher = struct {
        deviceChangeFn: main.DeviceChangeFn,
        userdata: ?*anyopaque,
        notif_client: win32.IMMNotificationClient,
    };

    pub fn init(allocator: std.mem.Allocator, options: main.Context.Options) !backends.BackendContext {
        const flags = win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE;
        var hr = win32.CoInitializeEx(null, flags);
        switch (hr) {
            win32.S_OK,
            win32.S_FALSE,
            win32.RPC_E_CHANGED_MODE,
            => {},
            win32.E_INVALIDARG => unreachable,
            win32.E_OUTOFMEMORY => return error.OutOfMemory,
            win32.E_UNEXPECTED => return error.SystemResources,
            else => unreachable,
        }

        var self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .devices_info = util.DevicesInfo.init(),
            .enumerator = blk: {
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
                    win32.E_POINTER => unreachable,
                    win32.E_NOINTERFACE => unreachable,
                    win32.CLASS_E_NOAGGREGATION => return error.SystemResources,
                    win32.REGDB_E_CLASSNOTREG => unreachable,
                    else => unreachable,
                }
                break :blk enumerator;
            },
            .watcher = if (options.deviceChangeFn) |deviceChangeFn| .{
                .deviceChangeFn = deviceChangeFn,
                .userdata = options.userdata,
                .notif_client = win32.IMMNotificationClient{
                    .vtable = &.{
                        .base = .{
                            .QueryInterface = queryInterfaceCB,
                            .AddRef = addRefCB,
                            .Release = releaseCB,
                        },
                        .OnDeviceStateChanged = onDeviceStateChangedCB,
                        .OnDeviceAdded = onDeviceAddedCB,
                        .OnDeviceRemoved = onDeviceRemovedCB,
                        .OnDefaultDeviceChanged = onDefaultDeviceChangedCB,
                        .OnPropertyValueChanged = onPropertyValueChangedCB,
                    },
                },
            } else null,
        };

        if (options.deviceChangeFn) |_| {
            hr = self.enumerator.?.RegisterEndpointNotificationCallback(&self.watcher.?.notif_client);
            switch (hr) {
                win32.S_OK => {},
                win32.E_POINTER => unreachable,
                win32.E_OUTOFMEMORY => return error.OutOfMemory,
                else => return error.SystemResources,
            }
        }

        return .{ .wasapi = self };
    }

    fn queryInterfaceCB(self: *const win32.IUnknown, riid: ?*const win32.Guid, ppv: ?*?*anyopaque) callconv(std.os.windows.WINAPI) win32.HRESULT {
        if (riid.?.eql(win32.IID_IUnknown.*) or riid.?.eql(win32.IID_IMMNotificationClient.*)) {
            ppv.?.* = @intToPtr(?*anyopaque, @ptrToInt(self));
            _ = self.AddRef();
            return win32.S_OK;
        } else {
            ppv.?.* = null;
            return win32.E_NOINTERFACE;
        }
    }

    fn addRefCB(_: *const win32.IUnknown) callconv(std.os.windows.WINAPI) u32 {
        return 1;
    }

    fn releaseCB(_: *const win32.IUnknown) callconv(std.os.windows.WINAPI) u32 {
        return 1;
    }

    fn onDeviceStateChangedCB(self: *const win32.IMMNotificationClient, _: ?[*:0]const u16, _: u32) callconv(std.os.windows.WINAPI) win32.HRESULT {
        var watcher = @fieldParentPtr(Watcher, "notif_client", self);
        watcher.deviceChangeFn(watcher.userdata);
        return win32.S_OK;
    }

    fn onDeviceAddedCB(self: *const win32.IMMNotificationClient, _: ?[*:0]const u16) callconv(std.os.windows.WINAPI) win32.HRESULT {
        var watcher = @fieldParentPtr(Watcher, "notif_client", self);
        watcher.deviceChangeFn(watcher.userdata);
        return win32.S_OK;
    }

    fn onDeviceRemovedCB(self: *const win32.IMMNotificationClient, _: ?[*:0]const u16) callconv(std.os.windows.WINAPI) win32.HRESULT {
        var watcher = @fieldParentPtr(Watcher, "notif_client", self);
        watcher.deviceChangeFn(watcher.userdata);
        return win32.S_OK;
    }

    fn onDefaultDeviceChangedCB(self: *const win32.IMMNotificationClient, _: win32.DataFlow, _: win32.Role, _: ?[*:0]const u16) callconv(std.os.windows.WINAPI) win32.HRESULT {
        var watcher = @fieldParentPtr(Watcher, "notif_client", self);
        watcher.deviceChangeFn(watcher.userdata);
        return win32.S_OK;
    }

    fn onPropertyValueChangedCB(self: *const win32.IMMNotificationClient, _: ?[*:0]const u16, _: win32.PROPERTYKEY) callconv(std.os.windows.WINAPI) win32.HRESULT {
        var watcher = @fieldParentPtr(Watcher, "notif_client", self);
        watcher.deviceChangeFn(watcher.userdata);
        return win32.S_OK;
    }

    pub fn deinit(self: *Context) void {
        if (self.watcher) |*watcher| {
            _ = self.enumerator.?.UnregisterEndpointNotificationCallback(&watcher.notif_client);
        }
        _ = self.enumerator.?.Release();
        for (self.devices_info.list.items) |d|
            freeDevice(self.allocator, d);
        self.devices_info.list.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn refresh(self: *Context) !void {
        // get default devices id
        var default_playback_device: ?*win32.IMMDevice = null;
        var hr = self.enumerator.?.GetDefaultAudioEndpoint(.render, .multimedia, &default_playback_device);
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            win32.E_INVALIDARG => unreachable,
            win32.E_OUTOFMEMORY => return error.OutOfMemory,
            // TODO: win32.E_NOTFOUND!?
            else => return error.OpeningDevice,
        }
        defer _ = default_playback_device.?.Release();

        var default_capture_device: ?*win32.IMMDevice = null;
        hr = self.enumerator.?.GetDefaultAudioEndpoint(.capture, .multimedia, &default_capture_device);
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            win32.E_INVALIDARG => unreachable,
            win32.E_OUTOFMEMORY => return error.OutOfMemory,
            // TODO: win32.E_NOTFOUND!?
            else => return error.OpeningDevice,
        }
        defer _ = default_capture_device.?.Release();

        var default_playback_id_u16: ?[*:0]u16 = undefined;
        hr = default_playback_device.?.GetId(&default_playback_id_u16);
        defer win32.CoTaskMemFree(default_playback_id_u16);
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            win32.E_OUTOFMEMORY => return error.OutOfMemory,
            else => return error.OpeningDevice,
        }
        const default_playback_id = std.unicode.utf16leToUtf8AllocZ(self.allocator, std.mem.span(default_playback_id_u16.?)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        defer self.allocator.free(default_playback_id);

        var default_capture_id_u16: ?[*:0]u16 = undefined;
        hr = default_capture_device.?.GetId(&default_capture_id_u16);
        defer win32.CoTaskMemFree(default_capture_id_u16);
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            win32.E_OUTOFMEMORY => return error.OutOfMemory,
            else => return error.OpeningDevice,
        }
        const default_capture_id = std.unicode.utf16leToUtf8AllocZ(self.allocator, std.mem.span(default_capture_id_u16.?)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        defer self.allocator.free(default_capture_id);

        // enumerate
        var collection: ?*win32.IMMDeviceCollection = null;
        hr = self.enumerator.?.EnumAudioEndpoints(
            win32.DataFlow.all,
            win32.DEVICE_STATE_ACTIVE,
            &collection,
        );
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            win32.E_INVALIDARG => unreachable,
            win32.E_OUTOFMEMORY => return error.OutOfMemory,
            else => return error.OpeningDevice,
        }
        defer _ = collection.?.Release();

        var device_count: u32 = 0;
        hr = collection.?.GetCount(&device_count);
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            else => return error.OpeningDevice,
        }

        var i: u32 = 0;
        while (i < device_count) : (i += 1) {
            var imm_device: ?*win32.IMMDevice = null;
            hr = collection.?.Item(i, &imm_device);
            switch (hr) {
                win32.S_OK => {},
                win32.E_POINTER => unreachable,
                win32.E_INVALIDARG => unreachable,
                else => return error.OpeningDevice,
            }
            defer _ = imm_device.?.Release();

            var property_store: ?*win32.IPropertyStore = null;
            var variant: win32.PROPVARIANT = undefined;
            hr = imm_device.?.OpenPropertyStore(win32.STGM_READ, &property_store);
            switch (hr) {
                win32.S_OK => {},
                win32.E_POINTER => unreachable,
                win32.E_INVALIDARG => unreachable,
                win32.E_OUTOFMEMORY => return error.OutOfMemory,
                else => return error.OpeningDevice,
            }
            defer _ = property_store.?.Release();

            hr = property_store.?.GetValue(&win32.PKEY_AudioEngine_DeviceFormat, &variant);
            switch (hr) {
                win32.S_OK, win32.INPLACE_S_TRUNCATED => {},
                else => return error.OpeningDevice,
            }
            var wf = @ptrCast(
                *win32.WAVEFORMATEXTENSIBLE,
                variant.anon.anon.anon.blob.pBlobData,
            );
            defer win32.CoTaskMemFree(variant.anon.anon.anon.blob.pBlobData);

            var device = main.Device{
                .mode = blk: {
                    var endpoint: ?*win32.IMMEndpoint = null;
                    hr = imm_device.?.QueryInterface(win32.IID_IMMEndpoint, @ptrCast(?*?*anyopaque, &endpoint));
                    switch (hr) {
                        win32.S_OK => {},
                        win32.E_POINTER => unreachable,
                        win32.E_NOINTERFACE => unreachable,
                        else => unreachable,
                    }
                    defer _ = endpoint.?.Release();

                    var dataflow: win32.DataFlow = undefined;
                    hr = endpoint.?.GetDataFlow(&dataflow);
                    switch (hr) {
                        win32.S_OK => {},
                        win32.E_POINTER => unreachable,
                        else => return error.OpeningDevice,
                    }

                    break :blk switch (dataflow) {
                        .render => .playback,
                        .capture => .capture,
                        else => unreachable,
                    };
                },
                .channels = blk: {
                    var chn_arr = std.ArrayList(main.Channel).init(self.allocator);
                    var channel: u32 = win32.SPEAKER_FRONT_LEFT;
                    while (channel < win32.SPEAKER_ALL) : (channel <<= 1) {
                        if (wf.dwChannelMask & channel != 0)
                            try chn_arr.append(.{ .id = fromWASApiChannel(channel) });
                    }
                    break :blk try chn_arr.toOwnedSlice();
                },
                .sample_rate = .{
                    .min = @intCast(u24, wf.Format.nSamplesPerSec),
                    .max = @intCast(u24, wf.Format.nSamplesPerSec),
                },
                .formats = blk: {
                    var audio_client: ?*win32.IAudioClient = null;
                    hr = imm_device.?.Activate(win32.IID_IAudioClient, win32.CLSCTX_ALL, null, @ptrCast(?*?*anyopaque, &audio_client));
                    switch (hr) {
                        win32.S_OK => {},
                        win32.E_POINTER => unreachable,
                        win32.E_INVALIDARG => unreachable,
                        win32.E_NOINTERFACE => unreachable,
                        win32.E_OUTOFMEMORY => return error.OutOfMemory,
                        win32.AUDCLNT_E_DEVICE_INVALIDATED => unreachable,
                        else => return error.OpeningDevice,
                    }
                    defer _ = audio_client.?.Release();

                    var fmt_arr = std.ArrayList(main.Format).init(self.allocator);
                    var closest_match: ?*win32.WAVEFORMATEX = null;
                    for (std.meta.tags(main.Format)) |format| {
                        setWaveFormatFormat(wf, format) catch continue;
                        if (audio_client.?.IsFormatSupported(
                            .SHARED,
                            @ptrCast(?*const win32.WAVEFORMATEX, @alignCast(@alignOf(*win32.WAVEFORMATEX), wf)),
                            &closest_match,
                        ) == win32.S_OK) {
                            try fmt_arr.append(format);
                        }
                    }

                    break :blk try fmt_arr.toOwnedSlice();
                },
                .id = blk: {
                    var id_u16: ?[*:0]u16 = undefined;
                    hr = imm_device.?.GetId(&id_u16);
                    switch (hr) {
                        win32.S_OK => {},
                        win32.E_POINTER => unreachable,
                        win32.E_OUTOFMEMORY => return error.OutOfMemory,
                        else => return error.OpeningDevice,
                    }
                    defer win32.CoTaskMemFree(id_u16);

                    break :blk std.unicode.utf16leToUtf8AllocZ(self.allocator, std.mem.span(id_u16.?)) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => unreachable,
                    };
                },
                .name = blk: {
                    hr = property_store.?.GetValue(&win32.PKEY_Device_FriendlyName, &variant);
                    switch (hr) {
                        win32.S_OK, win32.INPLACE_S_TRUNCATED => {},
                        else => return error.OpeningDevice,
                    }
                    defer win32.CoTaskMemFree(variant.anon.anon.anon.pwszVal);

                    break :blk std.unicode.utf16leToUtf8AllocZ(
                        self.allocator,
                        std.mem.span(variant.anon.anon.anon.pwszVal.?),
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => unreachable,
                    };
                },
            };

            try self.devices_info.list.append(self.allocator, device);
            if (self.devices_info.default(device.mode) == null) {
                switch (device.mode) {
                    .playback => if (std.mem.eql(u8, device.id, default_playback_id)) {
                        self.devices_info.setDefault(.playback, self.devices_info.list.items.len - 1);
                    },
                    .capture => if (std.mem.eql(u8, device.id, default_capture_id)) {
                        self.devices_info.setDefault(.capture, self.devices_info.list.items.len - 1);
                    },
                }
            }
        }
    }

    pub fn devices(self: Context) []const main.Device {
        return self.devices_info.list.items;
    }

    pub fn defaultDevice(self: Context, mode: main.Device.Mode) ?main.Device {
        return self.devices_info.default(mode);
    }

    fn fromWASApiChannel(speaker: u32) main.Channel.Id {
        return switch (speaker) {
            win32.SPEAKER_FRONT_CENTER => .front_center,
            win32.SPEAKER_FRONT_LEFT => .front_left,
            win32.SPEAKER_FRONT_RIGHT => .front_right,
            win32.SPEAKER_FRONT_LEFT_OF_CENTER => .front_left_center,
            win32.SPEAKER_FRONT_RIGHT_OF_CENTER => .front_right_center,
            win32.SPEAKER_BACK_CENTER => .back_center,
            win32.SPEAKER_SIDE_LEFT => .side_left,
            win32.SPEAKER_SIDE_RIGHT => .side_right,
            win32.SPEAKER_TOP_CENTER => .top_center,
            win32.SPEAKER_TOP_FRONT_CENTER => .top_front_center,
            win32.SPEAKER_TOP_FRONT_LEFT => .top_front_left,
            win32.SPEAKER_TOP_FRONT_RIGHT => .top_front_right,
            win32.SPEAKER_TOP_BACK_CENTER => .top_back_center,
            win32.SPEAKER_TOP_BACK_LEFT => .top_back_left,
            win32.SPEAKER_TOP_BACK_RIGHT => .top_back_right,
            win32.SPEAKER_LOW_FREQUENCY => .lfe,
            else => unreachable,
        };
    }

    fn setWaveFormatFormat(wf: *win32.WAVEFORMATEXTENSIBLE, format: main.Format) !void {
        switch (format) {
            .u8, .i16, .i24, .i24_4b, .i32 => {
                wf.SubFormat = win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM.*;
            },
            .f32, .f64 => {
                wf.SubFormat = win32.CLSID_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT.*;
            },
            .i8 => return error.Invalid,
        }
        wf.Format.wBitsPerSample = format.sizeBits();
        wf.Samples.wValidBitsPerSample = format.validSizeBits();
    }

    pub fn createPlayer(self: *Context, device: main.Device, writeFn: main.WriteFn, options: main.Player.Options) !backends.BackendPlayer {
        var imm_device: ?*win32.IMMDevice = null;
        var id_u16 = std.unicode.utf8ToUtf16LeWithNull(self.allocator, device.id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        defer self.allocator.free(id_u16);
        var hr = self.enumerator.?.GetDevice(id_u16, &imm_device);
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            win32.E_OUTOFMEMORY => return error.OutOfMemory,
            // TODO: win32.E_NOTFOUND!?
            else => return error.OpeningDevice,
        }

        var audio_client: ?*win32.IAudioClient = null;
        hr = imm_device.?.Activate(win32.IID_IAudioClient, win32.CLSCTX_ALL, null, @ptrCast(?*?*anyopaque, &audio_client));
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            win32.E_INVALIDARG => unreachable,
            win32.E_NOINTERFACE => unreachable,
            win32.E_OUTOFMEMORY => return error.OutOfMemory,
            win32.AUDCLNT_E_DEVICE_INVALIDATED => return error.OpeningDevice,
            else => return error.OpeningDevice,
        }

        const format = device.preferredFormat(options.format);
        const sample_rate = device.sample_rate.clamp(options.sample_rate);

        const wave_format = win32.WAVEFORMATEXTENSIBLE{
            .Format = .{
                .wFormatTag = win32.WAVE_FORMAT_EXTENSIBLE,
                .nChannels = @intCast(u16, device.channels.len),
                .nSamplesPerSec = sample_rate,
                .nAvgBytesPerSec = sample_rate * format.frameSize(device.channels.len),
                .nBlockAlign = format.frameSize(device.channels.len),
                .wBitsPerSample = format.sizeBits(),
                .cbSize = 0x16,
            },
            .Samples = .{
                .wValidBitsPerSample = format.validSizeBits(),
            },
            .dwChannelMask = toChannelMask(device.channels),
            .SubFormat = toSubFormat(format) catch return error.OpeningDevice,
        };

        hr = audio_client.?.Initialize(
            .SHARED,
            win32.AUDCLNT_STREAMFLAGS_NOPERSIST,
            0,
            0,
            @ptrCast(?*const win32.WAVEFORMATEX, @alignCast(@alignOf(*win32.WAVEFORMATEX), &wave_format)),
            null,
        );
        switch (hr) {
            win32.S_OK => {},
            win32.E_OUTOFMEMORY => return error.OutOfMemory,
            win32.E_POINTER => unreachable,
            win32.E_INVALIDARG => unreachable,
            win32.AUDCLNT_E_ALREADY_INITIALIZED => unreachable,
            win32.AUDCLNT_E_WRONG_ENDPOINT_TYPE => unreachable,
            win32.AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED => return error.OpeningDevice, // TODO: some libs handle this better
            win32.AUDCLNT_E_BUFFER_SIZE_ERROR => return error.OpeningDevice,
            win32.AUDCLNT_E_CPUUSAGE_EXCEEDED => return error.OpeningDevice,
            win32.AUDCLNT_E_DEVICE_INVALIDATED => return error.OpeningDevice,
            win32.AUDCLNT_E_DEVICE_IN_USE => unreachable,
            win32.AUDCLNT_E_ENDPOINT_CREATE_FAILED => return error.OpeningDevice,
            win32.AUDCLNT_E_INVALID_DEVICE_PERIOD => return error.OpeningDevice,
            win32.AUDCLNT_E_UNSUPPORTED_FORMAT => unreachable,
            win32.AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED => unreachable,
            win32.AUDCLNT_E_BUFDURATION_PERIOD_NOT_EQUAL => unreachable,
            win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return error.OpeningDevice,
            else => return error.OpeningDevice,
        }
        errdefer _ = audio_client.?.Release();

        var render_client: ?*win32.IAudioRenderClient = null;
        hr = audio_client.?.GetService(win32.IID_IAudioRenderClient, @ptrCast(?*?*anyopaque, &render_client));
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            win32.E_NOINTERFACE => unreachable,
            win32.AUDCLNT_E_NOT_INITIALIZED => unreachable,
            win32.AUDCLNT_E_WRONG_ENDPOINT_TYPE => unreachable,
            win32.AUDCLNT_E_DEVICE_INVALIDATED => return error.OpeningDevice,
            win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return error.OpeningDevice,
            else => return error.OpeningDevice,
        }

        var simple_volume: ?*win32.ISimpleAudioVolume = null;
        hr = audio_client.?.GetService(win32.IID_ISimpleAudioVolume, @ptrCast(?*?*anyopaque, &simple_volume));
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            win32.E_NOINTERFACE => unreachable,
            win32.AUDCLNT_E_NOT_INITIALIZED => unreachable,
            win32.AUDCLNT_E_WRONG_ENDPOINT_TYPE => unreachable,
            win32.AUDCLNT_E_DEVICE_INVALIDATED => return error.OpeningDevice,
            win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return error.OpeningDevice,
            else => return error.OpeningDevice,
        }

        return .{
            .wasapi = .{
                .thread = undefined,
                .mutex = .{},
                ._channels = device.channels,
                ._format = format,
                .sample_rate = sample_rate,
                .writeFn = writeFn,
                .audio_client = audio_client,
                .simple_volume = simple_volume,
                .imm_device = imm_device,
                .render_client = render_client,
                .is_paused = false,
                .vol = 1.0,
                .aborted = .{ .value = false },
            },
        };
    }

    fn toSubFormat(format: main.Format) !win32.Guid {
        return switch (format) {
            .u8 => win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM.*,
            .i16 => win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM.*,
            .i24 => win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM.*,
            .i24_4b => win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM.*,
            .i32 => win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM.*,
            .f32 => win32.CLSID_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT.*,
            .f64 => win32.CLSID_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT.*,
            else => error.Invalid,
        };
    }

    fn toChannelMask(channels: []const main.Channel) u32 {
        var mask: u32 = 0;
        for (channels) |ch| {
            mask |= switch (ch.id) {
                .front_center => win32.SPEAKER_FRONT_CENTER,
                .front_left => win32.SPEAKER_FRONT_LEFT,
                .front_right => win32.SPEAKER_FRONT_RIGHT,
                .front_left_center => win32.SPEAKER_FRONT_LEFT_OF_CENTER,
                .front_right_center => win32.SPEAKER_FRONT_RIGHT_OF_CENTER,
                .back_center => win32.SPEAKER_BACK_CENTER,
                .side_left => win32.SPEAKER_SIDE_LEFT,
                .side_right => win32.SPEAKER_SIDE_RIGHT,
                .top_center => win32.SPEAKER_TOP_CENTER,
                .top_front_center => win32.SPEAKER_TOP_FRONT_CENTER,
                .top_front_left => win32.SPEAKER_TOP_FRONT_LEFT,
                .top_front_right => win32.SPEAKER_TOP_FRONT_RIGHT,
                .top_back_center => win32.SPEAKER_TOP_BACK_CENTER,
                .top_back_left => win32.SPEAKER_TOP_BACK_LEFT,
                .top_back_right => win32.SPEAKER_TOP_BACK_RIGHT,
                .lfe => win32.SPEAKER_LOW_FREQUENCY,
            };
        }
        return mask;
    }
};

pub const Player = struct {
    thread: std.Thread,
    mutex: std.Thread.Mutex,
    _channels: []main.Channel,
    _format: main.Format,
    sample_rate: u24,
    writeFn: main.WriteFn,
    simple_volume: ?*win32.ISimpleAudioVolume,
    imm_device: ?*win32.IMMDevice,
    audio_client: ?*win32.IAudioClient,
    render_client: ?*win32.IAudioRenderClient,
    aborted: std.atomic.Atomic(bool),
    is_paused: bool,
    vol: f32,

    pub fn deinit(self: *Player) void {
        self.aborted.store(true, .Unordered);
        self.thread.join();
        _ = self.simple_volume.?.Release();
        _ = self.render_client.?.Release();
        _ = self.audio_client.?.Release();
        _ = self.imm_device.?.Release();
    }

    pub fn start(self: *Player) !void {
        self.thread = std.Thread.spawn(.{}, writeLoop, .{self}) catch |err| switch (err) {
            error.ThreadQuotaExceeded,
            error.SystemResources,
            error.LockedMemoryLimitExceeded,
            => return error.SystemResources,
            error.OutOfMemory => return error.OutOfMemory,
            error.Unexpected => unreachable,
        };
    }

    fn writeLoop(self: *Player) void {
        var parent = @fieldParentPtr(main.Player, "data", @ptrCast(*backends.BackendPlayer, self));

        var hr = self.audio_client.?.Start();
        switch (hr) {
            win32.S_OK => {},
            win32.AUDCLNT_E_NOT_INITIALIZED => unreachable,
            win32.AUDCLNT_E_NOT_STOPPED => unreachable,
            win32.AUDCLNT_E_EVENTHANDLE_NOT_SET => unreachable,
            win32.AUDCLNT_E_DEVICE_INVALIDATED => return,
            win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return,
            else => unreachable,
        }

        while (!self.aborted.load(.Unordered)) {
            var frames_buf: u32 = 0;
            hr = self.audio_client.?.GetBufferSize(&frames_buf);
            switch (hr) {
                win32.S_OK => {},
                win32.E_POINTER => unreachable,
                win32.AUDCLNT_E_NOT_INITIALIZED => unreachable,
                win32.AUDCLNT_E_DEVICE_INVALIDATED => return,
                win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return,
                else => unreachable,
            }

            var frames_used: u32 = 0;
            hr = self.audio_client.?.GetCurrentPadding(&frames_used);
            switch (hr) {
                win32.S_OK => {},
                win32.E_POINTER => unreachable,
                win32.AUDCLNT_E_NOT_INITIALIZED => unreachable,
                win32.AUDCLNT_E_DEVICE_INVALIDATED => return,
                win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return,
                else => unreachable,
            }
            const writable_frame_count = frames_buf - frames_used;
            if (writable_frame_count > 0) {
                var data: [*]u8 = undefined;
                hr = self.render_client.?.GetBuffer(writable_frame_count, @ptrCast(?*?*u8, &data));
                switch (hr) {
                    win32.S_OK => {},
                    win32.E_POINTER => unreachable,
                    win32.AUDCLNT_E_BUFFER_ERROR => unreachable,
                    win32.AUDCLNT_E_BUFFER_TOO_LARGE => unreachable,
                    win32.AUDCLNT_E_BUFFER_SIZE_ERROR => unreachable,
                    win32.AUDCLNT_E_OUT_OF_ORDER => unreachable,
                    win32.AUDCLNT_E_DEVICE_INVALIDATED => return,
                    win32.AUDCLNT_E_BUFFER_OPERATION_PENDING => continue,
                    win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return,
                    else => unreachable,
                }

                for (self.channels()) |*ch, i| {
                    ch.*.ptr = data + self.format().frameSize(i);
                }

                self.writeFn(parent, writable_frame_count);
                hr = self.render_client.?.ReleaseBuffer(writable_frame_count, 0);
                switch (hr) {
                    win32.S_OK => {},
                    win32.E_INVALIDARG => unreachable,
                    win32.AUDCLNT_E_INVALID_SIZE => unreachable,
                    win32.AUDCLNT_E_BUFFER_SIZE_ERROR => unreachable,
                    win32.AUDCLNT_E_OUT_OF_ORDER => unreachable,
                    win32.AUDCLNT_E_DEVICE_INVALIDATED => return,
                    win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return,
                    else => unreachable,
                }
            }
        }
    }

    pub fn play(self: *Player) !void {
        if (self.paused()) {
            const hr = self.audio_client.?.Start();
            switch (hr) {
                win32.S_OK => {},
                win32.AUDCLNT_E_NOT_INITIALIZED => unreachable,
                win32.AUDCLNT_E_NOT_STOPPED => unreachable,
                win32.AUDCLNT_E_EVENTHANDLE_NOT_SET => unreachable,
                win32.AUDCLNT_E_DEVICE_INVALIDATED => return error.CannotPlay,
                win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return error.CannotPlay,
                else => unreachable,
            }
            self.is_paused = false;
        }
    }

    pub fn pause(self: *Player) !void {
        if (!self.paused()) {
            const hr = self.audio_client.?.Stop();
            switch (hr) {
                win32.S_OK => {},
                win32.AUDCLNT_E_DEVICE_INVALIDATED => return error.CannotPause,
                win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return error.CannotPause,
                else => unreachable,
            }
            self.is_paused = true;
        }
    }

    pub fn paused(self: Player) bool {
        return self.is_paused;
    }

    pub fn setVolume(self: *Player, vol: f32) !void {
        const hr = self.simple_volume.?.SetMasterVolume(vol, null);
        switch (hr) {
            win32.S_OK => {},
            win32.E_INVALIDARG => unreachable,
            win32.AUDCLNT_E_DEVICE_INVALIDATED => return error.CannotSetVolume,
            win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return error.CannotSetVolume,
            else => return error.CannotSetVolume,
        }
    }

    pub fn volume(self: Player) !f32 {
        var vol: f32 = 0;
        const hr = self.simple_volume.?.GetMasterVolume(&vol);
        switch (hr) {
            win32.S_OK => {},
            win32.E_POINTER => unreachable,
            win32.AUDCLNT_E_DEVICE_INVALIDATED => return error.CannotGetVolume,
            win32.AUDCLNT_E_SERVICE_NOT_RUNNING => return error.CannotGetVolume,
            else => return error.CannotGetVolume,
        }
        return vol;
    }

    pub fn writeRaw(self: Player, channel: main.Channel, frame: usize, sample: anytype) void {
        var ptr = channel.ptr + frame * self.format().frameSize(self.channels().len);
        std.mem.bytesAsValue(@TypeOf(sample), ptr[0..@sizeOf(@TypeOf(sample))]).* = sample;
    }

    pub fn channels(self: Player) []main.Channel {
        return self._channels;
    }

    pub fn format(self: Player) main.Format {
        return self._format;
    }

    pub fn sampleRate(self: Player) u24 {
        return self.sample_rate;
    }
};

pub fn freeDevice(allocator: std.mem.Allocator, self: main.Device) void {
    allocator.free(self.id);
    allocator.free(self.name);
    allocator.free(self.formats);
    allocator.free(self.channels);
}
