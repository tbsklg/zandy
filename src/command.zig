const std = @import("std");
const registry = @import("registry.zig");

pub const Value = union(enum) {
    one: []const u8,
    many: []const []const u8,
};

pub const Args = struct {
    values: []const Value,
};

pub const Segment = union(enum) {
    literal: []const u8,
    param: usize,
};

pub fn parseParams(arena: std.mem.Allocator, declared: []const registry.Param, params: std.json.ObjectMap) !Args {
    const values = try arena.alloc(Value, declared.len);
    for (declared, values) |param, *value| {
        const given = params.get(param.name) orelse return error.InvalidParams;
        value.* = switch (param.kind) {
            .string => .{ .one = try parseString(given) },
            .list => .{ .many = try parseList(arena, given) },
            .choice => .{ .one = try parseChoice(param.choices, given) },
        };
    }
    return .{ .values = values };
}

fn parseString(given: std.json.Value) ![]const u8 {
    if (given != .string) return error.InvalidParams;
    if (std.mem.startsWith(u8, given.string, "-")) return error.InvalidParams;
    return given.string;
}

fn parseChoice(choices: []const []const u8, given: std.json.Value) ![]const u8 {
    const value = try parseString(given);
    for (choices) |choice| if (std.mem.eql(u8, choice, value)) return choice;
    return error.InvalidParams;
}

fn parseList(arena: std.mem.Allocator, given: std.json.Value) ![]const []const u8 {
    if (given != .array) return error.InvalidParams;
    const items = try arena.alloc([]const u8, given.array.items.len);
    for (given.array.items, items) |item, *out| {
        if (item != .string) return error.InvalidParams;
        out.* = item.string;
    }
    return items;
}

pub fn parseTemplate(arena: std.mem.Allocator, declared: []const registry.Param, template: []const []const u8) ![]const Segment {
    const segments = try arena.alloc(Segment, template.len);
    for (template, segments) |element, *segment| {
        if (element.len < 2 or element[0] != '{' or element[element.len - 1] != '}') {
            segment.* = .{ .literal = element };
            continue;
        }
        const name = element[1 .. element.len - 1];
        for (declared, 0..) |param, i| {
            if (std.mem.eql(u8, param.name, name)) {
                segment.* = .{ .param = i };
                break;
            }
        } else return error.UnknownPlaceholder;
    }
    return segments;
}

pub fn buildArgv(arena: std.mem.Allocator, binary: []const u8, segments: []const Segment, args: Args) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, binary);
    for (segments) |segment| switch (segment) {
        .literal => |literal| try argv.append(arena, literal),
        .param => |i| switch (args.values[i]) {
            .one => |one| try argv.append(arena, one),
            .many => |many| try argv.appendSlice(arena, many),
        },
    };
    return argv.items;
}

pub const Outcome = union(enum) {
    success: []const u8,
    failure: []const u8,
};

const inherited_env = [_][]const u8{ "PATH", "HOME" };

pub fn childEnviron(arena: std.mem.Allocator, parent: ?*const std.process.Environ.Map, names: []const []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(arena);
    const source = parent orelse return map;
    for ([_][]const []const u8{ &inherited_env, names }) |group| {
        for (group) |name| {
            if (source.get(name)) |value| try map.put(name, value);
        }
    }
    return map;
}

pub fn run(arena: std.mem.Allocator, io: std.Io, cap: registry.Capability, args: Args, parent: ?*const std.process.Environ.Map) !Outcome {
    const argv = try buildArgv(arena, cap.binary, cap.argv, args);
    const environ = try childEnviron(arena, parent, cap.env);
    const result = try std.process.run(arena, io, .{ .argv = argv, .environ_map = &environ });
    return switch (result.term) {
        .exited => |code| if (code == 0) .{ .success = result.stdout } else .{ .failure = result.stderr },
        else => .{ .failure = result.stderr },
    };
}

test "parseParams returns values in declared order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const declared = [_]registry.Param{ .{ .name = "project" }, .{ .name = "issue" } };
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"issue":"42","project":"acme/widgets"}
    , .{});

    const args = try parseParams(arena, &declared, params.object);

    try std.testing.expectEqualStrings("acme/widgets", args.values[0].one);
    try std.testing.expectEqualStrings("42", args.values[1].one);
}

test "parseParams rejects a missing param" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const declared = [_]registry.Param{.{ .name = "project" }};
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});

    try std.testing.expectError(error.InvalidParams, parseParams(arena, &declared, params.object));
}

test "parseParams rejects a value that looks like a flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const declared = [_]registry.Param{.{ .name = "project" }};
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"project":"--web"}
    , .{});

    try std.testing.expectError(error.InvalidParams, parseParams(arena, &declared, params.object));
}

test "parseTemplate turns placeholders into param indices" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const declared = [_]registry.Param{ .{ .name = "project" }, .{ .name = "state" } };
    const template = [_][]const u8{ "issue", "list", "--state", "{state}", "--repo", "{project}" };

    const segments = try parseTemplate(arena_state.allocator(), &declared, &template);

    try std.testing.expectEqual(6, segments.len);
    try std.testing.expectEqualStrings("issue", segments[0].literal);
    try std.testing.expectEqual(1, segments[3].param);
    try std.testing.expectEqual(0, segments[5].param);
}

test "parseTemplate rejects an unknown placeholder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const declared = [_]registry.Param{.{ .name = "project" }};
    const template = [_][]const u8{ "--repo", "{repo}" };

    try std.testing.expectError(error.UnknownPlaceholder, parseTemplate(arena_state.allocator(), &declared, &template));
}

test "buildArgv fills placeholders with parsed values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const segments = [_]Segment{ .{ .literal = "issue" }, .{ .literal = "--repo" }, .{ .param = 0 } };
    const args: Args = .{ .values = &.{.{ .one = "acme/widgets" }} };

    const argv = try buildArgv(arena_state.allocator(), "glab", &segments, args);

    try std.testing.expectEqual(4, argv.len);
    try std.testing.expectEqualStrings("glab", argv[0]);
    try std.testing.expectEqualStrings("issue", argv[1]);
    try std.testing.expectEqualStrings("--repo", argv[2]);
    try std.testing.expectEqualStrings("acme/widgets", argv[3]);
}

test "childEnviron keeps PATH, HOME and the adapter env only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parent = std.process.Environ.Map.init(arena);
    try parent.put("PATH", "/usr/bin");
    try parent.put("HOME", "/Users/acme");
    try parent.put("GITLAB_TOKEN", "secret");
    try parent.put("AWS_SECRET_ACCESS_KEY", "other");

    const environ = try childEnviron(arena, &parent, &.{"GITLAB_TOKEN"});

    try std.testing.expectEqual(3, environ.count());
    try std.testing.expectEqualStrings("secret", environ.get("GITLAB_TOKEN").?);
    try std.testing.expectEqual(null, environ.get("AWS_SECRET_ACCESS_KEY"));
}

test "run returns stdout when the command succeeds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const cap: registry.Capability = .{
        .name = "echo",
        .binary = "/bin/echo",
        .argv = &.{.{ .param = 0 }},
    };
    const outcome = try run(arena_state.allocator(), std.testing.io, cap, .{ .values = &.{.{ .one = "acme/widgets" }} }, null);

    try std.testing.expectEqualStrings("acme/widgets\n", outcome.success);
}

test "run returns stderr when the command fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const cap: registry.Capability = .{
        .name = "ls",
        .binary = "/bin/ls",
        .argv = &.{.{ .literal = "/nonexistent-zandy" }},
    };
    const outcome = try run(arena_state.allocator(), std.testing.io, cap, .{ .values = &.{} }, null);

    try std.testing.expect(std.mem.indexOf(u8, outcome.failure, "nonexistent-zandy") != null);
}

test "a list param expands into one argv entry per item, flags included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const declared = [_]registry.Param{.{ .name = "args", .kind = .list }};
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"args":["s3api","list-buckets","--output","json"]}
    , .{});

    const args = try parseParams(arena, &declared, params.object);
    const argv = try buildArgv(arena, "aws", &.{.{ .param = 0 }}, args);

    try std.testing.expectEqual(5, argv.len);
    try std.testing.expectEqualStrings("--output", argv[3]);
}

test "parseParams accepts a configured choice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const declared = [_]registry.Param{.{ .name = "profile", .kind = .choice, .choices = &.{ "acme-dev", "acme-int" } }};
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"profile":"acme-int"}
    , .{});

    const args = try parseParams(arena, &declared, params.object);

    try std.testing.expectEqualStrings("acme-int", args.values[0].one);
}

test "parseParams rejects a value that is not a configured choice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const declared = [_]registry.Param{.{ .name = "profile", .kind = .choice, .choices = &.{"acme-dev"} }};
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"profile":"acme-prod"}
    , .{});

    try std.testing.expectError(error.InvalidParams, parseParams(arena, &declared, params.object));
}
