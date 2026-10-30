const std = @import("std");
const macos = @import("macos.zig");

const log = std.log.scoped(.broker);

pub const Store = enum {
    zandy,
    login,
};

pub const Keychain = struct {
    service: []const u8,
    field: []const []const u8 = &.{},
    store: Store = .zandy,
};

pub const Source = union(enum) {
    keychain: Keychain,
};

pub const Sources = std.json.ArrayHashMap(Source);
pub const Files = std.json.ArrayHashMap([]const u8);

const security = "/usr/bin/security";

pub fn keychainPath(arena: std.mem.Allocator, home: []const u8, store: Store) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, switch (store) {
        .zandy => ".zandy/zandy.keychain-db",
        .login => "Library/Keychains/login.keychain-db",
    } });
}

pub fn dirFor(arena: std.mem.Allocator, session_dir: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ session_dir, name });
}

pub fn withDir(arena: std.mem.Allocator, value: []const u8, dir: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, arena, value, "{dir}", dir);
}

pub const Pipe = struct {
    path: [:0]const u8,
    text: []const u8,
};

pub const max_pipe_text = 4096;

pub fn materialize(arena: std.mem.Allocator, io: std.Io, home: []const u8, dir: []const u8, sources: Sources, files: Files) ![]const Pipe {
    try std.Io.Dir.createDirAbsolute(io, dir, .fromMode(0o700));

    const names = sources.map.keys();
    const values = try readAll(arena, io, home, sources);

    const pipes = try arena.alloc(Pipe, files.map.count());
    for (files.map.keys(), files.map.values(), pipes) |name, template, *pipe| {
        pipe.* = .{
            .path = try std.fs.path.joinZ(arena, &.{ dir, try parseFileName(name) }),
            .text = try parseText(try render(arena, template, names, values)),
        };
        if (macos.mkfifo(pipe.path.ptr, 0o600) != 0) return error.PipeNotCreated;
    }
    return pipes;
}

pub const Feed = struct {
    pipes: []const Pipe,
    threads: []std.Thread,

    pub fn start(arena: std.mem.Allocator, pipes: []const Pipe) !Feed {
        const threads = try arena.alloc(std.Thread, pipes.len);
        for (pipes, threads, 0..) |pipe, *thread, i| {
            thread.* = std.Thread.spawn(.{}, feed, .{pipe}) catch |err| {
                (Feed{ .pipes = pipes[0..i], .threads = threads[0..i] }).finish();
                return err;
            };
        }
        return .{ .pipes = pipes, .threads = threads };
    }

    pub fn finish(self: Feed) void {
        for (self.pipes, self.threads) |pipe, thread| {
            const fd = std.c.open(pipe.path.ptr, .{ .ACCMODE = .RDONLY, .NONBLOCK = true });
            if (fd < 0) {
                thread.detach();
                continue;
            }
            thread.join();
            _ = std.c.close(fd);
        }
    }
};

fn feed(pipe: Pipe) void {
    const fd = std.c.open(pipe.path.ptr, .{ .ACCMODE = .WRONLY, .NOFOLLOW = true });
    if (fd < 0) {
        log.err("{s} could not be opened", .{pipe.path});
        return;
    }
    defer _ = std.c.close(fd);
    var stat: std.c.Stat = undefined;
    if (std.c.fstat(fd, &stat) != 0 or !std.c.S.ISFIFO(stat.mode)) {
        log.err("{s} is not a named pipe", .{pipe.path});
        return;
    }
    if (std.c.fcntl(fd, std.c.F.SETNOSIGPIPE, @as(c_int, 1)) != 0) return;
    var rest = pipe.text;
    while (rest.len > 0) {
        const written = std.c.write(fd, rest.ptr, rest.len);
        if (written <= 0) return;
        rest = rest[@intCast(written)..];
    }
}

fn parseText(text: []const u8) ![]const u8 {
    if (text.len > max_pipe_text) return error.PipeTextTooLarge;
    return text;
}

pub fn readAll(arena: std.mem.Allocator, io: std.Io, home: []const u8, sources: Sources) ![]const []const u8 {
    const values = try arena.alloc([]const u8, sources.map.count());
    for (sources.map.values(), values) |source, *value| value.* = try read(arena, io, home, source);
    return values;
}

fn parseFileName(name: []const u8) ![]const u8 {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidFileName;
    return name;
}

pub fn read(arena: std.mem.Allocator, io: std.Io, home: []const u8, source: Source) ![]const u8 {
    return parseValue(switch (source) {
        .keychain => |keychain| try readKeychain(arena, io, home, keychain),
    });
}

fn parseValue(value: []const u8) ![]const u8 {
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.InvalidSecret;
    return value;
}

fn readKeychain(arena: std.mem.Allocator, io: std.Io, home: []const u8, keychain: Keychain) ![]const u8 {
    const path = try keychainPath(arena, home, keychain.store);
    const result = try std.process.run(arena, io, .{ .argv = &.{ security, "find-generic-password", "-s", keychain.service, "-w", path } });
    const found = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!found) {
        switch (keychain.store) {
            .zandy => std.debug.print("zandy: no secret '{s}' in {s}; store it with `zandy-<name> --zandy-secret {s}`\n", .{ keychain.service, path, keychain.service }),
            .login => std.debug.print("zandy: no item '{s}' in the login keychain\n", .{keychain.service}),
        }
        return error.NoKeychainItem;
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

pub fn render(arena: std.mem.Allocator, template: []const u8, names: []const []const u8, values: []const []const u8) ![]const u8 {
    const open = "{secret.";
    var out: std.ArrayList(u8) = .empty;
    var rest = template;
    while (std.mem.indexOf(u8, rest, open)) |start| {
        const end = std.mem.indexOfScalarPos(u8, rest, start, '}') orelse return error.UnknownSecret;
        const name = rest[start + open.len .. end];
        const value = for (names, values) |candidate, value| {
            if (std.mem.eql(u8, candidate, name)) break value;
        } else return error.UnknownSecret;
        try out.appendSlice(arena, rest[0..start]);
        try out.appendSlice(arena, value);
        rest = rest[end + 1 ..];
    }
    try out.appendSlice(arena, rest);
    return out.items;
}

pub fn set(arena: std.mem.Allocator, io: std.Io, home: []const u8, service: []const u8) !void {
    const quoted_service = try parseQuotable(service);
    const path = try keychainPath(arena, home, .zandy);
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("zandy: no keychain at {s}; create it once with\n  security create-keychain {s}\n  security set-keychain-settings {s}\n", .{ path, path, path });
            return error.NoKeychain;
        },
        else => return err,
    };

    const value = try parseQuotable(try parseValue(try prompt(arena, io, service)));
    var child = try std.process.spawn(io, .{ .argv = &.{ security, "-i" }, .stdin = .pipe, .stdout = .ignore });
    var buf: [256]u8 = undefined;
    var writer = child.stdin.?.writer(io, &buf);
    try writer.interface.print("add-generic-password -U -a zandy -s \"{s}\" -w \"{s}\" \"{s}\"\n", .{ quoted_service, value, path });
    try writer.interface.flush();
    child.stdin.?.close(io);
    child.stdin = null;
    _ = try child.wait(io);

    const check = try std.process.run(arena, io, .{ .argv = &.{ security, "find-generic-password", "-s", service, path } });
    switch (check.term) {
        .exited => |code| if (code != 0) return error.NotStored,
        else => return error.NotStored,
    }
}

fn parseQuotable(value: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, value, "\"\\") != null) return error.UnquotableValue;
    return value;
}

fn prompt(arena: std.mem.Allocator, io: std.Io, service: []const u8) ![]const u8 {
    const stdin = std.Io.File.stdin();
    const tty = try stdin.isTty(io);
    std.debug.print("secret for '{s}': ", .{service});

    const original = if (tty) try std.posix.tcgetattr(stdin.handle) else undefined;
    if (tty) {
        var silent = original;
        silent.lflag.ECHO = false;
        try std.posix.tcsetattr(stdin.handle, .FLUSH, silent);
    }
    defer if (tty) {
        std.posix.tcsetattr(stdin.handle, .FLUSH, original) catch {};
        std.debug.print("\n", .{});
    };

    var buf: [4096]u8 = undefined;
    var reader = stdin.reader(io, &buf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => reader.interface.buffered(),
        else => return err,
    };
    return arena.dupe(u8, line);
}

test "keychainPath names the zandy and the login keychain" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("/Users/acme/.zandy/zandy.keychain-db", try keychainPath(arena, "/Users/acme", .zandy));
    try std.testing.expectEqualStrings("/Users/acme/Library/Keychains/login.keychain-db", try keychainPath(arena, "/Users/acme", .login));
}

test "parses keychain sources with zandy as the default store" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const sources = try std.json.parseFromSliceLeaky(Sources, arena_state.allocator(),
        \\{"GITLAB_TOKEN":{"keychain":{"service":"gitlab-token"}},
        \\ "TOKEN":{"keychain":{"service":"Claude Code-credentials","store":"login","field":["claudeAiOauth","accessToken"]}}}
    , .{});
    const gitlab = sources.map.get("GITLAB_TOKEN").?.keychain;
    try std.testing.expectEqual(.zandy, gitlab.store);
    try std.testing.expectEqual(0, gitlab.field.len);
    const claude = sources.map.get("TOKEN").?.keychain;
    try std.testing.expectEqual(.login, claude.store);
    try std.testing.expectEqualStrings("accessToken", claude.field[1]);
}

test "jsonField follows the path to a string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const token = try jsonField(arena_state.allocator(), "{\"claudeAiOauth\":{\"accessToken\":\"sk-ant-oat\"}}", &.{ "claudeAiOauth", "accessToken" });
    try std.testing.expectEqualStrings("sk-ant-oat", token);
}

test "jsonField rejects a missing field, a non-string value and invalid json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.NoKeychainField, jsonField(arena, "{\"claudeAiOauth\":{}}", &.{ "claudeAiOauth", "accessToken" }));
    try std.testing.expectError(error.NoKeychainField, jsonField(arena, "{\"claudeAiOauth\":{\"accessToken\":1}}", &.{ "claudeAiOauth", "accessToken" }));
    try std.testing.expectError(error.NoKeychainField, jsonField(arena, "not json", &.{"claudeAiOauth"}));
}

test "parseValue rejects empty and multi-line secrets" {
    try std.testing.expectEqualStrings("glpat-abc", try parseValue("glpat-abc"));
    try std.testing.expectError(error.InvalidSecret, parseValue(""));
    try std.testing.expectError(error.InvalidSecret, parseValue("a\nINJECTED=1"));
}

test "render fills in secrets and keeps other placeholders" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const out = try render(arena_state.allocator(), "TOKEN={secret.TOKEN}\nPORT={env.PORT}\n", &.{"TOKEN"}, &.{"tok-1"});
    try std.testing.expectEqualStrings("TOKEN=tok-1\nPORT={env.PORT}\n", out);
}

test "render rejects an unknown secret" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.UnknownSecret, render(arena_state.allocator(), "{secret.MISSING}", &.{"TOKEN"}, &.{"tok-1"}));
}

test "parseFileName only accepts a plain name" {
    try std.testing.expectEqualStrings("config.yml", try parseFileName("config.yml"));
    try std.testing.expectError(error.InvalidFileName, parseFileName("../config.yml"));
    try std.testing.expectError(error.InvalidFileName, parseFileName(".."));
    try std.testing.expectError(error.InvalidFileName, parseFileName(""));
}

fn testPipes(arena: std.mem.Allocator, tmp: std.testing.TmpDir) ![]const Pipe {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const dir = try std.fs.path.join(arena, &.{ dir_buf[0..len], "gateway" });
    const files = try std.json.parseFromSliceLeaky(Files, arena, "{\"plain.txt\":\"no secrets\"}", .{});
    return materialize(arena, std.testing.io, "/Users/acme", dir, .{}, files);
}

test "materialize creates named pipes only the owner can open, with the rendered text kept in memory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pipes = try testPipes(arena_state.allocator(), tmp);

    try std.testing.expectEqualStrings("no secrets", pipes[0].text);
    const dir_stat = try tmp.dir.statFile(std.testing.io, "gateway", .{});
    try std.testing.expectEqual(0o700, dir_stat.permissions.toMode() & 0o777);
    const pipe_stat = try tmp.dir.statFile(std.testing.io, "gateway/plain.txt", .{});
    try std.testing.expectEqual(.named_pipe, pipe_stat.kind);
    try std.testing.expectEqual(0o600, pipe_stat.permissions.toMode() & 0o777);
}

test "a feed hands the text to the reader of the pipe" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const feed_state = try Feed.start(arena, try testPipes(arena, tmp));
    defer feed_state.finish();

    try std.testing.expectEqualStrings("no secrets", try tmp.dir.readFileAlloc(std.testing.io, "gateway/plain.txt", arena, .limited(max_pipe_text)));
}

test "a feed finishes when nobody reads the pipe" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const feed_state = try Feed.start(arena, try testPipes(arena, tmp));
    feed_state.finish();
}

test "parseText rejects text that might not fit the pipe's buffer" {
    try std.testing.expectEqualStrings("short", try parseText("short"));
    try std.testing.expectError(error.PipeTextTooLarge, parseText(&([_]u8{'x'} ** (max_pipe_text + 1))));
}

test "withDir fills in the private dir" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectEqualStrings("/run/1/gateway/secrets.env", try withDir(arena_state.allocator(), "{dir}/secrets.env", "/run/1/gateway"));
}
