const std = @import("std");

pub const Args = struct {
    preset: []const u8,
};

pub fn parseArgs(args: []const [:0]const u8) !Args {
    if (args.len < 2) return error.NoPreset;
    if (args.len > 2) return error.UnexpectedArgs;
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help")))
        return error.Help;

    return .{ .preset = args[1] };
}

pub const usage =
    \\usage: zandy <preset>
    \\
    \\presets:
    \\  opencode    sandbox opencode with its builtin profile
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

    try std.testing.expectEqualStrings("foo", parsed.preset);
}

test "returns help for --help" {
    const long = [_][:0]const u8{ "zandy", "--help" };
    try std.testing.expectError(error.Help, parseArgs(&long));
}
