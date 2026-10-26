const std = @import("std");

pub const Command = union(enum) {
    launch: []const u8,
    config,
};

pub fn parseArgs(args: []const [:0]const u8) !Command {
    if (args.len < 2) return error.NoPreset;
    if (args.len > 2) return error.UnexpectedArgs;
    if (std.mem.eql(u8, args[1], "--help")) return error.Help;
    if (std.mem.eql(u8, args[1], "config")) return .config;

    return .{ .launch = args[1] };
}

pub const usage =
    \\usage: zandy <preset>
    \\       zandy config    show the effective config and the methods the agent sees
    \\
    \\presets:
    \\  opencode    sandbox opencode with its builtin profile
    \\  claude      sandbox claude with its builtin profile
;

test "returns error when no preset" {
    const args = [_][:0]const u8{"zandy"};

    try std.testing.expectError(error.NoPreset, parseArgs(&args));
}

test "returns error when unexpected args" {
    const args = [_][:0]const u8{ "zandy", "foo", "bar" };

    try std.testing.expectError(error.UnexpectedArgs, parseArgs(&args));
}

test "returns args with preset" {
    const args = [_][:0]const u8{ "zandy", "foo" };

    const parsed = try parseArgs(&args);

    try std.testing.expectEqualStrings("foo", parsed.launch);
}

test "returns config command" {
    const args = [_][:0]const u8{ "zandy", "config" };

    try std.testing.expectEqual(.config, try parseArgs(&args));
}

test "returns help for --help" {
    const long = [_][:0]const u8{ "zandy", "--help" };
    try std.testing.expectError(error.Help, parseArgs(&long));
}
