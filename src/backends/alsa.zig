const std = @import("std");
const c = @cImport(@cInclude("alsa/asoundlib.h"));
const inotify_event = std.os.linux.inotify_event;

const Alsa = @This();

allocator: std.mem.Allocator,
lock: std.Thread.Mutex,
cond: std.Thread.Condition,
notify_fd: std.os.fd_t,
notify_wd: std.os.fd_t,
notify_pipe_fd: [2]std.os.fd_t,
run_thread: std.Thread,
abort: std.atomic.Atomic(bool),
pending_files: std.ArrayList([]const u8),

pub const ConnectError = std.os.INotifyInitError || std.os.INotifyAddWatchError || std.os.PipeError || std.Thread.SpawnError;

pub fn connect(allocator: std.mem.Allocator) ConnectError!Alsa {
    var result: Alsa = undefined;
    result.allocator = allocator;
    result.lock = std.Thread.Mutex{};
    result.cond = std.Thread.Condition{};
    result.notify_fd = try std.os.inotify_init1(0); // std.os.linux.IN.NONBLOCK
    result.notify_wd = try std.os.inotify_add_watch(result.notify_fd, "/dev/snd", std.os.linux.IN.CREATE | std.os.linux.IN.CLOSE_WRITE | std.os.linux.IN.DELETE);
    result.notify_pipe_fd = try std.os.pipe2(0); // std.os.linux.O.NONBLOCK
    result.abort.storeUnchecked(false);
    result.pending_files = std.ArrayList([]const u8).init(allocator);
    result.run_thread = try std.Thread.spawn(.{}, run, .{&result});
    result.run_thread.join();
    // _ = c.snd_lib_error_set_handler(@ptrCast(*const fn ([*c]const u8, c_int, [*c]const u8, c_int, [*c]const u8, ...) callconv(.C) void, &alsaErrorHandler));
    return result;
}

fn run(self: *Alsa) void {
    var buf: [4096]u8 align(@alignOf(inotify_event)) = undefined;
    var evt: *const inotify_event = undefined;
    const fds = &[_]std.os.pollfd{
        .{
            .fd = self.notify_fd,
            .events = std.os.POLL.IN,
            .revents = undefined,
        },
        .{
            .fd = self.notify_pipe_fd[0],
            .events = std.os.POLL.IN,
            .revents = undefined,
        },
    };

    while (true) {
        const poll_num = std.os.poll(fds, -1) catch {
            self.shutdown();
            return;
        };
        if (self.abort.load(.Acquire)) break;
        if (poll_num <= 0) continue;
        var got_rescan_event = false;
        if (fds[0].revents & std.os.POLL.IN > 0) {
            while (true) {
                const len = std.os.read(self.notify_fd, &buf) catch {
                    self.shutdown();
                    return;
                };
                var i: usize = 0;
                while (i < len) : (i += @sizeOf(inotify_event) + evt.len) {
                    evt = @ptrCast(*const inotify_event, @alignCast(@alignOf(inotify_event), &buf[i]));
                    if (!((evt.mask & std.os.linux.IN.CLOSE_WRITE > 0) or
                        (evt.mask & std.os.linux.IN.DELETE > 0) or
                        (evt.mask & std.os.linux.IN.CREATE > 0)))
                        continue;
                    if (evt.mask & std.os.linux.IN.ISDIR > 0)
                        continue;
                    if (evt.len < 8)
                        continue;
                    var evt_name = std.mem.sliceTo(buf[i..][0..16], 0);
                    if (std.mem.eql(u8, evt_name, "controlC"))
                        continue;
                    if (evt.mask & std.os.linux.IN.CREATE > 0) {
                        self.pending_files.append(evt_name) catch {
                            self.shutdown();
                            return;
                        };
                    }
                    if (self.pending_files.items.len > 0) {
                        // At this point ignore IN_DELETE in favor of waiting until the files
                        // opened with IN_CREATE have their IN_CLOSE_WRITE event.
                        if (evt.mask & std.os.linux.IN.CLOSE_WRITE <= 0)
                            continue;
                        for (self.pending_files.items) |pending_file, j| {
                            if (std.mem.eql(u8, pending_file, evt_name)) {
                                _ = self.pending_files.swapRemove(j);
                                if (self.pending_files.items.len == 0)
                                    got_rescan_event = true;
                                break;
                            }
                        }
                    } else if (evt.mask & std.os.linux.IN.DELETE > 0) {
                        // We are not waiting on created files to be closed, so when
                        // a delete happens we act on it.
                        got_rescan_event = true;
                    }
                }
            }
        }
    }
}

fn shutdown(self: Alsa) void {
    _ = self;
}

fn wakeupDevicePoll(self: Alsa) void {
    std.os.write(self.notify_pipe_fd[1], "a");
}
