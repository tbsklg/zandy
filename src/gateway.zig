const std = @import("std");

pub const max_head_len = 8 * 1024;

pub const Gateway = struct {
    name: []const u8,
    upstream: []const u8,
    auth: Auth,
};

pub const Auth = union(enum) {
    header: struct {
        name: []const u8,
        env: []const u8,
        prefix: []const u8 = "",
    },
    /// A local process that adds the auth itself, e.g. aws-sigv4-proxy; `{port}` in `argv` is where it listens.
    proxy: struct {
        argv: []const []const u8,
        env: std.json.ArrayHashMap([]const u8) = .{},
    },
};

pub const Upstream = struct {
    client: *std.http.Client,
    url: []const u8,
    /// Null when a proxy adds the auth.
    auth: ?std.http.Header,
};

const hop_by_hop = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "te", "trailer", "upgrade", "content-length", "host" };

// Credentials from the sandbox are never forwarded; the gateway sets its own.
const credential_headers = [_][]const u8{ "authorization", "proxy-authorization", "x-api-key" };

pub fn listen(io: std.Io) !std.Io.net.Server {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    return address.listen(io, .{});
}

pub fn port(server: *const std.Io.net.Server) u16 {
    return server.socket.address.getPort();
}

pub fn resolveHeader(arena: std.mem.Allocator, auth: @FieldType(Auth, "header"), environ: *const std.process.Environ.Map) !std.http.Header {
    const key = environ.get(auth.env) orelse return error.MissingAuthEnv;
    const value = try std.mem.concat(arena, u8, &.{ auth.prefix, key });
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidAuthValue;
    return .{ .name = auth.name, .value = value };
}

/// A gateway listening for the sandbox, with its auth already resolved.
pub const Running = struct {
    name: []const u8,
    server: std.Io.net.Server,
    upstream: Upstream,
    url: []const u8,
    proxy: ?std.process.Child = null,

    pub fn stop(self: *Running, io: std.Io) void {
        if (self.proxy) |*child| child.kill(io);
    }
};

pub fn start(arena: std.mem.Allocator, io: std.Io, client: *std.http.Client, gateway: Gateway, environ: *const std.process.Environ.Map) !Running {
    var running: Running = .{
        .name = gateway.name,
        .server = undefined,
        .upstream = .{ .client = client, .url = gateway.upstream, .auth = null },
        .url = undefined,
    };
    switch (gateway.auth) {
        .header => |header| running.upstream.auth = try resolveHeader(arena, header, environ),
        .proxy => |proxy| {
            const proxy_port = try freePort(io);
            running.proxy = try startProxy(arena, io, proxy, proxy_port, environ);
            running.upstream.url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{proxy_port});
        },
    }
    errdefer running.stop(io);

    running.server = try listen(io);
    running.url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{port(&running.server)});
    return running;
}

fn freePort(io: std.Io) !u16 {
    var server = try listen(io);
    defer server.deinit(io);
    return port(&server);
}

fn startProxy(arena: std.mem.Allocator, io: std.Io, proxy: @FieldType(Auth, "proxy"), proxy_port: u16, environ: *const std.process.Environ.Map) !std.process.Child {
    const port_text = try std.fmt.allocPrint(arena, "{d}", .{proxy_port});
    const argv = try arena.alloc([]const u8, proxy.argv.len);
    for (proxy.argv, argv) |arg, *out| out.* = try std.mem.replaceOwned(u8, arena, arg, "{port}", port_text);

    var proxy_environ = try environ.clone(arena);
    var it = proxy.env.map.iterator();
    while (it.next()) |entry| try proxy_environ.put(entry.key_ptr.*, entry.value_ptr.*);

    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = &proxy_environ, .stdin = .ignore, .stdout = .ignore });
    errdefer child.kill(io);

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", proxy_port);
    for (0..50) |_| {
        if (address.connect(io, .{ .mode = .stream })) |conn| {
            conn.close(io);
            return child;
        } else |_| try io.sleep(.fromMilliseconds(100), .awake);
    }
    return error.ProxyNotListening;
}

/// Env vars the preset declares for the running gateways, with `{url}` filled in.
pub fn environFor(arena: std.mem.Allocator, entries: []const Env, running: []const Running) ![]const std.http.Header {
    var vars: std.ArrayList(std.http.Header) = .empty;
    for (entries) |entry| for (running) |gateway| {
        if (!std.mem.eql(u8, entry.gateway, gateway.name)) continue;
        try vars.append(arena, .{ .name = entry.name, .value = try std.mem.replaceOwned(u8, arena, entry.value, "{url}", gateway.url) });
    };
    return vars.items;
}

pub const Env = struct {
    gateway: []const u8,
    name: []const u8,
    value: []const u8,
};

/// Serves each connection on its own thread: a streamed answer must not hold up the next request.
pub fn serveLoop(io: std.Io, gpa: std.mem.Allocator, server: *std.Io.net.Server, upstream: *const Upstream) void {
    while (true) {
        const conn = server.accept(io) catch |err| {
            std.log.err("gateway: {t}", .{err});
            continue;
        };
        const thread = std.Thread.spawn(.{}, handleLogged, .{ io, gpa, conn, upstream }) catch |err| {
            std.log.err("gateway: {t}", .{err});
            conn.close(io);
            continue;
        };
        thread.detach();
    }
}

fn handleLogged(io: std.Io, gpa: std.mem.Allocator, conn: std.Io.net.Stream, upstream: *const Upstream) void {
    handle(io, gpa, conn, upstream) catch |err| std.log.err("gateway: {t}", .{err});
}

pub fn serve(io: std.Io, gpa: std.mem.Allocator, server: *std.Io.net.Server, upstream: *const Upstream) !void {
    try handle(io, gpa, try server.accept(io), upstream);
}

fn handle(io: std.Io, gpa: std.mem.Allocator, conn: std.Io.net.Stream, upstream: *const Upstream) !void {
    defer conn.close(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var rbuf: [max_head_len]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = conn.reader(io, &rbuf);
    var writer = conn.writer(io, &wbuf);

    var http = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try http.receiveHead();
    try forward(arena_state.allocator(), &request, upstream);
}

fn forward(arena: std.mem.Allocator, request: *std.http.Server.Request, upstream: *const Upstream) !void {
    const head = request.head;
    if (head.target.len == 0 or head.target[0] != '/') return refuse(request, .bad_request);
    const uri = std.Uri.parse(try std.mem.concat(arena, u8, &.{ upstream.url, head.target })) catch return refuse(request, .bad_request);

    var out = upstream.client.request(head.method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{ .authorization = .omit, .user_agent = .omit, .accept_encoding = .omit, .content_type = .omit },
        .extra_headers = try requestHeaders(arena, request.iterateHeaders(), upstream.auth),
    }) catch return refuse(request, .bad_gateway);
    defer out.deinit();

    if (!head.method.requestHasBody()) {
        try out.sendBodiless();
    } else if (head.content_length == null and head.transfer_encoding == .none) {
        var empty: [0]u8 = .{};
        try out.sendBodyComplete(&empty);
    } else {
        out.transfer_encoding = if (head.content_length) |len| .{ .content_length = len } else .chunked;
        var send_buf: [4096]u8 = undefined;
        var body = try out.sendBody(&send_buf);
        var body_buf: [4096]u8 = undefined;
        _ = try (try request.readerExpectContinue(&body_buf)).streamRemaining(&body.writer);
        try body.end();
    }

    var redirect_buf: [1024]u8 = undefined;
    var response = out.receiveHead(&redirect_buf) catch return refuse(request, .bad_gateway);

    var reply_buf: [4096]u8 = undefined;
    var reply = try request.respondStreaming(&reply_buf, .{
        .content_length = response.head.content_length,
        .respond_options = .{
            .status = response.head.status,
            .reason = try arena.dupe(u8, response.head.reason),
            .keep_alive = false,
            .extra_headers = try responseHeaders(arena, response.head.iterateHeaders()),
        },
    });

    // Flush after every read so streamed model output reaches the agent as it arrives.
    var transfer_buf: [4096]u8 = undefined;
    const body = response.reader(&transfer_buf);
    while (true) {
        _ = body.stream(&reply.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try reply.writer.flush();
        try reply.flush();
    }
    try reply.end();
}

fn refuse(request: *std.http.Server.Request, status: std.http.Status) !void {
    try request.respond("", .{ .status = status, .keep_alive = false });
}

fn requestHeaders(arena: std.mem.Allocator, it: std.http.HeaderIterator, auth: ?std.http.Header) ![]const std.http.Header {
    var headers: std.ArrayList(std.http.Header) = .empty;
    var iter = it;
    while (iter.next()) |header| {
        if (isAny(header.name, &hop_by_hop) or isAny(header.name, &credential_headers)) continue;
        if (auth) |own| if (std.ascii.eqlIgnoreCase(header.name, own.name)) continue;
        try headers.append(arena, try dupeHeader(arena, header));
    }
    if (auth) |own| try headers.append(arena, own);
    return headers.items;
}

fn responseHeaders(arena: std.mem.Allocator, it: std.http.HeaderIterator) ![]const std.http.Header {
    var headers: std.ArrayList(std.http.Header) = .empty;
    var iter = it;
    while (iter.next()) |header| {
        if (isAny(header.name, &hop_by_hop)) continue;
        try headers.append(arena, try dupeHeader(arena, header));
    }
    return headers.items;
}

fn dupeHeader(arena: std.mem.Allocator, header: std.http.Header) !std.http.Header {
    return .{ .name = try arena.dupe(u8, header.name), .value = try arena.dupe(u8, header.value) };
}

fn isAny(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

const FakeUpstream = struct {
    server: std.Io.net.Server,
    head: [max_head_len]u8 = undefined,
    head_len: usize = 0,
    body: [256]u8 = undefined,
    body_len: usize = 0,

    fn run(self: *FakeUpstream) void {
        self.serveOnce() catch {};
    }

    fn serveOnce(self: *FakeUpstream) !void {
        const io = std.testing.io;
        const conn = try self.server.accept(io);
        defer conn.close(io);

        var rbuf: [max_head_len]u8 = undefined;
        var wbuf: [1024]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        var writer = conn.writer(io, &wbuf);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try http.receiveHead();

        @memcpy(self.head[0..request.head_buffer.len], request.head_buffer);
        self.head_len = request.head_buffer.len;
        var body_buf: [256]u8 = undefined;
        self.body_len = try (try request.readerExpectContinue(&body_buf)).readSliceShort(&self.body);

        try request.respond("hello", .{ .status = .created, .keep_alive = false, .extra_headers = &.{.{ .name = "x-upstream", .value = "yes" }} });
    }

    fn receivedHead(self: *const FakeUpstream) []const u8 {
        return self.head[0..self.head_len];
    }
};

fn serveOnce(server: *std.Io.net.Server, upstream: *const Upstream) void {
    serve(std.testing.io, std.testing.allocator, server, upstream) catch {};
}

/// Sends `raw` to the gateway as the agent would and returns everything it answers.
fn send(server: *const std.Io.net.Server, raw: []const u8, response: []u8) ![]const u8 {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port(server));
    const conn = try address.connect(io, .{ .mode = .stream });
    defer conn.close(io);

    var wbuf: [1024]u8 = undefined;
    var writer = conn.writer(io, &wbuf);
    try writer.interface.writeAll(raw);
    try writer.interface.flush();

    var rbuf: [1024]u8 = undefined;
    var reader = conn.reader(io, &rbuf);
    return response[0..try reader.interface.readSliceShort(response)];
}

fn testUpstream(client: *std.http.Client, url: []const u8) Upstream {
    return .{ .client = client, .url = url, .auth = .{ .name = "x-api-key", .value = "sk-from-broker" } };
}

test "forwards a request with the gateway's auth instead of the sandbox's" {
    var fake: FakeUpstream = .{ .server = try listen(std.testing.io) };
    defer fake.server.deinit(std.testing.io);
    const fake_thread = try std.Thread.spawn(.{}, FakeUpstream.run, .{&fake});

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const upstream = testUpstream(&client, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{port(&fake.server)}));

    var server = try listen(std.testing.io);
    defer server.deinit(std.testing.io);
    const gateway_thread = try std.Thread.spawn(.{}, serveOnce, .{ &server, &upstream });

    var response_buf: [1024]u8 = undefined;
    const response = try send(&server, "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Api-Key: sk-from-sandbox\r\nAuthorization: Bearer sandbox\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}", &response_buf);
    gateway_thread.join();
    fake_thread.join();

    const head = fake.receivedHead();
    try std.testing.expect(std.mem.startsWith(u8, head, "POST /v1/messages HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head, "x-api-key: sk-from-broker\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "sk-from-sandbox") == null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(head, "authorization") == null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(head, "content-type: application/json\r\n") != null);
    try std.testing.expectEqualStrings("{}", fake.body[0..fake.body_len]);

    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 201 Created\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, response, "x-upstream: yes\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, response, "\r\n\r\nhello"));
}

test "refuses a target that is not a path" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    const upstream = testUpstream(&client, "http://127.0.0.1:1");

    var server = try listen(std.testing.io);
    defer server.deinit(std.testing.io);
    const gateway_thread = try std.Thread.spawn(.{}, serveOnce, .{ &server, &upstream });

    var response_buf: [1024]u8 = undefined;
    const response = try send(&server, "GET http://evil.example/ HTTP/1.1\r\nHost: evil.example\r\nConnection: close\r\n\r\n", &response_buf);
    gateway_thread.join();

    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
}

test "answers bad gateway when the upstream is unreachable" {
    var unused = try listen(std.testing.io);
    const unreachable_port = port(&unused);
    unused.deinit(std.testing.io);

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const upstream = testUpstream(&client, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{unreachable_port}));

    var server = try listen(std.testing.io);
    defer server.deinit(std.testing.io);
    const gateway_thread = try std.Thread.spawn(.{}, serveOnce, .{ &server, &upstream });

    var response_buf: [1024]u8 = undefined;
    const response = try send(&server, "GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", &response_buf);
    gateway_thread.join();

    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 502 Bad Gateway\r\n"));
}

test "environFor fills in the url of the gateways that run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const running = [_]Running{.{ .name = "anthropic", .server = undefined, .upstream = undefined, .url = "http://127.0.0.1:4711" }};
    const entries = [_]Env{
        .{ .gateway = "anthropic", .name = "ANTHROPIC_BASE_URL", .value = "{url}" },
        .{ .gateway = "anthropic", .name = "ANTHROPIC_AUTH_TOKEN", .value = "zandy-gateway" },
        .{ .gateway = "bedrock", .name = "ANTHROPIC_BEDROCK_BASE_URL", .value = "{url}" },
    };

    const vars = try environFor(arena_state.allocator(), &entries, &running);
    try std.testing.expectEqual(2, vars.len);
    try std.testing.expectEqualStrings("http://127.0.0.1:4711", vars[0].value);
    try std.testing.expectEqualStrings("zandy-gateway", vars[1].value);
}

test "resolveHeader reads the key from zandy's environment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var environ = std.process.Environ.Map.init(arena_state.allocator());
    try environ.put("OPENAI_API_KEY", "sk-x");

    const header = try resolveHeader(arena_state.allocator(), .{ .name = "authorization", .env = "OPENAI_API_KEY", .prefix = "Bearer " }, &environ);
    try std.testing.expectEqualStrings("Bearer sk-x", header.value);

    try std.testing.expectError(error.MissingAuthEnv, resolveHeader(arena_state.allocator(), .{ .name = "x-api-key", .env = "ANTHROPIC_API_KEY" }, &environ));

    try environ.put("ANTHROPIC_API_KEY", "sk-x\r\nx-injected: 1");
    try std.testing.expectError(error.InvalidAuthValue, resolveHeader(arena_state.allocator(), .{ .name = "x-api-key", .env = "ANTHROPIC_API_KEY" }, &environ));
}
