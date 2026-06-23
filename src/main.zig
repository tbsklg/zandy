const std = @import("std");
const macos = @import("macos.zig");
const opencode = @import("opencode.zig");
const Config = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const envMap = init.environ_map;

    const cwd = try std.process.currentPathAlloc(init.io, gpa);
    defer gpa.free(cwd);

    const home = envMap.get("HOME") orelse return error.NoHome;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const arg_views = try gpa.alloc([]const u8, args.len);
    defer gpa.free(arg_views);
    for (args, arg_views) |a, *v| v.* = a;

    const profile = profileFromArgs(arg_views) catch {
        std.debug.print("invalid --profile (expected default or network_only)\n", .{});
        std.process.exit(1);
    };

    var cfg = try Config.default(gpa, io, envMap, cwd);
    defer if (cfg) |*c| c.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const profile_value = try opencode.opencodeProfile(arena_state.allocator(), .{ .profile = profile, .home = home, .cwd = cwd, .config = cfg });

    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();

    try profile_value.write(&aw.writer);

    const profile_z = try gpa.dupeZ(u8, aw.written());
    defer gpa.free(profile_z);

    const cwd_z = try gpa.dupeZ(u8, cwd);
    defer gpa.free(cwd_z);

    const home_z = try gpa.dupeZ(u8, home);
    defer gpa.free(home_z);

    const parameters = [_:null]?[*:0]const u8{
        "CWD",
        cwd_z.ptr,
        "HOME",
        home_z.ptr,
    };

    const path = try findOpencode(gpa, io);
    defer gpa.free(path);

    const argv = [_:null]?[*:0]const u8{"opencode"};
    const env = [_:null]?[*:0]u8{};

    const pid = std.c.fork();
    if (pid == -1) return error.ForkFailed;

    if (pid == 0) {
        var errbuf: ?[*:0]u8 = null;

        const rc = macos.sandbox_init_with_parameters(profile_z.ptr, 0, &parameters, &errbuf);
        defer if (errbuf) |buf| macos.sandbox_free_error(buf);

        if (rc != 0) {
            if (errbuf) |buf| {
                std.debug.print("sandbox initialization failed: {s}\n", .{std.mem.span(buf)});
            }
            return error.SandboxInitFailed;
        }

        _ = std.c.execve(path.ptr, argv[0..argv.len], env[0..env.len]);
        return error.OpencodeFailed;
    }

    _ = std.c.waitpid(pid, null, 0);
    std.log.debug("Child process terminated", .{});
}

fn findOpencode(allocator: std.mem.Allocator, io: std.Io) ![:0]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "/usr/bin/which", "opencode" } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const path = std.mem.trimEnd(u8, result.stdout, "\n\r ");
    if (path.len == 0) return error.OpencodeNotFound;

    return allocator.dupeZ(u8, path);
}

fn profileFromArgs(args: []const []const u8) !Config.Profile {
    const flag = "--profile";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, flag)) {
            if (i + 1 >= args.len) return error.MissingProfileValue;
            return Config.Profile.fromString(args[i + 1]) orelse error.UnknownProfile;
        }
        if (std.mem.startsWith(u8, arg, flag ++ "=")) {
            return Config.Profile.fromString(arg[flag.len + 1 ..]) orelse error.UnknownProfile;
        }
    }
    return .default;
}

test "profileFromArgs" {
    try std.testing.expectEqual(Config.Profile.default, try profileFromArgs(&.{"zandy"}));
    try std.testing.expectEqual(Config.Profile.network_only, try profileFromArgs(&.{ "zandy", "--profile", "network_only" }));
    try std.testing.expectEqual(Config.Profile.network_only, try profileFromArgs(&.{ "zandy", "--profile=network_only" }));
    try std.testing.expectError(error.UnknownProfile, profileFromArgs(&.{ "zandy", "--profile", "bogus" }));
    try std.testing.expectError(error.MissingProfileValue, profileFromArgs(&.{ "zandy", "--profile" }));
}
