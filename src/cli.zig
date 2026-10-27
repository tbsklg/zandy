const std = @import("std");

pub const Command = union(enum) {
    launch: Launch,
    config: []const u8,
};

pub const Launch = struct {
    env: []const u8,
    args: []const [:0]const u8,
};

pub fn parseArgs(args: []const [:0]const u8) !Command {
    if (args.len < 2) return error.NoEnv;
    if (std.mem.eql(u8, args[1], "--help")) return error.Help;
    if (std.mem.eql(u8, args[1], "config")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "--env")) return error.NoEnv;
        return .{ .config = args[3] };
    }
    if (!std.mem.eql(u8, args[1], "--env")) return error.NoEnv;
    if (args.len < 3) return error.NoEnv;

    return .{ .launch = .{ .env = args[2], .args = args[3..] } };
}

pub const usage =
    \\usage: zandy --env <drv> [args...]
    \\       zandy config --env <drv>    show the manifest and the methods the agent sees
    \\
    \\  <drv>  sandbox env built by zandy.lib.mkSandboxEnv, e.g. ./result
    \\         usually started with its launcher zandy-<name> or `nix run`
    \\
;

test "returns error when --env is missing" {
    const args = [_][:0]const u8{ "zandy", "claude" };

    try std.testing.expectError(error.NoEnv, parseArgs(&args));
}

test "returns error when --env has no value" {
    const args = [_][:0]const u8{ "zandy", "--env" };

    try std.testing.expectError(error.NoEnv, parseArgs(&args));
}

test "returns env and passes args through" {
    const args = [_][:0]const u8{ "zandy", "--env", "./result", "-p", "hi" };

    const parsed = try parseArgs(&args);

    try std.testing.expectEqualStrings("./result", parsed.launch.env);
    try std.testing.expectEqual(2, parsed.launch.args.len);
    try std.testing.expectEqualStrings("-p", parsed.launch.args[0]);
}

test "returns config command with its env" {
    const args = [_][:0]const u8{ "zandy", "config", "--env", "./result" };

    try std.testing.expectEqualStrings("./result", (try parseArgs(&args)).config);
}

test "returns error when config has no env" {
    const args = [_][:0]const u8{ "zandy", "config" };

    try std.testing.expectError(error.NoEnv, parseArgs(&args));
}

test "returns help for --help" {
    const long = [_][:0]const u8{ "zandy", "--help" };
    try std.testing.expectError(error.Help, parseArgs(&long));
}
