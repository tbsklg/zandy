const std = @import("std");
const registry_mod = @import("registry.zig");
const command = @import("command.zig");

const log = std.log.scoped(.broker);

pub const ticket_len = 64;

/// Everything a request is checked and answered against, for one broker session.
pub const Context = struct {
    ticket: *const [ticket_len]u8,
    registry: registry_mod.Registry,
    environ: ?*const std.process.Environ.Map = null,
};

pub fn handle(arena: std.mem.Allocator, io: std.Io, ctx: *const Context, request: []const u8) !?[]const u8 {
    const obj = parseObject(arena, request) catch |err| return try failure(arena, .null, err);
    const id = obj.get("id") orelse return null;

    const method = methodName(obj);
    const started = std.Io.Clock.awake.now(io);
    const outcome = dispatch(arena, io, ctx, obj) catch |err| {
        log.info("{s} {s} {d}ms", .{ method, @errorName(err), started.untilNow(io, .awake).toMilliseconds() });
        return try failure(arena, id, err);
    };
    log.info("{s} {s} {d}ms", .{ method, @tagName(outcome), started.untilNow(io, .awake).toMilliseconds() });

    return switch (outcome) {
        .success => |result| try resultResponse(arena, id, result),
        .failure => |stderr| try errorResponse(arena, id, -32002, stderr),
    };
}

fn methodName(obj: std.json.ObjectMap) []const u8 {
    const method = obj.get("method") orelse return "?";
    return if (method == .string) method.string else "?";
}

fn parseObject(arena: std.mem.Allocator, request: []const u8) !std.json.ObjectMap {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, request, .{}) catch return error.ParseError;
    return if (parsed == .object) parsed.object else error.InvalidRequest;
}

fn dispatch(arena: std.mem.Allocator, io: std.Io, ctx: *const Context, obj: std.json.ObjectMap) !command.Outcome {
    const version = obj.get("jsonrpc") orelse return error.InvalidRequest;
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return error.InvalidRequest;

    if (!hasValidTicket(obj, ctx.ticket)) return error.Unauthenticated;

    const method = obj.get("method") orelse return error.MethodNotFound;
    if (method != .string) return error.MethodNotFound;

    if (std.mem.eql(u8, method.string, "rpc.discover"))
        return .{ .success = try ctx.registry.discover(arena) };

    const cap = ctx.registry.find(method.string) orelse return error.MethodNotFound;

    const given = obj.get("params").?.object.get("args") orelse std.json.Value{ .object = .{} };
    if (given != .object) return error.InvalidParams;
    const args = try command.parseParams(arena, cap.params, given.object);

    return switch (command.run(arena, io, cap, args, ctx.environ) catch return error.CommandNotStarted) {
        .success => |stdout| .{ .success = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(stdout, .{})}) },
        .failure => |stderr| .{ .failure = stderr },
    };
}

fn failure(arena: std.mem.Allocator, id: std.json.Value, err: anyerror) ![]const u8 {
    const code: i32, const message: []const u8 = switch (err) {
        error.ParseError => .{ -32700, "Parse error" },
        error.InvalidRequest => .{ -32600, "Invalid Request" },
        error.MethodNotFound => .{ -32601, "Method not found" },
        error.InvalidParams => .{ -32602, "Invalid params" },
        error.Unauthenticated => .{ -32001, "Unauthenticated" },
        error.CommandNotStarted => .{ -32003, "Command could not be started" },
        else => return err,
    };
    return errorResponse(arena, id, code, message);
}

fn hasValidTicket(obj: std.json.ObjectMap, ticket: *const [ticket_len]u8) bool {
    const params = obj.get("params") orelse return false;
    if (params != .object) return false;

    const given = params.object.get("ticket") orelse return false;
    if (given != .string or given.string.len != ticket_len) return false;

    return std.crypto.timing_safe.eql([ticket_len]u8, given.string[0..ticket_len].*, ticket.*);
}

fn resultResponse(arena: std.mem.Allocator, id: std.json.Value, result_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{s}}}", .{
        std.json.fmt(id, .{}),
        result_json,
    });
}

fn errorResponse(arena: std.mem.Allocator, id: std.json.Value, code: i32, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"error\":{{\"code\":{d},\"message\":{f}}}}}", .{
        std.json.fmt(id, .{}),
        code,
        std.json.fmt(message, .{}),
    });
}

const test_ticket = "a" ** 64;
const test_ctx: Context = .{ .ticket = test_ticket, .registry = .{ .capabilities = &.{} } };
const valid_params = "\"params\":{\"ticket\":\"" ++ test_ticket ++ "\"}";

test "invalid json returns parse error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(arena_state.allocator(), std.testing.io, &test_ctx, "not json");

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
    , response.?);
}

test "wrong jsonrpc version returns invalid request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(arena_state.allocator(), std.testing.io, &test_ctx,
        \\{"jsonrpc":"1.0","id":1,"method":"rpc.discover"}
    );

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid Request"}}
    , response.?);
}

test "unknown method returns method not found" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(
        arena_state.allocator(),
        std.testing.io,
        &test_ctx,
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"issues.delete\"," ++ valid_params ++ "}",
    );

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"Method not found"}}
    , response.?);
}

test "rpc.discover returns version and method list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(
        arena_state.allocator(),
        std.testing.io,
        &test_ctx,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"rpc.discover\"," ++ valid_params ++ "}",
    );

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"result":{"version":"1","methods":[]}}
    , response.?);
}

test "request without id gets no response" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(arena_state.allocator(), std.testing.io, &test_ctx,
        \\{"jsonrpc":"2.0","method":"rpc.discover"}
    );

    try std.testing.expectEqual(null, response);
}

test "request without params is unauthenticated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(arena_state.allocator(), std.testing.io, &test_ctx,
        \\{"jsonrpc":"2.0","id":1,"method":"rpc.discover"}
    );

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Unauthenticated"}}
    , response.?);
}

test "params without ticket is unauthenticated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(arena_state.allocator(), std.testing.io, &test_ctx,
        \\{"jsonrpc":"2.0","id":1,"method":"rpc.discover","params":{}}
    );

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Unauthenticated"}}
    , response.?);
}

test "wrong ticket is unauthenticated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(arena_state.allocator(), std.testing.io, &test_ctx, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"rpc.discover\",\"params\":{\"ticket\":\"" ++ "b" ** 64 ++ "\"}}");

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Unauthenticated"}}
    , response.?);
}

test "ticket of the wrong length is unauthenticated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(arena_state.allocator(), std.testing.io, &test_ctx,
        \\{"jsonrpc":"2.0","id":1,"method":"rpc.discover","params":{"ticket":"aaaa"}}
    );

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Unauthenticated"}}
    , response.?);
}

test "ticket is checked before the method is looked up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(arena_state.allocator(), std.testing.io, &test_ctx,
        \\{"jsonrpc":"2.0","id":1,"method":"issues.delete"}
    );

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Unauthenticated"}}
    , response.?);
}

test "rpc.discover lists the capabilities of the registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const ctx: Context = .{ .ticket = test_ticket, .registry = .{ .capabilities = &.{
        .{ .name = "issues.list", .binary = "glab" },
    } } };
    const response = try handle(
        arena_state.allocator(),
        std.testing.io,
        &ctx,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"rpc.discover\"," ++ valid_params ++ "}",
    );

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"result":{"version":"1","methods":[{"name":"issues.list","description":"","params":{"type":"object","properties":{},"required":[]}}]}}
    , response.?);
}

const echo_ctx: Context = .{ .ticket = test_ticket, .registry = .{ .capabilities = &.{
    .{
        .name = "acme.echo",
        .binary = "/bin/echo",
        .params = &.{.{ .name = "project" }},
        .argv = &.{.{ .param = 0 }},
    },
} } };

test "calling a capability returns the command's stdout" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(
        arena_state.allocator(),
        std.testing.io,
        &echo_ctx,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"acme.echo\",\"params\":{\"ticket\":\"" ++ test_ticket ++ "\",\"args\":{\"project\":\"acme/widgets\"}}}",
    );

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"result":"acme/widgets\n"}
    , response.?);
}

test "calling a capability with invalid params returns invalid params" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = try handle(
        arena_state.allocator(),
        std.testing.io,
        &echo_ctx,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"acme.echo\"," ++ valid_params ++ "}",
    );

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params"}}
    , response.?);
}
