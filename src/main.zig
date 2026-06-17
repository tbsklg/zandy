const std = @import("std");
const macos = @import("macos.zig");
const opencode = @import("opencode.zig");
const Config = @import("config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const home = std.posix.getenv("HOME") orelse return error.NoHome;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const arg_views = try allocator.alloc([]const u8, args.len);
    defer allocator.free(arg_views);
    for (args, arg_views) |a, *v| v.* = a;

    const profile = profileFromArgs(arg_views) catch {
        std.debug.print("invalid --profile (expected default or network_only)\n", .{});
        std.process.exit(1);
    };

    var cfg = try Config.default(allocator, cwd);
    defer if (cfg) |*c| c.deinit();

    const pid = try std.posix.fork();

    if (pid == 0) {
        var errbuf: ?[*:0]u8 = null;

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();

        const profile_value = try opencode.opencodeProfile(arena_state.allocator(), .{ .profile = profile, .home = home, .cwd = cwd, .config = cfg });

        var profile_buf: std.ArrayList(u8) = .empty;
        defer profile_buf.deinit(allocator);
        try profile_value.write(profile_buf.writer(allocator));

        const profile_z = try allocator.dupeZ(u8, profile_buf.items);
        defer allocator.free(profile_z);

        const cwd_z = try allocator.dupeZ(u8, cwd);
        defer allocator.free(cwd_z);

        const home_z = try allocator.dupeZ(u8, home);
        defer allocator.free(home_z);

        const parameters = [_:null]?[*:0]const u8{
            "CWD",
            cwd_z.ptr,
            "HOME",
            home_z.ptr,
        };

        const rc = macos.sandbox_init_with_parameters(profile_z.ptr, 0, &parameters, &errbuf);
        defer if (errbuf) |buf| macos.sandbox_free_error(buf);

        if (rc != 0) {
            if (errbuf) |buf| {
                std.debug.print("sandbox initialization failed: {s}\n", .{std.mem.span(buf)});
            }
            return error.SandboxInitFailed;
        }

        const path = try findOpencode(allocator);
        defer allocator.free(path);

        const argv = [_:null]?[*:0]const u8{"opencode"};
        const env = [_:null]?[*:0]u8{};
        std.posix.execveZ(path.ptr, argv[0..argv.len], env[0..env.len]) catch return error.OpencodeRunFailed;
    } else {
        _ = std.posix.waitpid(pid, 0);
        std.log.debug("Child process terminated", .{});
    }
}

fn findOpencode(allocator: std.mem.Allocator) ![:0]u8 {
    var child = std.process.Child.init(&.{ "/usr/bin/which", "opencode" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 4096);
    errdefer allocator.free(stdout);
    _ = try child.wait();

    const path = std.mem.trimRight(u8, stdout, "\n\r ");
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
