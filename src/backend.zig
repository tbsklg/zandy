const std = @import("std");
const registry = @import("registry.zig");
const command = @import("command.zig");

pub const Backend = union(enum) {
    anthropic,
    bedrock: struct { profile: []const u8, region: []const u8 },
};

pub fn capability(arena: std.mem.Allocator, backend: Backend) !?registry.Capability {
    return switch (backend) {
        .anthropic => null,
        .bedrock => |b| .{
            .name = "backend.credentials",
            .description = "Short-lived AWS credentials for Bedrock, used by Claude Code's awsCredentialExport.",
            .effect = .read,
            .binary = "aws",
            .argv = try arena.dupe(command.Segment, &.{
                .{ .literal = "configure" },
                .{ .literal = "export-credentials" },
                .{ .literal = "--profile" },
                .{ .literal = b.profile },
                .{ .literal = "--format" },
                .{ .literal = "process" },
            }),
        },
    };
}

pub fn claudeSettings(arena: std.mem.Allocator, backend: Backend) !?[:0]const u8 {
    return switch (backend) {
        .anthropic => null,
        .bedrock => |b| try std.fmt.allocPrintSentinel(arena, "{f}", .{std.json.fmt(.{
            .awsCredentialExport = "zandy-client call backend.credentials",
            .env = .{ .CLAUDE_CODE_USE_BEDROCK = "1", .AWS_REGION = b.region },
        }, .{})}, 0),
    };
}

test "bedrock credentials use the configured profile" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const cap = (try capability(arena_state.allocator(), .{ .bedrock = .{ .profile = "acme", .region = "eu-west-1" } })).?;

    try std.testing.expectEqualStrings("backend.credentials", cap.name);
    try std.testing.expectEqualStrings("acme", cap.argv[3].literal);
}

test "anthropic needs no credentials and no settings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectEqual(null, try capability(arena_state.allocator(), .anthropic));
    try std.testing.expectEqual(null, try claudeSettings(arena_state.allocator(), .anthropic));
}

test "bedrock settings enable bedrock and export credentials through the broker" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const settings = (try claudeSettings(arena_state.allocator(), .{ .bedrock = .{ .profile = "acme", .region = "eu-west-1" } })).?;

    try std.testing.expectEqualStrings(
        \\{"awsCredentialExport":"zandy-client call backend.credentials","env":{"CLAUDE_CODE_USE_BEDROCK":"1","AWS_REGION":"eu-west-1"}}
    , settings);
}
