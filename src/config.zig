const std = @import("std");
const registry = @import("registry.zig");
const Backend = @import("backend.zig").Backend;

const Config = @This();

pub const global_dir = ".config/zandy";
pub const local_file = ".zandy.json";
const config_path = global_dir ++ "/config.json";

filesystem: ?FileSystem,
policy: registry.Policy = .{},
backend: Backend = .anthropic,
sources: []const []const u8 = &.{},
adapters: registry.AdapterSettings = .{},

pub const FileSystem = struct {
    allowRead: []const []const u8,
    denyRead: []const []const u8,
    allowWrite: []const []const u8,
    denyWrite: []const []const u8,
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, home: []const u8, cwd: []const u8) !?Config {
    const paths = [_][]const u8{
        try std.fs.path.join(allocator, &.{ home, config_path }),
        try std.fs.path.join(allocator, &.{ cwd, local_file }),
    };
    var layers: [paths.len]?std.json.ObjectMap = undefined;
    var sources: std.ArrayList([]const u8) = .empty;
    for (paths, &layers) |path, *layer| {
        layer.* = read_json(allocator, io, path);
        if (layer.* != null) try sources.append(allocator, path);
    }
    if (sources.items.len == 0) return null;

    var cfg = try from_object(allocator, try merge(allocator, &layers));
    cfg.sources = sources.items;
    return cfg;
}

fn merge(allocator: std.mem.Allocator, layers: []const ?std.json.ObjectMap) !std.json.ObjectMap {
    var root: std.json.ObjectMap = .empty;
    for (layers) |layer| {
        var it = (layer orelse continue).iterator();
        while (it.next()) |entry| try root.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
    return root;
}

fn read_json(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?std.json.ObjectMap {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{ .allocate = .alloc_always }) catch return null;
    return if (value == .object) value.object else null;
}

fn from_json(allocator: std.mem.Allocator, raw: []const u8) !Config {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{ .allocate = .alloc_always });
    return from_object(allocator, value.object);
}

fn from_object(allocator: std.mem.Allocator, root: std.json.ObjectMap) !Config {
    const policy: registry.Policy = if (root.get("policy")) |v| try std.json.parseFromValueLeaky(registry.Policy, allocator, v, .{}) else .{};
    const backend: Backend = if (root.get("backend")) |v| try std.json.parseFromValueLeaky(Backend, allocator, v, .{}) else .anthropic;
    const adapters: registry.AdapterSettings = if (root.get("adapters")) |v| try std.json.parseFromValueLeaky(registry.AdapterSettings, allocator, v, .{}) else .{};
    const fs_val = root.get("filesystem") orelse return .{ .filesystem = null, .policy = policy, .backend = backend, .adapters = adapters };
    const file_system = fs_val.object;

    return .{
        .filesystem = .{
            .allowRead = try parse_string_array(allocator, file_system.get("allowRead")),
            .denyRead = try parse_string_array(allocator, file_system.get("denyRead")),
            .allowWrite = try parse_string_array(allocator, file_system.get("allowWrite")),
            .denyWrite = try parse_string_array(allocator, file_system.get("denyWrite")),
        },
        .policy = policy,
        .backend = backend,
        .adapters = adapters,
    };
}

fn parse_string_array(allocator: std.mem.Allocator, val: ?std.json.Value) ![]const []const u8 {
    const arr = if (val) |v| v.array else return &[_][]const u8{};
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    for (arr.items) |item| {
        try list.append(allocator, item.string);
    }
    return try list.toOwnedSlice(allocator);
}

test "policy is read from config and defaults the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const cfg = try from_json(arena_state.allocator(),
        \\{"policy":{"admin":"allow"}}
    );

    try std.testing.expectEqual(.allow, cfg.policy.admin);
    try std.testing.expectEqual(.ask, cfg.policy.write);
}

test "backend is read from config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const cfg = try from_json(arena_state.allocator(),
        \\{"backend":{"bedrock":{"profile":"acme","region":"eu-west-1"}}}
    );

    try std.testing.expectEqualStrings("acme", cfg.backend.bedrock.profile);
}

test "backend defaults to anthropic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const cfg = try from_json(arena_state.allocator(), "{}");

    try std.testing.expectEqual(.anthropic, cfg.backend);
}

test "unknown backend is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.UnknownField, from_json(arena_state.allocator(),
        \\{"backend":{"acme":{}}}
    ));
}

test "project config keeps the global backend and replaces the keys it sets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const global = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"backend":{"bedrock":{"profile":"acme","region":"eu-west-1"}},"policy":{"admin":"allow"}}
    , .{});
    const local = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"policy":{"write":"allow"},"filesystem":{"allowRead":["/abs/allow"]}}
    , .{});

    const cfg = try from_object(arena, try merge(arena, &.{ global.object, local.object }));

    try std.testing.expectEqualStrings("acme", cfg.backend.bedrock.profile);
    try std.testing.expectEqual(.allow, cfg.policy.write);
    try std.testing.expectEqual(.deny, cfg.policy.admin);
    try std.testing.expectEqualStrings("/abs/allow", cfg.filesystem.?.allowRead[0]);
}

test "adapter choices are read from config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const cfg = try from_json(arena_state.allocator(),
        \\{"adapters":{"aws":{"profile":["acme-dev","acme-int"]}}}
    );

    try std.testing.expectEqualStrings("acme-int", cfg.adapters.map.get("aws").?.map.get("profile").?[1]);
}
