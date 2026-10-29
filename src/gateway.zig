const std = @import("std");

pub const Keychain = struct {
    service: []const u8,
    field: []const []const u8 = &.{},
};

pub const Secret = union(enum) {
    keychain: Keychain,
};

pub const Gateway = struct {
    name: []const u8,
    argv: []const []const u8,
    env: std.json.ArrayHashMap([]const u8) = .{},
    secrets: std.json.ArrayHashMap(Secret) = .{},
};

pub const Env = struct {
    gateway: []const u8,
    name: []const u8,
    value: []const u8,
};

pub const Running = struct {
    name: []const u8,
    port: u16,
    url: []const u8,
    child: std.process.Child,

    pub fn stop(self: *Running, io: std.Io) void {
        self.child.kill(io);
    }
};

pub fn start(arena: std.mem.Allocator, io: std.Io, gateway: Gateway, environ: *const std.process.Environ.Map) !Running {
    const port = try freePort(io);
    const port_text = try std.fmt.allocPrint(arena, "{d}", .{port});

    var child_environ = try environ.clone(arena);
    var it = gateway.env.map.iterator();
    while (it.next()) |entry| try child_environ.put(entry.key_ptr.*, entry.value_ptr.*);
    var secrets = gateway.secrets.map.iterator();
    while (secrets.next()) |entry| try child_environ.put(entry.key_ptr.*, try readSecret(arena, io, entry.value_ptr.*));
    try child_environ.put("ZANDY_GATEWAY_PORT", port_text);

    var child = try std.process.spawn(io, .{
        .argv = try withPort(arena, gateway.argv, port_text),
        .environ_map = &child_environ,
        .stdin = .ignore,
        .stdout = .ignore,
    });
    errdefer child.kill(io);
    try waitUntilListening(io, port);

    return .{
        .name = gateway.name,
        .port = port,
        .url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{port}),
        .child = child,
    };
}

pub fn environFor(arena: std.mem.Allocator, entries: []const Env, running: Running) ![]const std.http.Header {
    var vars: std.ArrayList(std.http.Header) = .empty;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.gateway, running.name)) continue;
        try vars.append(arena, .{ .name = entry.name, .value = try std.mem.replaceOwned(u8, arena, entry.value, "{url}", running.url) });
    }
    return vars.items;
}

fn readSecret(arena: std.mem.Allocator, io: std.Io, secret: Secret) ![]const u8 {
    return switch (secret) {
        .keychain => |keychain| readKeychain(arena, io, keychain),
    };
}

fn readKeychain(arena: std.mem.Allocator, io: std.Io, keychain: Keychain) ![]const u8 {
    const result = try std.process.run(arena, io, .{ .argv = &.{ "/usr/bin/security", "find-generic-password", "-s", keychain.service, "-w" } });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.NoKeychainItem,
        else => return error.NoKeychainItem,
    }
    const value = std.mem.trimEnd(u8, result.stdout, "\n");
    if (keychain.field.len == 0) return value;
    return jsonField(arena, value, keychain.field);
}

fn jsonField(arena: std.mem.Allocator, json: []const u8, path: []const []const u8) ![]const u8 {
    var value = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.NoKeychainField;
    for (path) |name| {
        if (value != .object) return error.NoKeychainField;
        value = value.object.get(name) orelse return error.NoKeychainField;
    }
    if (value != .string) return error.NoKeychainField;
    return value.string;
}

fn freePort(io: std.Io) !u16 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    return server.socket.address.getPort();
}

fn withPort(arena: std.mem.Allocator, argv: []const []const u8, port_text: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, argv.len);
    for (argv, out) |arg, *slot| slot.* = try std.mem.replaceOwned(u8, arena, arg, "{port}", port_text);
    return out;
}

fn waitUntilListening(io: std.Io, port: u16) !void {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    for (0..50) |_| {
        if (address.connect(io, .{ .mode = .stream })) |conn| {
            conn.close(io);
            return;
        } else |_| try io.sleep(.fromMilliseconds(100), .awake);
    }
    return error.GatewayNotListening;
}

test "withPort fills in the port wherever argv asks for it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const argv = try withPort(arena_state.allocator(), &.{ "aws-sigv4-proxy", "--port", "127.0.0.1:{port}" }, "4711");
    try std.testing.expectEqualStrings("aws-sigv4-proxy", argv[0]);
    try std.testing.expectEqualStrings("127.0.0.1:4711", argv[2]);
}

test "environFor fills in the url of the running gateway" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const running: Running = .{ .name = "anthropic", .port = 4711, .url = "http://127.0.0.1:4711", .child = undefined };
    const entries = [_]Env{
        .{ .gateway = "anthropic", .name = "ANTHROPIC_BASE_URL", .value = "{url}" },
        .{ .gateway = "anthropic", .name = "ANTHROPIC_AUTH_TOKEN", .value = "zandy-gateway" },
        .{ .gateway = "bedrock", .name = "ANTHROPIC_BEDROCK_BASE_URL", .value = "{url}" },
    };

    const vars = try environFor(arena_state.allocator(), &entries, running);
    try std.testing.expectEqual(2, vars.len);
    try std.testing.expectEqualStrings("http://127.0.0.1:4711", vars[0].value);
    try std.testing.expectEqualStrings("zandy-gateway", vars[1].value);
}

test "parses keychain secrets of a gateway" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const gateway = try std.json.parseFromSliceLeaky(Gateway, arena_state.allocator(),
        \\{"name":"anthropic","argv":["caddy"],"secrets":{"ZANDY_GATEWAY_TOKEN":{"keychain":{"service":"Claude Code-credentials","field":["claudeAiOauth","accessToken"]}}}}
    , .{});
    const keychain = gateway.secrets.map.get("ZANDY_GATEWAY_TOKEN").?.keychain;
    try std.testing.expectEqualStrings("Claude Code-credentials", keychain.service);
    try std.testing.expectEqualStrings("accessToken", keychain.field[1]);
}

test "jsonField follows the path to a string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const token = try jsonField(arena_state.allocator(), "{\"claudeAiOauth\":{\"accessToken\":\"sk-ant-oat\"}}", &.{ "claudeAiOauth", "accessToken" });
    try std.testing.expectEqualStrings("sk-ant-oat", token);
}

test "jsonField rejects a missing field and a non-string value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.NoKeychainField, jsonField(arena, "{\"claudeAiOauth\":{}}", &.{ "claudeAiOauth", "accessToken" }));
    try std.testing.expectError(error.NoKeychainField, jsonField(arena, "{\"claudeAiOauth\":{\"accessToken\":1}}", &.{ "claudeAiOauth", "accessToken" }));
    try std.testing.expectError(error.NoKeychainField, jsonField(arena, "not json", &.{"claudeAiOauth"}));
}
