const std = @import("std");
const c = @cImport(@cInclude("pulse/pulseaudio.h"));
const DevicesInfo = @import("../main.zig").DevicesInfo;

const PulseAudio = @This();

allocator: std.mem.Allocator,
device_scan_queued: bool,
main_loop: *c.pa_threaded_mainloop,
props: *c.pa_proplist,
pulse_context: *c.pa_context,
emitted_shutdown_event: bool,
context_state: c.pa_context_state_t,
devices_info: ?DevicesInfo,

pub const Event = union(enum) {
    devices_changed: void,
};
pub const Options = struct {};
pub const ConnectionError = error{ OutOfMemory, Disconnected, InitAudioBackend, Interrupted };

pub fn connect(allocator: std.mem.Allocator, options: Options) ConnectionError!PulseAudio {
    _ = options;
    var self = PulseAudio{
        .allocator = allocator,
        .device_scan_queued = true,
        .main_loop = undefined,
        .props = undefined,
        .pulse_context = undefined,
        .emitted_shutdown_event = false,
        .devices_info = null,
        .context_state = c.PA_CONTEXT_UNCONNECTED,
    };
    self.main_loop = c.pa_threaded_mainloop_new() orelse return error.OutOfMemory;
    errdefer c.pa_threaded_mainloop_free(self.main_loop);

    var main_loop_api = c.pa_threaded_mainloop_get_api(self.main_loop);

    self.props = c.pa_proplist_new() orelse return error.OutOfMemory;
    errdefer c.pa_proplist_free(self.props);

    self.pulse_context = c.pa_context_new_with_proplist(main_loop_api, "SoundIO", self.props) orelse return error.OutOfMemory;
    errdefer c.pa_context_unref(self.pulse_context);

    c.pa_context_set_state_callback(self.pulse_context, contextStateCallback, &self);
    c.pa_context_set_subscribe_callback(self.pulse_context, subscribeCallback, &self);

    if (c.pa_context_connect(self.pulse_context, null, 0, null) != 0) return error.InitAudioBackend;
    errdefer c.pa_context_disconnect(self.pulse_context);

    if (c.pa_threaded_mainloop_start(self.main_loop) > 0)
        return error.OutOfMemory;

    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);

    while (true) {
        switch (self.context_state) {
            // The context hasn't been connected yet.
            c.PA_CONTEXT_UNCONNECTED,
            // A connection is being established.
            c.PA_CONTEXT_CONNECTING,
            // The client is authorizing itself to the daemon.
            c.PA_CONTEXT_AUTHORIZING,
            // The client is passing its application name to the daemon.
            c.PA_CONTEXT_SETTING_NAME,
            // The connection was terminated cleanly.
            c.PA_CONTEXT_TERMINATED,
            => c.pa_threaded_mainloop_wait(self.main_loop),
            // The connection is established, the context is ready to execute operations.
            c.PA_CONTEXT_READY => break,
            // The connection failed or was disconnected.
            c.PA_CONTEXT_FAILED => return error.Disconnected,
            else => unreachable,
        }
    }

    // subscribe to events
    const events = c.PA_SUBSCRIPTION_MASK_SINK | c.PA_SUBSCRIPTION_MASK_SOURCE | c.PA_SUBSCRIPTION_MASK_SERVER;
    try self.performOperation(c.pa_context_subscribe(self.pulse_context, events, null, &self));

    return self;
}

fn performOperation(self: PulseAudio, op: ?*c.pa_operation) error{ OutOfMemory, Interrupted }!void {
    if (op == null) return error.OutOfMemory;
    while (true) {
        switch (c.pa_operation_get_state(op)) {
            c.PA_OPERATION_RUNNING => c.pa_threaded_mainloop_wait(self.main_loop),
            c.PA_OPERATION_DONE => return c.pa_operation_unref(op),
            c.PA_OPERATION_CANCELLED => {
                c.pa_operation_unref(op);
                return error.Interrupted;
            },
            else => unreachable,
        }
    }
}

fn subscribeCallback(_: ?*c.pa_context, _: c.pa_subscription_event_type_t, _: u32, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    self.device_scan_queued = true;
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

fn contextStateCallback(context: ?*c.pa_context, userdata: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*PulseAudio, @alignCast(@alignOf(*PulseAudio), userdata.?));
    self.context_state = c.pa_context_get_state(context);
    c.pa_threaded_mainloop_signal(self.main_loop, 0);
}

pub fn flushWaitEvents(self: *PulseAudio, wait: bool) !?Event {
    c.pa_threaded_mainloop_lock(self.main_loop);
    defer c.pa_threaded_mainloop_unlock(self.main_loop);
    // std.debug.assert(!self.emitted_shutdown_event);
    errdefer self.emitted_shutdown_event = true;
    while (wait and !self.device_scan_queued)
        c.pa_threaded_mainloop_wait(self.main_loop);
    self.device_scan_queued = false;
    try self.refreshDevices();
    return if (wait) .{ .devices_changed = {} } else null;
}

pub fn refreshDevices(self: PulseAudio) error{Disconnected}!void {
    _ = self;
    // const list_sink_op = c.pa_context_get_sink_info_list(self.pulse_context, sink_info_callback, &self);
    // const list_source_op = c.pa_context_get_source_info_list(self.pulse_context, source_info_callback, &self);
    // const server_info_op = c.pa_context_get_server_info(self.pulse_context, server_info_callback, &self);

    // try self.performOperation(list_sink_op);
    // try self.performOperation(list_source_op);
    // try self.performOperation(server_info_op);

    // if (self.device_query_err)
    //     return self.device_query_err;

    // // based on the default sink name, figure out the default output index
    // // if the name doesn't match just pick the first one. if there are no
    // // devices then we need to set it to -1.
    // self.current_devices_info.default_output_index = -1;
    // self.current_devices_info.default_input_index = -1;

    // if (self.current_devices_info.input_devices.length > 0) {
    //     self.current_devices_info.default_input_index = 0;
    //     var i: usize =0;
    //     while (i < self.current_devices_info.input_devices.length) :(i +=1) {
    //         struct SoundIoDevice *device = SoundIoListDevicePtr_val_at(
    //                 &self.current_devices_info.input_devices, i);

    //         assert(device.aim == SoundIoDeviceAimInput);
    //         if (strcmp(device.id, self.default_source_name) == 0) {
    //             self.current_devices_info.default_input_index = i;
    //         }
    //     }
    // }

    // if (self.current_devices_info.output_devices.length > 0) {
    //     self.current_devices_info.default_output_index = 0;
    //     for (int i = 0; i < self.current_devices_info.output_devices.length; i += 1) {
    //         struct SoundIoDevice *device = SoundIoListDevicePtr_val_at(
    //                 &self.current_devices_info.output_devices, i);

    //         assert(device.aim == SoundIoDeviceAimOutput);
    //         if (strcmp(device.id, self.default_sink_name) == 0) {
    //             self.current_devices_info.default_output_index = i;
    //         }
    //     }
    // }

    // soundio_destroy_devices_info(self.ready_devices_info);
    // self.ready_devices_info = self.current_devices_info;
    // self.current_devices_info = NULL;
    // pa_threaded_mainloop_signal(self.main_loop, 0);
    // soundio.on_events_signal(soundio);

    return error.Disconnected;
}

pub fn deinit(self: *PulseAudio) void {
    self.lock.lock();
    defer self.lock.unlock();
}
