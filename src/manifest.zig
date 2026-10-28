const std = @import("std");
const sbpl = @import("sbpl.zig");
const registry = @import("registry.zig");
const gateway = @import("gateway.zig");

pub const Preset = struct {
    name: []const u8,
    binary: [:0]const u8,
    env: []const []const u8 = &.{},
    args: []const [:0]const u8 = &.{},
    gatewayEnv: []const gateway.Env = &.{},
    profile: sbpl.Profile,
};

pub const FileSystem = struct {
    allowRead: []const []const u8 = &.{},
    denyRead: []const []const u8 = &.{},
    allowWrite: []const []const u8 = &.{},
    denyWrite: []const []const u8 = &.{},
};

pub const Manifest = struct {
    preset: Preset,
    adapters: []const registry.Adapter = &.{},
    gateway: ?gateway.Gateway = null,
    filesystem: FileSystem = .{},
};

pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !Manifest {
    return std.json.parseFromSliceLeaky(Manifest, arena, bytes, .{ .allocate = .alloc_always });
}

test "parses a manifest and defaults filesystem" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const manifest = try parse(arena_state.allocator(),
        \\{"preset":{"name":"claude","binary":"claude","env":["HOME"],"args":["--verbose"],
        \\  "profile":{"rules":[
        \\    {"action":"allow","operation":"file_all","filter":{"subpath":{"param_append":{"param":"HOME","suffix":"/.claude"}}}},
        \\    {"action":"allow","operation":"process_fork"}
        \\  ]}},
        \\ "adapters":[{"name":"gitlab","binary":"/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-glab-1.0/bin/glab","env":["GITLAB_TOKEN"],
        \\   "capabilities":[{"name":"cli","description":"Run glab","params":[{"name":"args","kind":"list"}],"argv":["{args}"]}]}]}
    );

    try std.testing.expectEqualStrings("claude", manifest.preset.binary);
    try std.testing.expectEqualStrings("--verbose", manifest.preset.args[0]);
    try std.testing.expectEqualStrings("/.claude", manifest.preset.profile.rules[0].filter.?.subpath.param_append.suffix);
    try std.testing.expectEqual(null, manifest.preset.profile.rules[1].filter);
    try std.testing.expectEqualStrings("gitlab", manifest.adapters[0].name);
    try std.testing.expectEqual(0, manifest.filesystem.allowWrite.len);
    try std.testing.expectEqual(null, manifest.gateway);
}

test "parses a gateway behind a proxy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const manifest = try parse(arena_state.allocator(),
        \\{"preset":{"name":"claude","binary":"claude","profile":{}},
        \\ "gateway":{"name":"bedrock","upstream":"https://bedrock-runtime.eu-west-1.amazonaws.com",
        \\   "auth":{"proxy":{"argv":["/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-aws-sigv4-proxy-1.13/bin/aws-sigv4-proxy","--port","127.0.0.1:{port}"],
        \\     "env":{"AWS_PROFILE":"acme-bedrock"}}}}}
    );

    const proxy = manifest.gateway.?.auth.proxy;
    try std.testing.expectEqualStrings("127.0.0.1:{port}", proxy.argv[2]);
    try std.testing.expectEqualStrings("acme-bedrock", proxy.env.map.get("AWS_PROFILE").?);
}

test "parses a gateway with a header and defaults its prefix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const manifest = try parse(arena_state.allocator(),
        \\{"preset":{"name":"claude","binary":"claude","profile":{}},
        \\ "gateway":{"name":"anthropic","upstream":"https://api.anthropic.com",
        \\   "auth":{"header":{"name":"x-api-key","env":"ANTHROPIC_API_KEY"}}}}
    );

    const header = manifest.gateway.?.auth.header;
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", header.env);
    try std.testing.expectEqualStrings("", header.prefix);
}

test "rejects an unknown auth kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.UnknownField, parse(arena_state.allocator(),
        \\{"preset":{"name":"claude","binary":"claude","profile":{}},
        \\ "gateway":{"name":"x","upstream":"https://x","auth":{"token":{"value":"sk-x"}}}}
    ));
}

test "rejects unknown fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.UnknownField, parse(arena_state.allocator(),
        \\{"preset":{"name":"claude","binary":"claude","profile":{}},"secrets":{"GITLAB_TOKEN":"glpat-x"}}
    ));
}

test "rejects an unknown sbpl operation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.InvalidEnumTag, parse(arena_state.allocator(),
        \\{"preset":{"name":"claude","binary":"claude","profile":{"rules":[{"action":"allow","operation":"process_everything"}]}}}
    ));
}
