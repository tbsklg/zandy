const std = @import("std");
const command = @import("command.zig");
const secret = @import("../secret.zig");

pub const Param = struct {
    name: []const u8,
    kind: enum { string, list, choice } = .string,
    description: ?[]const u8 = null,
    choices: []const []const u8 = &.{},
};

pub const CapabilityConfig = struct {
    name: []const u8,
    description: []const u8,
    params: []const Param = &.{},
    argv: []const []const u8,
};

pub const Adapter = struct {
    name: []const u8,
    binary: []const u8,
    env: []const []const u8 = &.{},
    setEnv: std.json.ArrayHashMap([]const u8) = .{},
    secrets: secret.Sources = .{},
    files: secret.Files = .{},
    capabilities: []const CapabilityConfig,
};

pub const Capability = struct {
    name: []const u8,
    description: []const u8 = "",
    params: []const Param = &.{},
    binary: []const u8,
    env: []const []const u8 = &.{},
    set_env: []const std.http.Header = &.{},
    argv: []const command.Segment = &.{},
    pipes: []const secret.Pipe = &.{},
};

pub fn parseAdapters(arena: std.mem.Allocator, adapters: []const Adapter, pipes: []const []const secret.Pipe, session_dir: []const u8) ![]const Capability {
    var capabilities: std.ArrayList(Capability) = .empty;
    for (adapters, pipes) |adapter, adapter_pipes| {
        const set_env = try setEnvIn(arena, adapter, session_dir);
        next: for (adapter.capabilities) |config| {
            const params = config.params;
            for (params) |param| {
                if (param.kind == .choice and param.choices.len == 0) continue :next;
            }
            try capabilities.append(arena, .{
                .name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ adapter.name, config.name }),
                .description = config.description,
                .params = params,
                .binary = adapter.binary,
                .env = adapter.env,
                .set_env = set_env,
                .argv = try command.parseTemplate(arena, params, config.argv),
                .pipes = adapter_pipes,
            });
        }
    }
    return capabilities.items;
}

pub fn dirFor(arena: std.mem.Allocator, session_dir: []const u8, adapter: Adapter) ![]const u8 {
    return secret.dirFor(arena, session_dir, try std.fmt.allocPrint(arena, "adapter-{s}", .{adapter.name}));
}

fn setEnvIn(arena: std.mem.Allocator, adapter: Adapter, session_dir: []const u8) ![]const std.http.Header {
    const dir = try dirFor(arena, session_dir, adapter);
    const vars = try arena.alloc(std.http.Header, adapter.setEnv.map.count());
    for (adapter.setEnv.map.keys(), adapter.setEnv.map.values(), vars) |name, value, *slot| {
        slot.* = .{ .name = name, .value = try secret.withDir(arena, value, dir) };
    }
    return vars;
}

fn writeSchema(w: *std.Io.Writer, params: []const Param) !void {
    try w.writeAll("{\"type\":\"object\",\"properties\":{");
    for (params, 0..) |param, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{f}:{{", .{std.json.fmt(param.name, .{})});
        try w.writeAll(switch (param.kind) {
            .string => "\"type\":\"string\"",
            .list => "\"type\":\"array\",\"items\":{\"type\":\"string\"}",
            .choice => "\"type\":\"string\"",
        });
        if (param.kind == .choice) try w.print(",\"enum\":{f}", .{std.json.fmt(param.choices, .{})});
        if (param.description) |description| try w.print(",\"description\":{f}", .{std.json.fmt(description, .{})});
        try w.writeAll("}");
    }
    try w.writeAll("},\"required\":[");
    for (params, 0..) |param, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{f}", .{std.json.fmt(param.name, .{})});
    }
    try w.writeAll("]}");
}

pub const Registry = struct {
    capabilities: []const Capability,

    pub fn discover(self: Registry, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;

        try w.writeAll("{\"version\":\"1\",\"methods\":[");
        var first = true;
        for (self.capabilities) |cap| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("{{\"name\":{f},\"description\":{f},\"params\":", .{
                std.json.fmt(cap.name, .{}),
                std.json.fmt(cap.description, .{}),
            });
            try writeSchema(w, cap.params);
            try w.writeAll("}");
        }
        try w.writeAll("]}");

        return out.written();
    }

    pub fn find(self: Registry, name: []const u8) ?Capability {
        for (self.capabilities) |cap| {
            if (std.mem.eql(u8, cap.name, name)) return cap;
        }
        return null;
    }
};

test "empty registry discovers no methods" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const registry: Registry = .{ .capabilities = &.{} };
    const json = try registry.discover(arena_state.allocator());

    try std.testing.expectEqualStrings(
        \\{"version":"1","methods":[]}
    , json);
}

test "registered capability is discovered with its schema" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const registry: Registry = .{ .capabilities = &.{
        .{
            .name = "issues.list",
            .description = "List issues.",
            .binary = "glab",
            .params = &.{
                .{ .name = "project", .description = "Project path" },
                .{ .name = "issue" },
            },
        },
    } };
    const json = try registry.discover(arena_state.allocator());

    try std.testing.expectEqualStrings(
        \\{"version":"1","methods":[{"name":"issues.list","description":"List issues.","params":{"type":"object","properties":{"project":{"type":"string","description":"Project path"},"issue":{"type":"string"}},"required":["project","issue"]}}]}
    , json);
}

test "parseAdapters prefixes names and parses argv templates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const adapters = [_]Adapter{.{
        .name = "gitlab",
        .binary = "glab",
        .env = &.{"GITLAB_TOKEN"},
        .capabilities = &.{.{
            .name = "issues.list",
            .description = "List issues.",
            .params = &.{.{ .name = "project" }},
            .argv = &.{ "issue", "list", "--repo", "{project}" },
        }},
    }};

    const capabilities = try parseAdapters(arena_state.allocator(), &adapters, &.{&.{}}, "/run/1");

    try std.testing.expectEqual(1, capabilities.len);
    try std.testing.expectEqualStrings("gitlab.issues.list", capabilities[0].name);
    try std.testing.expectEqualStrings("glab", capabilities[0].binary);
    try std.testing.expectEqualStrings("GITLAB_TOKEN", capabilities[0].env[0]);
    try std.testing.expectEqual(0, capabilities[0].argv[3].param);
}

test "parseAdapters rejects a template with an unknown placeholder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const adapters = [_]Adapter{.{
        .name = "gitlab",
        .binary = "glab",
        .capabilities = &.{.{
            .name = "issues.list",
            .description = "List issues.",
            .params = &.{.{ .name = "project" }},
            .argv = &.{ "--repo", "{repo}" },
        }},
    }};

    try std.testing.expectError(error.UnknownPlaceholder, parseAdapters(arena_state.allocator(), &adapters, &.{&.{}}, "/run/1"));
}

fn awsAdapter(comptime choices: []const []const u8) Adapter {
    return .{
        .name = "aws",
        .binary = "/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-awscli2-2.0/bin/aws",
        .capabilities = &.{.{
            .name = "cli",
            .description = "Run aws.",
            .params = &.{ .{ .name = "profile", .kind = .choice, .choices = choices }, .{ .name = "args", .kind = .list } },
            .argv = &.{ "{args}", "--profile", "{profile}" },
        }},
    };
}

test "parseAdapters keeps a choice param's values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const adapters = [_]Adapter{awsAdapter(&.{ "acme-dev", "acme-int" })};
    const capabilities = try parseAdapters(arena_state.allocator(), &adapters, &.{&.{}}, "/run/1");

    try std.testing.expectEqualStrings("aws.cli", capabilities[0].name);
    try std.testing.expectEqualStrings("acme-int", capabilities[0].params[0].choices[1]);
}

test "parseAdapters drops a capability whose choice param has no values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const adapters = [_]Adapter{awsAdapter(&.{})};
    const capabilities = try parseAdapters(arena_state.allocator(), &adapters, &.{&.{}}, "/run/1");

    try std.testing.expectEqual(0, capabilities.len);
}

test "parseAdapters points setEnv at the adapter's private dir" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const adapters = try std.json.parseFromSliceLeaky([]const Adapter, arena,
        \\[{"name":"gitlab","binary":"glab","setEnv":{"GLAB_CONFIG_DIR":"{dir}","GITLAB_HOST":"gitlab.com"},
        \\  "capabilities":[{"name":"cli","description":"Run glab.","argv":[]}]}]
    , .{});
    const capabilities = try parseAdapters(arena, adapters, &.{&.{}}, "/run/1");

    try std.testing.expectEqualStrings("GLAB_CONFIG_DIR", capabilities[0].set_env[0].name);
    try std.testing.expectEqualStrings("/run/1/adapter-gitlab", capabilities[0].set_env[0].value);
    try std.testing.expectEqualStrings("gitlab.com", capabilities[0].set_env[1].value);
}
