const std = @import("std");
const profile_mod = @import("profile.zig");
const launch_mod = @import("launch.zig");
const registry_mod = @import("registry.zig");
const cli = @import("cli.zig");
const secret = @import("secret.zig");

const Env = @import("env.zig");
const SandboxEnv = @import("sandbox_env.zig");

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

    const env_path = switch (command) {
        .launch => |launch| launch.env,
        .config => |env_path| env_path,
        .secret => |service| return storeSecret(arena, io, envMap, service),
    };
    const sandbox_env = SandboxEnv.load(arena, io, env_path) catch |err| {
        std.debug.print("zandy: --env '{s}' is not a sandbox env built by zandy.lib.mkSandboxEnv: {t}\n", .{ env_path, err });
        std.process.exit(1);
    };

    const launch = switch (command) {
        .launch => |launch| launch,
        .config => return showConfig(arena, io, sandbox_env),
        .secret => unreachable,
    };

    const env = try Env.init(arena, io, envMap);
    const profile = try profile_mod.buildProfile(arena, sandbox_env.manifest.preset.profile, env, sandbox_env.manifest.filesystem, sandbox_env.closure);

    try launch_mod.launch(init, sandbox_env, launch.args, profile, env);
}

fn storeSecret(arena: std.mem.Allocator, io: std.Io, envMap: *std.process.Environ.Map, service: []const u8) !void {
    const home = envMap.get("HOME") orelse return error.NoHome;
    secret.set(arena, io, home, service) catch |err| {
        std.debug.print("zandy: could not store '{s}': {t}\n", .{ service, err });
        std.process.exit(1);
    };
    std.debug.print("zandy: stored '{s}' in {s}\n", .{ service, try secret.keychainPath(arena, home, .zandy) });
}

fn showConfig(arena: std.mem.Allocator, io: std.Io, sandbox_env: SandboxEnv) !void {
    const manifest = sandbox_env.manifest;
    const no_pipes = try arena.alloc([]const secret.Pipe, manifest.adapters.len);
    @memset(no_pipes, &.{});
    const registry: registry_mod.Registry = .{ .capabilities = try registry_mod.parseAdapters(arena, manifest.adapters, no_pipes, "~/.zandy/run/<pid>") };
    const discovered = try std.json.parseFromSliceLeaky(std.json.Value, arena, try registry.discover(arena), .{});

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    try stdout.interface.print("{f}\n", .{std.json.fmt(.{ .env = sandbox_env.root.path, .manifest = manifest, .discover = discovered }, .{ .whitespace = .indent_2 })});
    try stdout.interface.flush();
}
