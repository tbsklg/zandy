const std = @import("std");
const sbpl = @import("sbpl.zig");
const store = @import("store.zig");

const FileSystem = @import("manifest.zig").FileSystem;
const Env = @import("env.zig");
const Rule = sbpl.Rule;

pub fn buildProfile(arena: std.mem.Allocator, base: sbpl.Profile, env: Env, fs: FileSystem, store_paths: []const store.StorePath) !sbpl.Profile {
    const fs_rules = try buildFilesystemRules(arena, env, fs);
    const rules = try std.mem.concat(arena, sbpl.Rule, &.{ base.rules, try storeRules(arena, store_paths), fs_rules });
    return .{ .version = base.version, .deny_default = base.deny_default, .rules = rules };
}

fn storeRules(arena: std.mem.Allocator, store_paths: []const store.StorePath) ![]Rule {
    const rules = try arena.alloc(Rule, store_paths.len * 2);
    for (store_paths, 0..) |p, i| {
        const filter: sbpl.Filter = .{ .subpath = .{ .literal = p.path } };
        rules[2 * i] = Rule.allow(.process_exec, filter);
        rules[2 * i + 1] = Rule.allow(.file_read_all, filter);
    }
    return rules;
}

fn resolvePath(arena: std.mem.Allocator, home: []const u8, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        return std.fs.path.join(arena, &.{ home, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) return arena.dupe(u8, path);
    return std.fs.path.join(arena, &.{ cwd, path });
}

fn buildFilesystemRules(arena: std.mem.Allocator, env: Env, fs: FileSystem) ![]Rule {
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

    const cfg = FileSystem{
        .allowRead = &allowRead,
        .denyRead = &denyRead,
        .allowWrite = &allowWrite,
        .denyWrite = &empty,
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

test "store paths may be executed and read, nothing else in the store" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const store_paths = [_]store.StorePath{
        try store.parse("/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0"),
        try store.parse("/nix/store/7f0sryhgq9arkgzmv2pfzyxn40p7j69f-pcre2-10.48"),
    };

    const profile = try buildProfile(arena, .{ .rules = &.{} }, .{ .home = "/Users/acme", .cwd = "/Users/acme/widgets", .tmpdir = "/private/tmp" }, .{}, &store_paths);

    var aw = std.Io.Writer.Allocating.init(arena);
    try profile.write(&aw.writer);
    const written = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, written, "(allow process-exec (subpath \"/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "(allow file-read* (subpath \"/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "(allow process-exec (subpath \"/nix/store/7f0sryhgq9arkgzmv2pfzyxn40p7j69f-pcre2-10.48\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "(subpath \"/nix/store\")") == null);
}
