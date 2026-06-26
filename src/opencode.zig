const std = @import("std");
const sbpl = @import("sbpl.zig");
const Config = @import("config.zig");

const Rule = sbpl.Rule;
const Profile = sbpl.Profile;
const allow = Rule.allow;
const deny = Rule.deny;
const zon = std.zon;

const builtin_profile: Profile = @import("profiles/opencode.zon");

fn resolvePath(arena: std.mem.Allocator, home: []const u8, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        return std.fs.path.join(arena, &.{ home, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) return arena.dupe(u8, path);
    return std.fs.path.join(arena, &.{ cwd, path });
}

pub const Env = struct {
    profile: Config.Profile,
    home: []const u8,
    cwd: []const u8,
    config: ?Config = null,
};

fn buildFilesystemRules(arena: std.mem.Allocator, env: Env) ![]Rule {
    const c = env.config orelse return &.{};
    const fs = c.filesystem orelse return &.{};

    const Entry = struct { action: sbpl.Action, op: sbpl.Operation, paths: []const []const u8 };
    const entries = [_]Entry{
        .{ .action = .allow, .op = .file_read_all, .paths = fs.allowRead },
        .{ .action = .deny, .op = .file_read_all, .paths = fs.denyRead },
        .{ .action = .allow, .op = .file_write_all, .paths = fs.allowWrite },
        .{ .action = .deny, .op = .file_write_all, .paths = fs.denyWrite },
    };

    var total: usize = 0;
    for (entries) |e| total += e.paths.len;

    const rules = try arena.alloc(Rule, total);
    var i: usize = 0;
    for (entries) |e| for (e.paths) |p| {
        const abs = try resolvePath(arena, env.home, env.cwd, p);
        rules[i] = .{ .action = e.action, .operation = e.op, .filter = .{ .subpath = .{ .literal = abs } } };
        i += 1;
    };

    return rules;
}

fn cwdRule(profile: Config.Profile) Rule {
    const op: sbpl.Operation = switch (profile) {
        .default => .file_all,
        .network_only => .file_read_all,
    };
    return allow(op, .{ .subpath = .{ .param = "CWD" } });
}

pub fn opencodeProfile(arena: std.mem.Allocator, env: Env) !sbpl.Profile {
    const fs_rules = try buildFilesystemRules(arena, env);
    const base_rules = builtin_profile.rules;

    const cwd_rule = cwdRule(env.profile);
    const cwd_rules = &.{cwd_rule};

    const rules = try std.mem.concat(arena, Rule, &.{ base_rules, cwd_rules, fs_rules });

    return .{ .rules = rules };
}

test "serialize opencode profile" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    const profile = try opencodeProfile(arena_state.allocator(), .{ .profile = .default, .home = "/Users/test", .cwd = "/Users/test/cwd" });
    try profile.write(&aw.writer);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow process-exec)") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow ipc-posix-shm-read-data)") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow process-info* (target same-sandbox))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow mach-lookup (global-name \"com.apple.logd\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file* (subpath (string-append (param \"HOME\") \"/.config/opencode\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read-data (literal \"/\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file* (subpath (param \"CWD\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-write-create (subpath \"/private/tmp\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read* (literal \"/opt/homebrew/bin/opencode\"))") != null);
}

test "network_only profile grants read-only cwd" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    const profile = try opencodeProfile(arena_state.allocator(), .{ .profile = .network_only, .home = "/Users/test", .cwd = "/Users/test/cwd" });
    try profile.write(&aw.writer);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read* (subpath (param \"CWD\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file* (subpath (param \"CWD\")))") == null);
}

test "serialize opencode profile with filesystem config" {
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
        .allocator = allocator,
        .parsed = null,
        .filesystem = .{
            .allowRead = &allowRead,
            .denyRead = &denyRead,
            .allowWrite = &allowWrite,
            .denyWrite = &empty,
        },
    };

    const profile = try opencodeProfile(arena_state.allocator(), .{ .profile = .default, .home = "/Users/test", .cwd = "/Users/test/cwd", .config = cfg });
    try profile.write(&aw.writer);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read* (subpath \"/abs/allow\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read* (subpath \"/Users/test/cwd/rel/allow\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-read* (subpath \"/Users/test/tilde/allow\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(deny file-read* (subpath \"/abs/deny\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file-write* (subpath \"/abs/write\"))") != null);
}
