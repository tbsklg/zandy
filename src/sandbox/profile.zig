const std = @import("std");
const sbpl = @import("sbpl.zig");
const store = @import("../env/store.zig");

const FileSystem = @import("../env/manifest.zig").FileSystem;
const Env = @import("../env/env.zig");
const Rule = sbpl.Rule;

pub fn buildProfile(arena: std.mem.Allocator, base: sbpl.Profile, env: Env, fs: FileSystem, store_paths: []const store.StorePath) !sbpl.Profile {
    const fs_rules = try buildFilesystemRules(arena, env, fs);
    const rules = try std.mem.concat(arena, sbpl.Rule, &.{ base.rules, try storeRules(arena, store_paths), fs_rules, &protected_rules, &secret_rules });
    return .{ .version = base.version, .deny_default = base.deny_default, .rules = rules };
}

const protected_literals = [_][]const u8{ "/flake.nix", "/flake.lock", "/.envrc", "/.git", "/.git/config" };
const protected_subpaths = [_][]const u8{"/.git/hooks"};
const protected_operations = [_]sbpl.Operation{ .file_write_all, .file_write_create, .file_write_data };

const protected_rules = blk: {
    var rules: [(protected_literals.len + protected_subpaths.len) * protected_operations.len]Rule = undefined;
    var i = 0;
    for (protected_operations) |op| {
        for (protected_literals) |suffix| {
            rules[i] = Rule.deny(op, .{ .literal = .{ .param_append = .{ .param = "CWD", .suffix = suffix } } });
            i += 1;
        }
        for (protected_subpaths) |suffix| {
            rules[i] = Rule.deny(op, .{ .subpath = .{ .param_append = .{ .param = "CWD", .suffix = suffix } } });
            i += 1;
        }
    }
    break :blk rules;
};

const zandy_dir: sbpl.Filter = .{ .subpath = .{ .param_append = .{ .param = "HOME", .suffix = "/.zandy" } } };
const keychains_dir: sbpl.Filter = .{ .subpath = .{ .param_append = .{ .param = "HOME", .suffix = "/Library/Keychains" } } };

const secret_rules = [_]Rule{
    Rule.deny(.file_read_data, zandy_dir),
    Rule.deny(.file_write_all, zandy_dir),
    Rule.deny(.file_read_data, keychains_dir),
    Rule.deny(.file_write_all, keychains_dir),
    Rule.deny(.mach_lookup, .{ .global_name = "com.apple.SecurityServer" }),
    Rule.deny(.mach_lookup, .{ .global_name = "com.apple.securityd.xpc" }),
};

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

test "files that define the sandbox or run outside it stay read-only even when the user allows writing CWD" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const allowWrite = [_][]const u8{"."};
    const profile = try buildProfile(arena, .{ .rules = &.{} }, .{ .home = "/Users/acme", .cwd = "/Users/acme/widgets", .tmpdir = "/private/tmp" }, .{ .allowWrite = &allowWrite }, &.{});

    var aw = std.Io.Writer.Allocating.init(arena);
    try profile.write(&aw.writer);
    const written = aw.written();

    const allow = std.mem.indexOf(u8, written, "(allow file-write* (subpath \"/Users/acme/widgets/.\"))").?;
    const deny_flake = std.mem.indexOf(u8, written, "(deny file-write* (literal (string-append (param \"CWD\") \"/flake.nix\")))").?;
    const deny_hooks = std.mem.indexOf(u8, written, "(deny file-write* (subpath (string-append (param \"CWD\") \"/.git/hooks\")))").?;
    try std.testing.expect(allow < deny_flake);
    try std.testing.expect(allow < deny_hooks);
    try std.testing.expect(std.mem.indexOf(u8, written, "(deny file-write-create (subpath (string-append (param \"CWD\") \"/.git/hooks\")))") != null);
}

test "zandy's secrets and the keychain stay closed even when the user allows reading HOME" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const allowRead = [_][]const u8{"~/"};
    const profile = try buildProfile(arena, .{ .rules = &.{} }, .{ .home = "/Users/acme", .cwd = "/Users/acme/widgets", .tmpdir = "/private/tmp" }, .{ .allowRead = &allowRead }, &.{});

    var aw = std.Io.Writer.Allocating.init(arena);
    try profile.write(&aw.writer);
    const written = aw.written();

    const allow = std.mem.indexOf(u8, written, "(allow file-read* (subpath \"/Users/acme\"))").?;
    const deny_zandy = std.mem.indexOf(u8, written, "(deny file-read-data (subpath (string-append (param \"HOME\") \"/.zandy\")))").?;
    const deny_keychains = std.mem.indexOf(u8, written, "(deny file-read-data (subpath (string-append (param \"HOME\") \"/Library/Keychains\")))").?;
    try std.testing.expect(allow < deny_zandy);
    try std.testing.expect(allow < deny_keychains);
    try std.testing.expect(std.mem.indexOf(u8, written, "(deny file-write* (subpath (string-append (param \"HOME\") \"/.zandy\")))") != null);
}

test "a preset can't open the keychain services" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = [_]Rule{Rule.allow(.mach_lookup, .{ .global_name = "com.apple.SecurityServer" })};
    const profile = try buildProfile(arena, .{ .rules = &base }, .{ .home = "/Users/acme", .cwd = "/Users/acme/widgets", .tmpdir = "/private/tmp" }, .{}, &.{});

    var aw = std.Io.Writer.Allocating.init(arena);
    try profile.write(&aw.writer);
    const written = aw.written();

    const allow = std.mem.indexOf(u8, written, "(allow mach-lookup (global-name \"com.apple.SecurityServer\"))").?;
    const deny = std.mem.indexOf(u8, written, "(deny mach-lookup (global-name \"com.apple.SecurityServer\"))").?;
    try std.testing.expect(allow < deny);
    try std.testing.expect(std.mem.indexOf(u8, written, "(deny mach-lookup (global-name \"com.apple.securityd.xpc\"))") != null);
}
