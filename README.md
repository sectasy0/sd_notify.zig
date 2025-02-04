# sd_notify.zig

A pure zig implementation systemd's of systemd's service notification protocol aka `sd_notify`.

This implementation functions seamlessly on both systemd and non-systemd systems. On non-systemd systems, it creates a notifier that does nothing.

## Basic example

```rs
const std = @import("std");

const sd_notify = @import("sd_notify");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var notifier = try sd_notify.createNotifier(allocator);

    // There is also `sd_notify.createNotifierUnmanaged(allocator)` version
    // when you'll need manage when it should send notification
    // see `src/lib.zig`

    try notifier.ready();

    while (true) {
        try notifier.watchdog();

        // do heavy stuff here
    }
}
```

## Test systemd service
```
[Unit]
Description=Test service for sd_notify
After=network.target

[Service]
Type=notify
ExecStart=/path/to/executable
WatchdogSec=20s
Restart=always

[Install]
WantedBy=multi-user.target
```