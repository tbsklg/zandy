const std = @import("std");
const profile_mod = @import("profile.zig");
const preset_mod = @import("preset.zig");
const launch_mod = @import("launch.zig");
const cli = @import("cli.zig");

const Config = @import("config.zig");
const Env = @import("env.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const envMap = init.environ_map;

    const raw_args = try init.minimal.args.toSlice(arena);
    const command = cli.parseArgs(raw_args) catch |err| switch (err) {
        error.Help => {
            std.debug.print("{s}", .{cli.usage});
            std.process.exit(0);
        },
        else => {
            std.debug.print("{s}", .{cli.usage});
            std.process.exit(1);
        },
    };

    const env = try Env.init(arena, io, envMap);
    const cfg = try Config.load(arena, io, env.home, env.cwd);

    const preset_name = switch (command) {
        .launch => |name| name,
        .config => return showConfig(arena, io, cfg orelse .{ .filesystem = null }),
    };
    const preset = preset_mod.find(preset_name) orelse {
        std.debug.print("zandy: unknown preset '{s}'", .{preset_name});
        std.process.exit(1);
    };
    const profile = try profile_mod.buildProfile(arena, preset.profile, env, cfg);

    try launch_mod.launch(init, preset, profile, env, cfg);
}

fn showConfig(arena: std.mem.Allocator, io: std.Io, cfg: Config) !void {
    const capabilities = try launch_mod.capabilities(arena, cfg);
    const registry: @import("registry.zig").Registry = .{ .capabilities = capabilities };
    const discovered = try std.json.parseFromSliceLeaky(std.json.Value, arena, try registry.discover(arena, cfg.policy), .{});

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    try stdout.interface.print("{f}\n", .{std.json.fmt(.{ .config = cfg, .discover = discovered }, .{ .whitespace = .indent_2 })});
    try stdout.interface.flush();
}
