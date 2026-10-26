const std = @import("std");
const broker = @import("broker.zig");
const rpc = @import("rpc.zig");

const usage =
    \\usage: zandy-client discover
    \\       zandy-client call <method> ['<json args>']
;

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        if (err != error.Reported) std.debug.print("zandy-client: {s}\n", .{message(err)});
        return exitCode(err);
    };
    return 0;
}

const Command = union(enum) {
    discover,
    call: struct { method: []const u8, args: std.json.Value },
};

fn parseCommand(arena: std.mem.Allocator, argv: []const [:0]const u8) !Command {
    if (argv.len < 2) return error.Usage;

    if (std.mem.eql(u8, argv[1], "discover")) {
        if (argv.len != 2) return error.Usage;
        return .discover;
    }

    if (std.mem.eql(u8, argv[1], "call")) {
        if (argv.len != 3 and argv.len != 4) return error.Usage;
        const args = try parseArgsJson(arena, if (argv.len == 4) argv[3] else "{}");
        return .{ .call = .{ .method = argv[2], .args = args } };
    }

    return error.Usage;
}

fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const command = try parseCommand(arena, try init.minimal.args.toSlice(arena));
    const config = try readConfig(init.environ_map);

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;

    switch (command) {
        .discover => {
            const result = try send(io, arena, config, "rpc.discover", null);
            try checkVersion(result);
            try out.print("{f}\n", .{std.json.fmt(result, .{})});
        },
        .call => |c| {
            const result = try send(io, arena, config, c.method, c.args);
            if (result != .string) return error.InvalidResponse;
            try out.writeAll(result.string);
        },
    }

    try out.flush();
}

fn send(io: std.Io, arena: std.mem.Allocator, config: Config, method: []const u8, args: ?std.json.Value) !std.json.Value {
    const line = try call(io, arena, config.sock, try buildRequest(arena, method, config.ticket, args));
    return switch (try parseReply(arena, line)) {
        .result => |result| result,
        .failure => |msg| {
            std.debug.print("zandy-client: {s}\n", .{msg});
            return error.Reported;
        },
    };
}

fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.Usage, error.InvalidArgs, error.MissingBrokerSock, error.MissingBrokerTicket => 2,
        error.BrokerNotRunning => 3,
        error.Unauthenticated, error.Reported => 4,
        error.VersionMismatch => 5,
        else => 1,
    };
}

fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.Usage => usage,
        error.InvalidArgs => "args must be a JSON object",
        error.MissingBrokerSock => "BROKER_SOCK is not set",
        error.MissingBrokerTicket => "BROKER_TICKET is not set",
        error.BrokerNotRunning => "broker not running",
        error.Unauthenticated => "broker refused the ticket",
        error.VersionMismatch => "broker speaks another protocol version",
        error.InvalidResponse => "broker sent an invalid response",
        else => @errorName(err),
    };
}

const Config = struct {
    sock: []const u8,
    ticket: []const u8,
};

fn readConfig(env: *std.process.Environ.Map) !Config {
    const sock = env.get("BROKER_SOCK") orelse return error.MissingBrokerSock;
    const ticket = env.get("BROKER_TICKET") orelse return error.MissingBrokerTicket;

    return .{
        .sock = sock,
        .ticket = ticket,
    };
}

const protocol_version = "1";

const Reply = union(enum) {
    result: std.json.Value,
    failure: []const u8,
};

const Response = struct {
    result: ?std.json.Value = null,
    @"error": ?struct {
        code: i64,
        message: []const u8 = "",
    } = null,
};

fn parseReply(arena: std.mem.Allocator, line: []const u8) !Reply {
    const response = std.json.parseFromSliceLeaky(Response, arena, line, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidResponse;

    if (response.@"error") |err| {
        if (err.code == -32001) return error.Unauthenticated;
        return .{ .failure = err.message };
    }
    return .{ .result = response.result orelse return error.InvalidResponse };
}

fn checkVersion(result: std.json.Value) !void {
    if (result != .object) return error.InvalidResponse;
    const version = result.object.get("version") orelse return error.InvalidResponse;
    if (version != .string or !std.mem.eql(u8, version.string, protocol_version)) return error.VersionMismatch;
}

fn parseArgsJson(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.InvalidArgs;
    if (value != .object) return error.InvalidArgs;
    return value;
}

fn call(io: std.Io, arena: std.mem.Allocator, sock: []const u8, line: []const u8) ![]const u8 {
    const conn = broker.connect(io, sock) catch |err| switch (err) {
        error.FileNotFound, error.Unexpected => return error.BrokerNotRunning,
        else => return err,
    };
    defer conn.close(io);

    var wbuf: [256]u8 = undefined;
    var writer = conn.writer(io, &wbuf);
    try writer.interface.writeAll(line);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();

    var rbuf: [4096]u8 = undefined;
    var reader = conn.reader(io, &rbuf);
    var reply: std.Io.Writer.Allocating = .init(arena);
    _ = try reader.interface.streamDelimiter(&reply.writer, '\n');

    return reply.written();
}

fn buildRequest(arena: std.mem.Allocator, method: []const u8, ticket: []const u8, args: ?std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":{f},\"params\":{{\"ticket\":{f}", .{
        std.json.fmt(method, .{}),
        std.json.fmt(ticket, .{}),
    });
    if (args) |a| try w.print(",\"args\":{f}", .{std.json.fmt(a, .{})});
    try w.writeAll("}}");
    return out.written();
}

test "parseCommand parses discover" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const argv = [_][:0]const u8{ "zandy-client", "discover" };

    try std.testing.expectEqual(.discover, try parseCommand(arena_state.allocator(), &argv));
}

test "parseCommand parses call with args" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const argv = [_][:0]const u8{ "zandy-client", "call", "gitlab.cli", "{\"args\":[\"issue\",\"list\"]}" };
    const command = try parseCommand(arena_state.allocator(), &argv);

    try std.testing.expectEqualStrings("gitlab.cli", command.call.method);
    try std.testing.expect(command.call.args.object.contains("args"));
}

test "parseCommand defaults call args to an empty object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const argv = [_][:0]const u8{ "zandy-client", "call", "backend.credentials" };
    const command = try parseCommand(arena_state.allocator(), &argv);

    try std.testing.expectEqual(0, command.call.args.object.count());
}

test "parseCommand rejects unknown commands and wrong arity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Usage, parseCommand(arena, &.{"zandy-client"}));
    try std.testing.expectError(error.Usage, parseCommand(arena, &.{ "zandy-client", "list" }));
    try std.testing.expectError(error.Usage, parseCommand(arena, &.{ "zandy-client", "discover", "extra" }));
    try std.testing.expectError(error.Usage, parseCommand(arena, &.{ "zandy-client", "call" }));
}

test "readConfig returns socket and ticket from env" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("BROKER_SOCK", "/tmp/broker.sock");
    try env.put("BROKER_TICKET", "abc");

    const config = try readConfig(&env);

    try std.testing.expectEqualStrings("/tmp/broker.sock", config.sock);
    try std.testing.expectEqualStrings("abc", config.ticket);
}

test "readConfig fails without BROKER_SOCK" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("BROKER_TICKET", "abc");

    try std.testing.expectError(error.MissingBrokerSock, readConfig(&env));
}

test "readConfig fails without BROKER_TICKET" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("BROKER_SOCK", "/tmp/broker.sock");

    try std.testing.expectError(error.MissingBrokerTicket, readConfig(&env));
}

test "buildRequest puts method and ticket into a JSON-RPC request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const request = try buildRequest(arena_state.allocator(), "rpc.discover", "abc", null);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"rpc.discover","params":{"ticket":"abc"}}
    , request);
}

test "buildRequest escapes the ticket" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const request = try buildRequest(arena_state.allocator(), "rpc.discover", "a\"b", null);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"rpc.discover","params":{"ticket":"a\"b"}}
    , request);
}

test "parseReply returns the result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const reply = try parseReply(arena_state.allocator(),
        \\{"jsonrpc":"2.0","id":1,"result":"acme/widgets\n"}
    );

    try std.testing.expectEqualStrings("acme/widgets\n", reply.result.string);
}

test "parseReply returns the broker's error message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const reply = try parseReply(arena_state.allocator(),
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params"}}
    );

    try std.testing.expectEqualStrings("Invalid params", reply.failure);
}

test "parseReply maps -32001 to Unauthenticated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.Unauthenticated, parseReply(arena_state.allocator(),
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Unauthenticated"}}
    ));
}

test "parseReply rejects a response that is not JSON-RPC" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.InvalidResponse, parseReply(arena_state.allocator(), "pong"));
}

test "checkVersion refuses another major version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(),
        \\{"version":"2","methods":[]}
    , .{});

    try std.testing.expectError(error.VersionMismatch, checkVersion(result));
}

test "buildRequest puts call args under params.args" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseArgsJson(arena,
        \\{"project":"acme/widgets"}
    );
    const request = try buildRequest(arena, "gitlab.issues.list", "abc", args);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"gitlab.issues.list","params":{"ticket":"abc","args":{"project":"acme/widgets"}}}
    , request);
}

test "parseArgsJson rejects anything but an object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.InvalidArgs, parseArgsJson(arena_state.allocator(), "[1]"));
    try std.testing.expectError(error.InvalidArgs, parseArgsJson(arena_state.allocator(), "{"));
}

test "call sends a request to the broker and returns its response" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    const ticket = "a" ** rpc.ticket_len;
    const ctx: rpc.Context = .{ .ticket = ticket, .registry = .{ .capabilities = &.{} } };
    var server = try broker.listen(std.testing.io, path);
    defer server.deinit(std.testing.io);

    const pid = std.c.fork();
    try std.testing.expect(pid != -1);

    if (pid == 0) {
        broker.serve(std.testing.io, std.heap.page_allocator, &server, &ctx) catch std.c._exit(1);
        std.c._exit(0);
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const response = try call(std.testing.io, arena, path, try buildRequest(arena, "rpc.discover", ticket, null));

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"result":{"version":"1","methods":[]}}
    , response);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(0, std.c.W.EXITSTATUS(@bitCast(status)));
}

test "call reports a missing socket as BrokerNotRunning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    try std.testing.expectError(error.BrokerNotRunning, call(std.testing.io, std.testing.allocator, path, "{}"));
}

test "call reports a socket nobody listens on as BrokerNotRunning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/broker.sock", .{dir_buf[0..len]});

    var server = try broker.listen(std.testing.io, path);
    server.deinit(std.testing.io);

    try std.testing.expectError(error.BrokerNotRunning, call(std.testing.io, std.testing.allocator, path, "{}"));
}

test "exitCode separates usage, broker down, refusal and version" {
    try std.testing.expectEqual(2, exitCode(error.Usage));
    try std.testing.expectEqual(2, exitCode(error.InvalidArgs));
    try std.testing.expectEqual(2, exitCode(error.MissingBrokerSock));
    try std.testing.expectEqual(2, exitCode(error.MissingBrokerTicket));
    try std.testing.expectEqual(3, exitCode(error.BrokerNotRunning));
    try std.testing.expectEqual(4, exitCode(error.Unauthenticated));
    try std.testing.expectEqual(4, exitCode(error.Reported));
    try std.testing.expectEqual(5, exitCode(error.VersionMismatch));
    try std.testing.expectEqual(1, exitCode(error.OutOfMemory));
}
