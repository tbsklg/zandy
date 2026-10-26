const std = @import("std");
const sbpl = @import("sbpl.zig");
const backend = @import("backend.zig");

pub const Preset = struct {
    name: []const u8,
    binary: [:0]const u8,
    profile: sbpl.Profile,
    env: []const []const u8,
    args: ArgsFn = noArgs,
};

pub const ArgsFn = *const fn (std.mem.Allocator, backend.Backend) anyerror![]const [:0]const u8;

fn noArgs(_: std.mem.Allocator, _: backend.Backend) ![]const [:0]const u8 {
    return &.{};
}

const claude_prompt =
    \\You run inside the zandy sandbox. CLIs like aws and glab have no credentials here.
    \\Run `zandy-client discover` to list the available broker methods, then call one with
    \\`zandy-client call <method> '<json args>'`, e.g.
    \\`zandy-client call aws.cli '{"profile":"<profile>","args":["s3","ls"]}'`.
    \\`backend.credentials` is for Claude Code itself; don't use it.
;

fn claudeArgs(arena: std.mem.Allocator, b: backend.Backend) ![]const [:0]const u8 {
    const prompt = [_][:0]const u8{ "--append-system-prompt", claude_prompt };
    const settings = try backend.claudeSettings(arena, b) orelse return arena.dupe([:0]const u8, &prompt);
    return arena.dupe([:0]const u8, &(prompt ++ [_][:0]const u8{ "--settings", settings }));
}

const interactive_env = [_][]const u8{ "PATH", "HOME", "TMPDIR", "USER", "SHELL", "TERM", "COLORTERM", "LANG", "LC_ALL" };

const presets = [_]Preset{
    .{ .name = "opencode", .binary = "opencode", .profile = @import("profiles/opencode.zon"), .env = &interactive_env },
    .{ .name = "claude", .binary = "claude", .profile = @import("profiles/claude.zon"), .env = &interactive_env, .args = claudeArgs },
};

pub fn find(name: []const u8) ?*const Preset {
    for (&presets) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }

    return null;
}

test "returns preset for existing preset" {
    const preset = find("opencode").?;

    try std.testing.expectEqualStrings("opencode", preset.name);
}

test "returns null for non existing preset" {
    const preset = find("foo");

    try std.testing.expectEqual(null, preset);
}

test "opencode preset contains expected rules" {
    const p = find("opencode").?;

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try p.profile.write(&aw.writer);

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

test "claude preset contains expected rules" {
    const p = find("claude").?;

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try p.profile.write(&aw.writer);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow process-exec)") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow network-outbound (remote unix-socket (path-literal (param \"BROKER_SOCK\"))))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow network-bind)") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow network-inbound)") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow signal (target same-sandbox))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow mach-lookup (global-name \"com.apple.trustd\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file* (subpath (string-append (param \"HOME\") \"/.claude\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file* (literal (string-append (param \"HOME\") \"/.claude.json\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file* (subpath (param \"CWD\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(deny file* (subpath \"/private/tmp/com.apple.launchd\"))") != null);
}

test "claude is told about the broker and gets backend settings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const args = try find("claude").?.args(arena_state.allocator(), .{ .bedrock = .{ .profile = "acme", .region = "eu-west-1" } });

    try std.testing.expectEqualStrings("--append-system-prompt", args[0]);
    try std.testing.expectEqualStrings("--settings", args[2]);
}
