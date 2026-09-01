const std = @import("std");
const sbpl = @import("sbpl.zig");

const Config = @import("config.zig");
const Env = @import("env.zig");
const Rule = sbpl.Rule;

pub fn buildProfile(arena: std.mem.Allocator, base: sbpl.Profile, env: Env, config: ?Config) !sbpl.Profile {
    const fs_rules = try buildFilesystemRules(arena, env, config);
    const rules = try std.mem.concat(arena, sbpl.Rule, &.{ base.rules, fs_rules });
    return .{ .rules = rules };
}

fn resolvePath(arena: std.mem.Allocator, home: []const u8, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        return std.fs.path.join(arena, &.{ home, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) return arena.dupe(u8, path);
    return std.fs.path.join(arena, &.{ cwd, path });
}

fn buildFilesystemRules(arena: std.mem.Allocator, env: Env, config: ?Config) ![]Rule {
    const c = config orelse return &.{};
    const fs = c.filesystem orelse return &.{};

    const Entry = struct { action: sbpl.Action, op: sbpl.Operation, paths: []const []const u8 };
    const entries = [_]Entry{
        .{ .action = .allow, .op = .file_read_all, .paths = fs.allowRead },
        .{ .action = .deny, .op = .file_read_all, .paths = fs.denyRead },
        .{ .action = .allow, .op = .file_write_all, .paths = fs.allowWrite },
        .{ .action = .deny, .op = .file_write_all, .paths = fs.denyWrite },
    };

    var rules: std.ArrayList(Rule) = .empty;
    for (entries) |e| for (e.paths) |p| {
        const abs = try resolvePath(arena, env.home, env.cwd, p);
        try rules.append(arena, .{ .action = e.action, .operation = e.op, .filter = .{ .subpath = .{ .literal = abs } } });
    };
    return rules.toOwnedSlice(arena);
}

test "build filesystem rules from config" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    const allowRead = [_][]const u8{ "/abs/allow", "rel/allow", "~/tilde/allow" };
    const denyRead = [_][]const u8{"/abs/deny"};
    const allowWrite = [_][]const u8{"/abs/write"};
    const empty = [_][]const u8{};

    const cfg = Config{
        .parsed = null,
        .filesystem = .{
            .allowRead = &allowRead,
            .denyRead = &denyRead,
            .allowWrite = &allowWrite,
            .denyWrite = &empty,
        },
    };

    const rules = try buildFilesystemRules(arena_state.allocator(), .{ .home = "/Users/test", .cwd = "/Users/test/cwd" }, cfg);
    const profile = sbpl.Profile{ .rules = rules };
    try profile.write(&aw.writer);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read* (subpath \"/abs/allow\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read* (subpath \"/Users/test/cwd/rel/allow\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read* (subpath \"/Users/test/tilde/allow\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(deny file-read* (subpath \"/abs/deny\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-write* (subpath \"/abs/write\"))") != null);
}
