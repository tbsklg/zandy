const std = @import("std");
const command = @import("command.zig");

pub const Effect = enum { read, write, admin };

pub const Decision = enum { allow, ask, deny };

pub const Policy = struct {
    read: Decision = .allow,
    write: Decision = .ask,
    admin: Decision = .deny,

    pub fn decide(self: Policy, effect: Effect) Decision {
        return switch (effect) {
            .read => self.read,
            .write => self.write,
            .admin => self.admin,
        };
    }
};

pub const Param = struct {
    name: []const u8,
    kind: enum { string, list, choice } = .string,
    description: ?[]const u8 = null,
    choices: []const []const u8 = &.{},
};

pub const CapabilityConfig = struct {
    name: []const u8,
    description: []const u8,
    effect: Effect,
    params: []const Param = &.{},
    argv: []const []const u8,
};

pub const Adapter = struct {
    name: []const u8,
    binary: []const u8,
    env: []const []const u8 = &.{},
    capabilities: []const CapabilityConfig,
};

pub const Capability = struct {
    name: []const u8,
    description: []const u8 = "",
    effect: Effect,
    params: []const Param = &.{},
    binary: []const u8,
    env: []const []const u8 = &.{},
    argv: []const command.Segment = &.{},
};

pub fn parseAdapters(arena: std.mem.Allocator, adapters: []const Adapter) ![]const Capability {
    var capabilities: std.ArrayList(Capability) = .empty;
    for (adapters) |adapter| {
        next: for (adapter.capabilities) |config| {
            const params = config.params;
            for (params) |param| {
                if (param.kind == .choice and param.choices.len == 0) continue :next;
            }
            try capabilities.append(arena, .{
                .name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ adapter.name, config.name }),
                .description = config.description,
                .effect = config.effect,
                .params = params,
                .binary = adapter.binary,
                .env = adapter.env,
                .argv = try command.parseTemplate(arena, params, config.argv),
            });
        }
    }
    return capabilities.items;
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

    pub fn discover(self: Registry, arena: std.mem.Allocator, policy: Policy) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;

        try w.writeAll("{\"version\":\"1\",\"methods\":[");
        var first = true;
        for (self.capabilities) |cap| {
            if (policy.decide(cap.effect) != .allow) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("{{\"name\":{f},\"description\":{f},\"effect\":{f},\"params\":", .{
                std.json.fmt(cap.name, .{}),
                std.json.fmt(cap.description, .{}),
                std.json.fmt(@tagName(cap.effect), .{}),
            });
            try writeSchema(w, cap.params);
            try w.writeAll("}");
        }
        try w.writeAll("]}");

        return out.written();
    }

    pub fn find(self: Registry, name: []const u8, policy: Policy) ?Capability {
        for (self.capabilities) |cap| {
            if (policy.decide(cap.effect) != .allow) continue;
            if (std.mem.eql(u8, cap.name, name)) return cap;
        }
        return null;
    }
};

test "empty registry discovers no methods" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const registry: Registry = .{ .capabilities = &.{} };
    const json = try registry.discover(arena_state.allocator(), .{});

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
            .effect = .read,
            .binary = "glab",
            .params = &.{
                .{ .name = "project", .description = "Project path" },
                .{ .name = "issue" },
            },
        },
    } };
    const json = try registry.discover(arena_state.allocator(), .{});

    try std.testing.expectEqualStrings(
        \\{"version":"1","methods":[{"name":"issues.list","description":"List issues.","effect":"read","params":{"type":"object","properties":{"project":{"type":"string","description":"Project path"},"issue":{"type":"string"}},"required":["project","issue"]}}]}
    , json);
}

test "only capabilities allowed by the policy are discovered" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const registry: Registry = .{ .capabilities = &.{
        .{ .name = "issues.list", .effect = .read, .binary = "glab" },
        .{ .name = "issues.close", .effect = .write, .binary = "glab" },
        .{ .name = "project.delete", .effect = .admin, .binary = "glab" },
    } };
    const json = try registry.discover(arena_state.allocator(), .{});

    try std.testing.expectEqualStrings(
        \\{"version":"1","methods":[{"name":"issues.list","description":"","effect":"read","params":{"type":"object","properties":{},"required":[]}}]}
    , json);
}

test "find returns only capabilities allowed by the policy" {
    const registry: Registry = .{ .capabilities = &.{
        .{ .name = "issues.list", .effect = .read, .binary = "glab" },
        .{ .name = "issues.close", .effect = .write, .binary = "glab" },
    } };

    try std.testing.expectEqualStrings("issues.list", registry.find("issues.list", .{}).?.name);
    try std.testing.expectEqual(null, registry.find("issues.close", .{}));
    try std.testing.expectEqual(null, registry.find("issues.delete", .{}));
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
            .effect = .read,
            .params = &.{.{ .name = "project" }},
            .argv = &.{ "issue", "list", "--repo", "{project}" },
        }},
    }};

    const capabilities = try parseAdapters(arena_state.allocator(), &adapters);

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
            .effect = .read,
            .params = &.{.{ .name = "project" }},
            .argv = &.{ "--repo", "{repo}" },
        }},
    }};

    try std.testing.expectError(error.UnknownPlaceholder, parseAdapters(arena_state.allocator(), &adapters));
}

fn awsAdapter(comptime choices: []const []const u8) Adapter {
    return .{
        .name = "aws",
        .binary = "/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-awscli2-2.0/bin/aws",
        .capabilities = &.{.{
            .name = "cli",
            .description = "Run aws.",
            .effect = .admin,
            .params = &.{ .{ .name = "profile", .kind = .choice, .choices = choices }, .{ .name = "args", .kind = .list } },
            .argv = &.{ "{args}", "--profile", "{profile}" },
        }},
    };
}

test "parseAdapters keeps a choice param's values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const adapters = [_]Adapter{awsAdapter(&.{ "acme-dev", "acme-int" })};
    const capabilities = try parseAdapters(arena_state.allocator(), &adapters);

    try std.testing.expectEqualStrings("aws.cli", capabilities[0].name);
    try std.testing.expectEqualStrings("acme-int", capabilities[0].params[0].choices[1]);
}

test "parseAdapters drops a capability whose choice param has no values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const adapters = [_]Adapter{awsAdapter(&.{})};
    const capabilities = try parseAdapters(arena_state.allocator(), &adapters);

    try std.testing.expectEqual(0, capabilities.len);
}
