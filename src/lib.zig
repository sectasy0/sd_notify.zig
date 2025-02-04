const std = @import("std");

const systemd_dir: []const u8 = "/run/systemd/system";

// Creates a Notifier object in unmanaged mode.
// This mode is useful when you want to manually control the notifications.
pub fn createNotifierUnmanaged(allocator: std.mem.Allocator) !Notifier {
    return _createNotifier(allocator, false);
}

// Creates a Notifier object in managed mode.
// This mode is useful when you don't want to handle when it's time to send the watchdog notification.
pub fn createNotifier(allocator: std.mem.Allocator) !Notifier {
    return _createNotifier(allocator, true);
}

// This function checks if system was booted with systemd and if so, creates a Notifier object
// Otherwise, it creates a Notifier object that does nothing.
// It's simple as hell it just checks whatever `/run/systemd/system` exists, if it does, it means systemd is running.
// See link below for more information.
// https://www.freedesktop.org/software/systemd/man/latest/sd_booted.html
fn _createNotifier(allocator: std.mem.Allocator, managed: bool) !Notifier {
    const stat = std.fs.cwd().statFile(systemd_dir) catch {
        return Notifier.init(no_notify, null);
    };
    return switch (stat.kind) {
        .directory => {
            var env_map: std.process.EnvMap = try std.process.getEnvMap(allocator);
            defer env_map.deinit();

            const socket_path: []const u8 = env_map.get("NOTIFY_SOCKET") orelse {
                return error.NoSocketPath;
            };

            const sockfd: std.posix.socket_t = connectUnixSocket(socket_path) catch {
                return error.SocketConnectFailed;
            };

            var notifier = Notifier.init(notify, sockfd);

            if (managed) {
                const interval_s: ?[]const u8 = env_map.get("WATCHDOG_USEC");
                var interval: u32 = 0;
                if (interval_s) |value| {
                    interval = try std.fmt.parseInt(u32, value, 10);
                } else {
                    return error.NoInterval;
                }

                const watchdog_pid_s: ?[]const u8 = env_map.get("WATCHDOG_PID");
                var watchdog_pid: u32 = 0;
                if (watchdog_pid_s) |value| {
                    watchdog_pid = try std.fmt.parseInt(u32, value, 10);
                } else {
                    return error.NoWatchdogPid;
                }

                notifier.metadata = .{
                    .interval = interval / 1_000_000, // convert microseconds to seconds
                    .watchdog_pid = watchdog_pid,
                    .last_check = std.time.timestamp(),
                };
            }

            return notifier;
        },
        else => Notifier.init(no_notify, null),
    };
}

pub const Notifier = struct {
    socketfd: ?std.posix.socket_t,
    notifyFn: notifyFnType,

    // Struct for storing watchdog metadata, including check interval, watchdog PID,
    // and last check timestamp. Used primarily to enforce correct check intervals in managed mode.
    // it its null then it's not in managed mode.
    metadata: ?struct { interval: u64, watchdog_pid: u32, last_check: i64 } = null,

    const notifyFnType = *const fn (socket: std.posix.socket_t, bytes: []const u8) anyerror!void;

    pub const State = enum {
        Ready,
        Reloading,
        Stopping,
        Status,
        Errno,
        MainPid,
        Watchdog,
        FdStore,

        pub fn _raw(self: State, args: anytype) ![]const u8 {
            var buffer: [1024]u8 = undefined;

            return switch (self) {
                .Ready => "READY=1\n",
                .Reloading => "RELOADING=1\n",
                .Stopping => "STOPPING=1\n",
                .Status => try std.fmt.bufPrint(&buffer, "STATUS={any}", .{args}),
                .Errno => try std.fmt.bufPrint(&buffer, "ERRNO={any}", .{args}),
                .MainPid => try std.fmt.bufPrint(&buffer, "MAINPID={any}", .{args}),
                .Watchdog => "WATCHDOG=1\n",
                .FdStore => "FDSTORE=1\n",
            };
        }
    };

    pub fn init(ptr: notifyFnType, socketfd: ?std.posix.socket_t) Notifier {
        return Notifier{
            .socketfd = socketfd,
            .notifyFn = ptr,
        };
    }

    pub fn deinit(self: *Notifier) void {
        if (self.socketfd) |socketfd| {
            _ = std.posix.close(socketfd);
        }
    }

    pub fn ready(self: *Notifier) !void {
        if (self.metadata != null) {
            self.metadata.?.last_check = std.time.timestamp();
        }
        try self.notify(.Ready, .{});
    }

    pub fn reloading(self: *Notifier) !void {
        try self.notify(.Reloading, .{});
    }

    pub fn stopping(self: *Notifier) !void {
        try self.notify(.Stopping, .{});
    }

    pub fn status(self: *Notifier, message: []const u8) !void {
        try self.notify(.Status, .{message});
    }

    pub fn errno(self: *Notifier, message: []const u8) !void {
        try self.notify(.Errno, .{message});
    }

    pub fn main_pid(self: *Notifier, pid: u32) !void {
        try self.notify(.MainPid, .{pid});
    }

    pub fn watchdog(self: *Notifier) !void {
        if (self.metadata) |metadata| {
            const now = std.time.timestamp();

            // if timer is not passed then return
            if (now - metadata.last_check < metadata.interval - 2) {
                return;
            }

            self.metadata.?.last_check = now;
        }

        try self.notify(.Watchdog, .{});
    }

    pub fn fd_store(self: *Notifier) !void {
        try self.notify(.FdStore, .{});
    }

    pub fn get_interval(self: *Notifier) u64 {
        if (self.metadata) |metadata| {
            return metadata.interval;
        }
        return 0;
    }

    fn notify(self: *Notifier, state: State, args: anytype) !void {
        const message: []const u8 = try state._raw(args);
        if (self.socketfd) |socketfd| {
            try self.notifyFn(socketfd, message);
        }
    }
};

fn notify(fd: std.posix.socket_t, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        index += try std.posix.write(fd, bytes[index..]);
    }
}

fn no_notify(socket: std.posix.socket_t, bytes: []const u8) !void {
    _ = socket;
    _ = bytes;
    return;
}

fn connectUnixSocket(path: []const u8) !std.posix.socket_t {
    const opt_non_block = 0;
    const sockfd = try std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC | opt_non_block,
        0,
    );
    errdefer std.posix.close(sockfd);

    var addr = try std.net.Address.initUnix(path);
    try std.posix.connect(sockfd, &addr.any, addr.getOsSockLen());

    return sockfd;
}
