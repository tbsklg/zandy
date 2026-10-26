const std = @import("std");
const sbpl = @import("sbpl.zig");
const registry = @import("registry.zig");

pub const Preset = struct {
    name: []const u8,
    binary: [:0]const u8,
    env: []const []const u8 = &.{},
    args: []const [:0]const u8 = &.{},
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
    policy: registry.Policy = .{},
    filesystem: FileSystem = .{},
};

pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !Manifest {
    return std.json.parseFromSliceLeaky(Manifest, arena, bytes, .{ .allocate = .alloc_always });
}

test "parses a manifest and defaults policy and filesystem" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const manifest = try parse(arena_state.allocator(),
        \\{"preset":{"name":"claude","binary":"claude","env":["HOME"],"args":["--verbose"],
        \\  "profile":{"rules":[
        \\    {"action":"allow","operation":"file_all","filter":{"subpath":{"param_append":{"param":"HOME","suffix":"/.claude"}}}},
        \\    {"action":"allow","operation":"process_fork"}
        \\  ]}},
        \\ "adapters":[{"name":"gitlab","binary":"/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-glab-1.0/bin/glab","env":["GITLAB_TOKEN"],
        \\   "capabilities":[{"name":"cli","description":"Run glab","effect":"admin","params":[{"name":"args","kind":"list"}],"argv":["{args}"]}]}]}
    );

    try std.testing.expectEqualStrings("claude", manifest.preset.binary);
    try std.testing.expectEqualStrings("--verbose", manifest.preset.args[0]);
    try std.testing.expectEqualStrings("/.claude", manifest.preset.profile.rules[0].filter.?.subpath.param_append.suffix);
    try std.testing.expectEqual(null, manifest.preset.profile.rules[1].filter);
    try std.testing.expectEqualStrings("gitlab", manifest.adapters[0].name);
    try std.testing.expectEqual(.deny, manifest.policy.admin);
    try std.testing.expectEqual(0, manifest.filesystem.allowWrite.len);
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
