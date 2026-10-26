const std = @import("std");
const rpc = @import("rpc.zig");

pub const max_line_len = 64 * 1024;

pub fn listen(io: std.Io, path: []const u8) !std.Io.net.Server {
    if (connect(io, path)) |stream| {
        stream.close(io);
        return error.AddressInUse;
    } else |err| switch (err) {
        // in zig 0.17 there is an explicit error.ConnectionRefused
        error.Unexpected => try std.Io.Dir.deleteFileAbsolute(io, path),
        error.FileNotFound => {},
        else => return err,
    }

    const address = try std.Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    errdefer server.deinit(io);

    try std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o600), .{});

    return server;
}

pub fn connect(io: std.Io, path: []const u8) !std.Io.net.Stream {
    const address = try std.Io.net.UnixAddress.init(path);
    return address.connect(io);
}

pub fn createSocketDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, parent, .fromMode(0o700));

    try std.Io.Dir.createDirAbsolute(io, path, .fromMode(0o700));
}

pub fn removeSocketDir(io: std.Io, path: []const u8) !void {
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&sock_buf, "{s}/broker.sock", .{path});

    try std.Io.Dir.deleteFileAbsolute(io, sock_path);
    try std.Io.Dir.deleteDirAbsolute(io, path);
}


fn readLine(reader: *std.Io.Reader) ![]u8 {
    return try reader.takeDelimiterExclusive('\n');
}

pub fn newTicket(io: std.Io) [rpc.ticket_len]u8 {
    var bytes: [rpc.ticket_len / 2]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

pub fn serve(io: std.Io, gpa: std.mem.Allocator, server: *std.Io.net.Server, ctx: *const rpc.Context) !void {
    const conn = try server.accept(io);
    defer conn.close(io);

    var rbuf: [max_line_len]u8 = undefined;
    var reader = conn.reader(io, &rbuf);
    const line = readLine(&reader.interface) catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const response = try rpc.handle(arena_state.allocator(), io, ctx, line) orelse return;

    var wbuf: [64]u8 = undefined;
    var writer = conn.writer(io, &wbuf);
    try writer.interface.writeAll(response);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

pub fn serveLoop(io: std.Io, gpa: std.mem.Allocator, server: *std.Io.net.Server, ctx: *const rpc.Context) void {
    while (true) {
        serve(io, gpa, server, ctx) catch |err| std.log.err("broker: {t}", .{err});
    }
}

pub fn sessionDirPath(buf: []u8, home: []const u8, pid: i32) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/.zandy/run/{d}", .{ home, pid });
}


const test_ticket = "a" ** rpc.ticket_len;
const test_ctx: rpc.Context = .{ .ticket = test_ticket, .registry = .{ .capabilities = &.{} } };
test "broker receives `ping` from client" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    var server = try listen(std.testing.io, path);
    defer server.deinit(std.testing.io);

    const client = try connect(std.testing.io, path);
    defer client.close(std.testing.io);

    var wbuf: [64]u8 = undefined;
    var writer = client.writer(std.testing.io, &wbuf);
    try writer.interface.writeAll("ping\n");
    try writer.interface.flush();

    const conn = try server.accept(std.testing.io);
    defer conn.close(std.testing.io);

    var rbuf: [64]u8 = undefined;
    var reader = conn.reader(std.testing.io, &rbuf);
    const line = try reader.interface.takeDelimiterExclusive('\n');

    try std.testing.expectEqualStrings("ping", line);
}

test "listen creates socket file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    var server = try listen(std.testing.io, path);
    defer server.deinit(std.testing.io);

    const stat = try tmp.dir.statFile(std.testing.io, "broker.sock", .{});

    try std.testing.expectEqual(.unix_domain_socket, stat.kind);
}

test "listen on existing file returns AddressInUse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    var server = try listen(std.testing.io, path);
    defer server.deinit(std.testing.io);

    try std.testing.expectError(error.AddressInUse, listen(std.testing.io, path));
    const stat = try tmp.dir.statFile(std.testing.io, "broker.sock", .{});
    try std.testing.expectEqual(.unix_domain_socket, stat.kind);
}

test "child pings parent over socket" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    var server = try listen(std.testing.io, path);
    defer server.deinit(std.testing.io);

    const pid = std.c.fork();
    try std.testing.expect(pid != -1);

    if (pid == 0) {
        var wbuf: [64]u8 = undefined;
        const client = connect(std.testing.io, path) catch std.c._exit(1);
        defer client.close(std.testing.io);

        var writer = client.writer(std.testing.io, &wbuf);
        writer.interface.writeAll("ping\n") catch std.c._exit(1);
        writer.interface.flush() catch std.c._exit(1);

        std.c._exit(0);
    }

    const conn = try server.accept(std.testing.io);
    defer conn.close(std.testing.io);

    var rbuf: [64]u8 = undefined;
    var reader = conn.reader(std.testing.io, &rbuf);
    const line = try reader.interface.takeDelimiterExclusive('\n');

    try std.testing.expectEqualStrings("ping", line);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(0, std.c.W.EXITSTATUS(@bitCast(status)));
}

test "listen replaces an existing socket file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    var server = try listen(std.testing.io, path);
    server.deinit(std.testing.io);

    var server2 = try listen(std.testing.io, path);
    defer server2.deinit(std.testing.io);
}

test "socket file is only accessible by the owner `0600`" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    var server = try listen(std.testing.io, path);
    defer server.deinit(std.testing.io);

    const stat = try tmp.dir.statFile(std.testing.io, "broker.sock", .{});
    const mode = stat.permissions.toMode() & 0o777;

    try std.testing.expectEqual(0o600, mode);
}

test "socket directory is created with `0700`" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/run", .{dir_buf[0..len]});

    try createSocketDir(std.testing.io, path);

    const stat = try tmp.dir.statFile(std.testing.io, "run", .{});
    const mode = stat.permissions.toMode() & 0o777;

    try std.testing.expectEqual(0o700, mode);
}

test "line longer than max_line is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    var server = try listen(std.testing.io, path);
    defer server.deinit(std.testing.io);

    const pid = std.c.fork();
    try std.testing.expect(pid != -1);

    if (pid == 0) {
        var wbuf: [64]u8 = undefined;
        const client = connect(std.testing.io, path) catch std.c._exit(1);
        defer client.close(std.testing.io);

        var writer = client.writer(std.testing.io, &wbuf);
        writer.interface.splatByteAll('a', 64 + 1) catch std.c._exit(1);
        writer.interface.flush() catch std.c._exit(1);

        std.c._exit(0);
    }

    const conn = try server.accept(std.testing.io);
    defer conn.close(std.testing.io);

    var rbuf: [64]u8 = undefined;
    var reader = conn.reader(std.testing.io, &rbuf);

    try std.testing.expectError(error.StreamTooLong, readLine(&reader.interface));
}

test "session dir is under home and named by pid" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try sessionDirPath(&buf, "/Users/test", 4242);
    try std.testing.expectEqualStrings("/Users/test/.zandy/run/4242", dir);
}

test "socket dir creates missing parent dirs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/.zandy/run/4242", .{dir_buf[0..len]});

    try createSocketDir(std.testing.io, path);

    const stat = try tmp.dir.statFile(std.testing.io, ".zandy/run/4242", .{});
    try std.testing.expectEqual(.directory, stat.kind);
    try std.testing.expectEqual(0o700, stat.permissions.toMode() & 0o777);
}

test "serve answers rpc.discover" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    var server = try listen(std.testing.io, path);
    defer server.deinit(std.testing.io);

    const pid = std.c.fork();
    try std.testing.expect(pid != -1);

    if (pid == 0) {
        const client = connect(std.testing.io, path) catch std.c._exit(1);

        var wbuf: [64]u8 = undefined;
        var writer = client.writer(std.testing.io, &wbuf);
        writer.interface.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"rpc.discover\",\"params\":{\"ticket\":\"" ++ test_ticket ++ "\"}}\n") catch std.c._exit(1);
        writer.interface.flush() catch std.c._exit(1);

        var rbuf: [256]u8 = undefined;
        var reader = client.reader(std.testing.io, &rbuf);
        const line = reader.interface.takeDelimiterExclusive('\n') catch std.c._exit(1);
        if (!std.mem.eql(u8, line, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"version\":\"1\",\"methods\":[]}}")) std.c._exit(2);

        std.c._exit(0);
    }

    try serve(std.testing.io, std.testing.allocator, &server, &test_ctx);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(0, std.c.W.EXITSTATUS(@bitCast(status)));
}

test "serve ignores a client that sends nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    var server = try listen(std.testing.io, path);
    defer server.deinit(std.testing.io);

    const pid = std.c.fork();
    try std.testing.expect(pid != -1);

    if (pid == 0) {
        _ = connect(std.testing.io, path) catch std.c._exit(1);
        std.c._exit(0);
    }

    try serve(std.testing.io, std.testing.allocator, &server, &test_ctx);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(0, std.c.W.EXITSTATUS(@bitCast(status)));
}

test "removeSocketDir deletes the socket and its dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path_buf, "{s}/run", .{dir_buf[0..len]});
    try createSocketDir(std.testing.io, dir_path);

    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&sock_buf, "{s}/broker.sock", .{dir_path});
    var server = try listen(std.testing.io, sock_path);
    server.deinit(std.testing.io);

    try removeSocketDir(std.testing.io, dir_path);

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "run", .{}));
}

test "newTicket returns lowercase hex" {
    const ticket = newTicket(std.testing.io);

    for (ticket) |c| {
        try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    }
}

test "newTicket returns a different ticket each time" {
    const a = newTicket(std.testing.io);
    const b = newTicket(std.testing.io);

    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
