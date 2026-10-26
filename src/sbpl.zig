const std = @import("std");

pub const Action = enum {
    allow,
    deny,
};

pub const Operation = enum {
    file_all,
    file_ioctl,
    file_map_executable,
    file_read_all,
    file_read_data,
    file_read_metadata,
    file_write_all,
    file_write_data,
    file_write_create,
    ipc_posix_shm_read_data,
    ipc_posix_shm_write_create,
    mach_lookup,
    mach_priv_task_port,
    network_bind,
    network_inbound,
    network_outbound,
    process_exec,
    process_fork,
    process_info_all,
    signal,
    sysctl_all,
    system_socket,

    pub fn write(self: Operation, writer: anytype) !void {
        switch (self) {
            .file_all => try writer.writeAll("file*"),
            .file_ioctl => try writer.writeAll("file-ioctl"),
            .file_map_executable => try writer.writeAll("file-map-executable"),
            .file_read_all => try writer.writeAll("file-read*"),
            .file_read_data => try writer.writeAll("file-read-data"),
            .file_read_metadata => try writer.writeAll("file-read-metadata"),
            .file_write_all => try writer.writeAll("file-write*"),
            .file_write_data => try writer.writeAll("file-write-data"),
            .file_write_create => try writer.writeAll("file-write-create"),
            .ipc_posix_shm_read_data => try writer.writeAll("ipc-posix-shm-read-data"),
            .ipc_posix_shm_write_create => try writer.writeAll("ipc-posix-shm-write-create"),
            .mach_lookup => try writer.writeAll("mach-lookup"),
            .mach_priv_task_port => try writer.writeAll("mach-priv-task-port"),
            .network_bind => try writer.writeAll("network-bind"),
            .network_inbound => try writer.writeAll("network-inbound"),
            .network_outbound => try writer.writeAll("network-outbound"),
            .process_exec => try writer.writeAll("process-exec"),
            .process_fork => try writer.writeAll("process-fork"),
            .process_info_all => try writer.writeAll("process-info*"),
            .signal => try writer.writeAll("signal"),
            .sysctl_all => try writer.writeAll("sysctl*"),
            .system_socket => try writer.writeAll("system-socket"),
        }
    }
};

test "write operation" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try Operation.file_all.write(w);
    try Operation.file_read_data.write(w);
    try Operation.file_write_data.write(w);
    try Operation.file_read_all.write(w);
    try Operation.file_write_create.write(w);
    try Operation.ipc_posix_shm_read_data.write(w);
    try Operation.mach_lookup.write(w);

    try std.testing.expectEqualStrings("file*file-read-datafile-write-datafile-read*file-write-createipc-posix-shm-read-datamach-lookup", aw.written());
}

pub const Expr = union(enum) {
    literal: []const u8,
    param: []const u8,
    param_append: struct { param: []const u8, suffix: []const u8 },

    pub fn write(self: Expr, writer: anytype) !void {
        switch (self) {
            .literal => |s| try writer.print("\"{s}\"", .{s}),
            .param => |s| try writer.print("(param \"{s}\")", .{s}),
            .param_append => |pa| try writer.print("(string-append (param \"{s}\") \"{s}\")", .{ pa.param, pa.suffix }),
        }
    }
};

test "write expr" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try (Expr{ .literal = "a/b/c" }).write(w);
    try std.testing.expectEqualStrings("\"a/b/c\"", aw.written());

    aw.clearRetainingCapacity();

    try (Expr{ .param = "CWD" }).write(w);
    try std.testing.expectEqualStrings("(param \"CWD\")", aw.written());

    aw.clearRetainingCapacity();

    try (Expr{ .param_append = .{ .param = "CWD", .suffix = "a/b/c" } }).write(w);
    try std.testing.expectEqualStrings("(string-append (param \"CWD\") \"a/b/c\")", aw.written());
}

pub const Filter = union(enum) {
    subpath: Expr,
    literal: Expr,
    global_name: []const u8,
    socket_domain: u32,
    target: []const u8,
    remote_tcp: []const u8,
    remote_unix_socket: Expr,

    pub fn write(self: Filter, writer: anytype) !void {
        switch (self) {
            .remote_tcp => |address| {
                try writer.print("(remote tcp \"{s}\")", .{address});
            },
            .remote_unix_socket => |expr| {
                try writer.writeAll("(remote unix-socket (path-literal ");
                try expr.write(writer);
                try writer.writeAll("))");
            },
            .subpath => |expr| {
                try writer.writeAll("(subpath ");
                try expr.write(writer);
                try writer.writeAll(")");
            },
            .literal => |expr| {
                try writer.writeAll("(literal ");
                try expr.write(writer);
                try writer.writeAll(")");
            },
            .global_name => |name| {
                try writer.print("(global-name \"{s}\")", .{name});
            },
            .socket_domain => |domain| {
                try writer.print("(socket-domain {d})", .{domain});
            },
            .target => |t| {
                try writer.print("(target {s})", .{t});
            },
        }
    }
};

test "write filter" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try (Filter{ .subpath = .{ .param_append = .{ .param = "CWD", .suffix = "/a/b/c" } } }).write(w);
    try std.testing.expectEqualStrings("(subpath (string-append (param \"CWD\") \"/a/b/c\"))", aw.written());

    aw.clearRetainingCapacity();

    try (Filter{ .literal = .{ .literal = "/a/b/c" } }).write(w);
    try std.testing.expectEqualStrings("(literal \"/a/b/c\")", aw.written());

    aw.clearRetainingCapacity();

    try (Filter{ .global_name = "com.apple.SecurityServer" }).write(w);
    try std.testing.expectEqualStrings("(global-name \"com.apple.SecurityServer\")", aw.written());

    aw.clearRetainingCapacity();

    try (Filter{ .target = "same-sandbox" }).write(w);
    try std.testing.expectEqualStrings("(target same-sandbox)", aw.written());

    aw.clearRetainingCapacity();

    try (Filter{ .socket_domain = 32 }).write(w);
    try std.testing.expectEqualStrings("(socket-domain 32)", aw.written());

    aw.clearRetainingCapacity();

    try (Filter{ .remote_tcp = "*:443" }).write(w);
    try std.testing.expectEqualStrings("(remote tcp \"*:443\")", aw.written());

    aw.clearRetainingCapacity();

    try (Filter{ .remote_unix_socket = .{ .param = "BROKER_SOCK" } }).write(w);
    try std.testing.expectEqualStrings("(remote unix-socket (path-literal (param \"BROKER_SOCK\")))", aw.written());
}

pub const Rule = struct {
    action: Action,
    operation: Operation,
    filter: ?Filter = null,

    pub fn allow(operation: Operation, filter: ?Filter) Rule {
        return .{ .action = .allow, .operation = operation, .filter = filter };
    }

    pub fn deny(operation: Operation, filter: ?Filter) Rule {
        return .{ .action = .deny, .operation = operation, .filter = filter };
    }

    pub fn write(self: Rule, writer: anytype) !void {
        try writer.writeAll("(");
        try writer.writeAll(@tagName(self.action));
        try writer.writeAll(" ");
        try self.operation.write(writer);
        if (self.filter) |f| {
            try writer.writeAll(" ");
            try f.write(writer);
        }
        try writer.writeAll(")");
    }
};

test "write rule" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const rule = Rule{
        .action = .allow,
        .operation = .file_read_all,
        .filter = .{ .subpath = .{ .param_append = .{ .param = "CWD", .suffix = "/a/b/c" } } },
    };
    try rule.write(w);
    try std.testing.expectEqualStrings("(allow file-read* (subpath (string-append (param \"CWD\") \"/a/b/c\")))", aw.written());

    aw.clearRetainingCapacity();

    try (Rule{ .action = .allow, .operation = .process_exec }).write(w);
    try std.testing.expectEqualStrings("(allow process-exec)", aw.written());
}

pub const Profile = struct {
    version: []const u8 = "1",
    deny_default: bool = true,
    rules: []const Rule = &.{},

    pub fn write(self: Profile, writer: anytype) !void {
        try writer.print("(version {s})\n", .{self.version});

        if (self.deny_default) {
            try writer.writeAll("(deny default)");
        } else {
            try writer.writeAll("(allow default)");
        }

        for (self.rules) |r| {
            try writer.writeAll("\n");
            try r.write(writer);
        }
    }
};

test "write profile" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const profile = Profile{
        .rules = &.{
            Rule.allow(.file_read_all, .{ .subpath = .{ .param_append = .{ .param = "CWD", .suffix = "/a/b/c" } } }),
        },
    };
    try profile.write(w);

    const expected =
        \\(version 1)
        \\(deny default)
        \\(allow file-read* (subpath (string-append (param "CWD") "/a/b/c")))
    ;
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "write profile multiple rules" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const profile = Profile{
        .rules = &.{
            Rule.allow(.process_exec, null),
            Rule.allow(.process_fork, null),
        },
    };
    try profile.write(w);

    const expected =
        \\(version 1)
        \\(deny default)
        \\(allow process-exec)
        \\(allow process-fork)
    ;
    try std.testing.expectEqualStrings(expected, aw.written());
}
