const std = @import("std");
const sbpl = @import("sbpl.zig");

pub const Preset = struct {
    name: []const u8,
    binary: [:0]const u8,
    profile: sbpl.Profile,
};

const presets = [_]Preset{
    .{ .name = "opencode", .binary = "opencode", .profile = @import("profiles/opencode.zon") },
    .{ .name = "claude", .binary = "claude", .profile = @import("profiles/claude.zon") },
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
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow network-outbound)") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow network-bind)") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow network-inbound)") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow signal (target same-sandbox))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow mach-lookup (global-name \"com.apple.trustd\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file* (subpath (string-append (param \"HOME\") \"/.claude\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file* (literal (string-append (param \"HOME\") \"/.claude.json\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(allow file* (subpath (param \"CWD\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(deny file* (subpath \"/private/tmp/com.apple.launchd\"))") != null);
}
