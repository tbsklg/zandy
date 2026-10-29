const std = @import("std");
const secret = @import("secret.zig");

pub const Gateway = struct {
    name: []const u8,
    argv: []const []const u8,
    env: std.json.ArrayHashMap([]const u8) = .{},
    secrets: secret.Sources = .{},
    files: secret.Files = .{},
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

const inherited_env = [_][]const u8{ "HOME", "PATH", "TMPDIR", "USER" };

pub fn start(arena: std.mem.Allocator, io: std.Io, gateway: Gateway, environ: *const std.process.Environ.Map, home: []const u8, dir: []const u8) !Running {
    const feed = try secret.Feed.start(arena, try secret.materialize(arena, io, home, dir, gateway.secrets, gateway.files));
    defer feed.finish();

    const port = try freePort(io);
    const port_text = try std.fmt.allocPrint(arena, "{d}", .{port});

    var child_environ = std.process.Environ.Map.init(arena);
    for (inherited_env) |name| {
        if (environ.get(name)) |value| try child_environ.put(name, value);
    }
    var it = gateway.env.map.iterator();
    while (it.next()) |entry| try child_environ.put(entry.key_ptr.*, try secret.withDir(arena, entry.value_ptr.*, dir));
    try child_environ.put("ZANDY_GATEWAY_PORT", port_text);

    var child = try std.process.spawn(io, .{
        .argv = try fillArgv(arena, gateway.argv, port_text, dir),
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

fn freePort(io: std.Io) !u16 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    return server.socket.address.getPort();
}

fn fillArgv(arena: std.mem.Allocator, argv: []const []const u8, port_text: []const u8, dir: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, argv.len);
    for (argv, out) |arg, *slot| slot.* = try secret.withDir(arena, try std.mem.replaceOwned(u8, arena, arg, "{port}", port_text), dir);
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

test "fillArgv fills in the port and the private dir wherever argv asks for them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const argv = try fillArgv(arena_state.allocator(), &.{ "caddy", "--port", "127.0.0.1:{port}", "--envfile", "{dir}/secrets.env" }, "4711", "/run/1/gateway");
    try std.testing.expectEqualStrings("caddy", argv[0]);
    try std.testing.expectEqualStrings("127.0.0.1:4711", argv[2]);
    try std.testing.expectEqualStrings("/run/1/gateway/secrets.env", argv[4]);
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

test "parses the secrets and files of a gateway" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const gateway = try std.json.parseFromSliceLeaky(Gateway, arena_state.allocator(),
        \\{"name":"anthropic","argv":["caddy","--envfile","{dir}/secrets.env"],
        \\ "secrets":{"ANTHROPIC_API_KEY":{"keychain":{"service":"anthropic-api-key"}}},
        \\ "files":{"secrets.env":"ANTHROPIC_API_KEY={secret.ANTHROPIC_API_KEY}\n"}}
    , .{});
    try std.testing.expectEqualStrings("anthropic-api-key", gateway.secrets.map.get("ANTHROPIC_API_KEY").?.keychain.service);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY={secret.ANTHROPIC_API_KEY}\n", gateway.files.map.get("secrets.env").?);
}
