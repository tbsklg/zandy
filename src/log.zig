const std = @import("std");

const subsystem = "tbsklg.zandy";

const OsLog = opaque {};

const LogType = enum(u8) {
    default = 0x00,
    debug = 0x02,
    err = 0x10,
    fault = 0x11,
};

extern "c" fn os_log_create(subsystem: [*:0]const u8, category: [*:0]const u8) ?*OsLog;
extern "c" fn os_log_type_enabled(log: *OsLog, kind: LogType) bool;
extern "c" fn os_release(object: *anyopaque) void;
extern "c" fn zandy_os_log_with_type(log: *OsLog, kind: LogType, message: [*:0]const u8) void;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    switch (level) {
        .err, .warn => std.log.defaultLog(level, scope, format, args),
        .info, .debug => {},
    }

    const log = logger(scope) orelse return;
    const kind = logType(level);
    if (!os_log_type_enabled(log, kind)) return;

    var buf: [4096]u8 = undefined;
    const message = std.fmt.bufPrintZ(&buf, format, args) catch truncated: {
        buf[buf.len - 1] = 0;
        break :truncated buf[0 .. buf.len - 1 :0];
    };

    zandy_os_log_with_type(log, kind, message.ptr);
}

// One os_log handle per scope, created once and reused: creating one per log
// call is slow, and Apple's guidance is to reuse them. The atomic swap handles
// the broker thread racing the main thread on first use.
// Adapted from Ghostty: https://github.com/ghostty-org/ghostty/blob/42c92b620e6acec5bf6953c4e1c9aa489b5cb918/src/main_ghostty.zig#L170-L199
fn logger(comptime scope: @EnumLiteral()) ?*OsLog {
    const cache = struct {
        var log: std.atomic.Value(?*OsLog) = .init(null);
    };
    if (cache.log.load(.acquire)) |log| return log;

    const created = os_log_create(subsystem, @tagName(scope)) orelse return null;
    if (cache.log.cmpxchgStrong(null, created, .acq_rel, .acquire)) |existing| {
        os_release(created);
        return existing;
    }
    return created;
}

fn logType(comptime level: std.log.Level) LogType {
    return switch (level) {
        .debug => .debug,
        .info => .default,
        .warn => .err,
        .err => .fault,
    };
}
