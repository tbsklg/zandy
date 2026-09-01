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
    const args = cli.parseArgs(raw_args) catch |err| switch (err) {
        error.Help => {
            std.debug.print("{s}", .{cli.usage});
            std.process.exit(0);
        },
        else => {
            std.debug.print("{s}", .{cli.usage});
            std.process.exit(1);
        },
    };

    const preset = preset_mod.find(args.preset) orelse {
        std.debug.print("zandy: unknown preset '{s}'", .{args.preset});
        std.process.exit(1);
    };
    const env = try Env.init(arena, io, envMap);
    const cfg = try Config.load(arena, io, env.home, env.cwd);
    const profile = try profile_mod.buildProfile(arena, preset.profile, env, cfg);

    try launch_mod.launch(arena, io, preset.binary, profile, env);
}
