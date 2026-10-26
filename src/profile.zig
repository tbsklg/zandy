const std = @import("std");
const sbpl = @import("sbpl.zig");

const Config = @import("config.zig");
const Env = @import("env.zig");
const Rule = sbpl.Rule;

pub fn buildProfile(arena: std.mem.Allocator, base: sbpl.Profile, env: Env, config: ?Config) !sbpl.Profile {
    const fs_rules = try buildFilesystemRules(arena, env, config);
    const rules = try std.mem.concat(arena, sbpl.Rule, &.{ base.rules, fs_rules, &config_rules });
    return .{ .rules = rules };
}

const config_rules = [_]Rule{
    Rule.deny(.file_write_all, .{ .literal = .{ .param_append = .{ .param = "CWD", .suffix = "/" ++ Config.local_file } } }),
    Rule.deny(.file_write_all, .{ .subpath = .{ .param_append = .{ .param = "HOME", .suffix = "/" ++ Config.global_dir } } }),
};

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
        .filesystem = .{
            .allowRead = &allowRead,
            .denyRead = &denyRead,
            .allowWrite = &allowWrite,
            .denyWrite = &empty,
        },
    };

    const rules = try buildFilesystemRules(arena_state.allocator(), .{ .home = "/Users/test", .cwd = "/Users/test/cwd", .tmpdir = "/private/tmp" }, cfg);
    const profile = sbpl.Profile{ .rules = rules };
    try profile.write(&aw.writer);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read* (subpath \"/abs/allow\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read* (subpath \"/Users/test/cwd/rel/allow\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read* (subpath \"/Users/test/tilde/allow\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(deny file-read* (subpath \"/abs/deny\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-write* (subpath \"/abs/write\"))") != null);
}

test "zandy's own config stays read-only even when the user allows writing its directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const allowWrite = [_][]const u8{"~/.config"};
    const empty = [_][]const u8{};
    const cfg = Config{ .filesystem = .{ .allowRead = &empty, .denyRead = &empty, .allowWrite = &allowWrite, .denyWrite = &empty } };

    const profile = try buildProfile(arena, .{ .rules = &.{} }, .{ .home = "/Users/acme", .cwd = "/Users/acme/widgets", .tmpdir = "/private/tmp" }, cfg);

    var aw = std.Io.Writer.Allocating.init(arena);
    try profile.write(&aw.writer);
    const written = aw.written();

    const allow = std.mem.indexOf(u8, written, "(allow file-write* (subpath \"/Users/acme/.config\"))").?;
    const deny_global = std.mem.indexOf(u8, written, "(deny file-write* (subpath (string-append (param \"HOME\") \"/.config/zandy\")))").?;
    const deny_local = std.mem.indexOf(u8, written, "(deny file-write* (literal (string-append (param \"CWD\") \"/.zandy.json\")))").?;
    try std.testing.expect(allow < deny_global);
    try std.testing.expect(allow < deny_local);
}
