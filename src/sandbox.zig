const std = @import("std");
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Profile = config_mod.Profile;

fn find_opencode(allocator: std.mem.Allocator) ![]u8 {
    var child = std.process.Child.init(&.{ "/usr/bin/which", "opencode" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 4096);
    errdefer allocator.free(stdout);
    _ = try child.wait();

    const path = std.mem.trimRight(u8, stdout, "\n\r ");
    if (path.len == 0) return error.OpencodeNotFound;

    return allocator.dupe(u8, path);
}

pub fn start_sandbox(allocator: std.mem.Allocator, cwd: []const u8, config: ?Config, profile: Profile) !void {
    const cwd_env = try std.fmt.allocPrint(allocator, "CWD={s}", .{cwd});
    defer allocator.free(cwd_env);

    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const home_env = try std.fmt.allocPrint(allocator, "HOME={s}", .{home});
    defer allocator.free(home_env);

    const opencode_path = find_opencode(allocator) catch |err| {
        std.debug.print("zandy: could not find opencode in PATH: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(opencode_path);

    const policy = switch (profile) {
        .network_only => try network_only_policy(allocator, cwd, config, opencode_path),
        .default => try default_policy(allocator, cwd, config, opencode_path),
    };
    defer allocator.free(policy);

    const target_dir = "/tmp/zandy";
    std.fs.makeDirAbsolute(target_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const base_argv = [_][]const u8{ "/usr/bin/sandbox-exec", "-D", cwd_env, "-D", home_env, "-p", policy, opencode_path };
    const network_only_argv = base_argv ++ [_][]const u8{target_dir};

    const effective_argv: []const []const u8 = switch (profile) {
        .network_only => &network_only_argv,
        .default => &base_argv,
    };

    var process = std.process.Child.init(effective_argv, allocator);
    process.spawn() catch |err| {
        std.debug.print("zandy: failed to launch opencode: {s}\n", .{@errorName(err)});
        return err;
    };

    const term = try process.wait();
    switch (term) {
        .Exited => |code| std.process.exit(code),
        .Signal => |sig| {
            std.debug.print("zandy: opencode killed by signal {d}\n", .{sig});
            std.process.exit(1);
        },
        .Stopped, .Unknown => std.process.exit(1),
    }
}

fn allow_network(w: std.ArrayList(u8).Writer) !void {
    try w.writeAll(
        \\; Network
        \\(allow network-outbound)
        \\(allow system-socket (socket-domain 32))
    );
}

fn allow_opencode(w: std.ArrayList(u8).Writer) !void {
    try w.writeAll(
        \\; Opencode Config
        \\(allow file* (subpath (string-append (param "HOME") "/.local/share/opencode")))
        \\(allow file* (subpath (string-append (param "HOME") "/.local/state/opencode")))
        \\(allow file* (subpath (string-append (param "HOME") "/.cache/opencode")))
        \\(allow file* (subpath (string-append (param "HOME") "/.config/opencode")))
        \\(allow file* (subpath (string-append (param "HOME") "/dotfiles/config/opencode")))
    );
}

fn mach_lookup(w: std.ArrayList(u8).Writer) !void {
    try w.writeAll(
        \\; Mach services
        \\(allow mach-lookup (global-name "com.apple.SecurityServer"))
        \\(allow mach-lookup (global-name "com.apple.securityd.xpc"))
        \\(allow mach-lookup (global-name "com.apple.bsd.dirhelper"))
        \\(allow mach-lookup (global-name "com.apple.logd"))
        \\(allow mach-lookup (global-name "com.apple.system.notification_center"))
        \\(allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo"))
        \\(allow mach-lookup (global-name "com.apple.system.opendirectoryd.membership"))
        \\(allow mach-lookup (global-name "com.apple.PowerManagement.control"))
        \\(allow mach-lookup (global-name "ipc-posix-shm-read-data apple.shm.notification_center"))
    );
}

fn deny_default(w: std.ArrayList(u8).Writer) !void {
    try w.writeAll(
        \\(version 1)
        \\(deny default)
    );
}

fn apply_filesystem_config(allocator: std.mem.Allocator, w: std.ArrayList(u8).Writer, cwd: []const u8, config: ?Config) !void {
    if (config) |c| {
        if (c.filesystem) |fs| {
            for (fs.allowRead) |p| {
                const abs = try resolve_path(allocator, cwd, p);
                defer allocator.free(abs);
                try w.print("(allow file-read*  (subpath \"{s}\"))\n", .{abs});
            }
            for (fs.denyRead) |p| {
                const abs = try resolve_path(allocator, cwd, p);
                defer allocator.free(abs);
                try w.print("(deny file-read*  (subpath \"{s}\"))\n", .{abs});
            }
            for (fs.allowWrite) |p| {
                const abs = try resolve_path(allocator, cwd, p);
                defer allocator.free(abs);
                try w.print("(allow file-write* (subpath \"{s}\"))\n", .{abs});
            }
            for (fs.denyWrite) |p| {
                const abs = try resolve_path(allocator, cwd, p);
                defer allocator.free(abs);
                try w.print("(deny file-write* (subpath \"{s}\"))\n", .{abs});
            }
        }
    }
}

fn resolve_path(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }

    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);

    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn network_only_policy(allocator: std.mem.Allocator, cwd: []const u8, config: ?Config, opencode_path: []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    const w = buffer.writer(allocator);
        
    try deny_default(w);

    try w.writeAll(
        \\; Process
        \\(allow process-exec)
        \\(allow process-fork)
        \\(allow sysctl*)
        \\(allow file-ioctl)
        \\(allow file-read-metadata)
        \\(allow file-map-executable)
    );

    try allow_network(w);

    try mach_lookup(w);

    try allow_opencode(w);

    try w.writeAll(
        \\(allow file-read-data (subpath "/opt/homebrew"))
        \\
        \\; CWD
        \\(allow file-read* (subpath (param "CWD")))
        \\
        \\(allow file-read-data (subpath "/private/var"))
        \\(allow file-read-data (subpath "/usr/share/icu"))
        \\
        \\(allow file* (literal "/dev/null"))
        \\(allow file-read-data (literal "/"))
        \\(allow file-read-data (subpath "/private/tmp"))
        \\(allow file-write-data (subpath "/private/var"))
        \\(allow file-write-create (subpath "/private/var"))
        \\
        \\(deny file* (subpath "/private/tmp/com.apple.launchd"))
    );

    try apply_filesystem_config(allocator, w, cwd, config);

    try w.print(
        \\; Allow reading opencode binary
        \\(allow file-read* (literal "{s}"))
        \\
    , .{opencode_path});

    return buffer.toOwnedSlice(allocator);
}

fn default_policy(allocator: std.mem.Allocator, cwd: []const u8, config: ?Config, opencode_path: []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    const w = buffer.writer(allocator);
    
    try deny_default(w);

    try w.writeAll(
        \\(allow process-exec)
        \\(allow process-fork)
        \\(allow sysctl*)
        \\(allow file-ioctl)
        \\(allow file-read-metadata)
        \\(allow file-map-executable)
        \\(allow process-info* (target same-sandbox))
        \\(allow signal (target same-sandbox))
        \\(allow mach-priv-task-port (target same-sandbox))
    );

    try allow_network(w);

    try mach_lookup(w);

    try allow_opencode(w);

    try w.writeAll(
        \\(allow file-read-data (subpath "/opt/homebrew"))
        \\
        \\; CWD
        \\(allow file-read* (subpath (param "CWD")))
        \\
        \\(allow file-read-data (subpath "/private/var"))
        \\(allow file-read-data (subpath "/usr/share/icu"))
        \\
        \\(allow file* (literal "/dev/null"))
        \\(allow file-read-data (literal "/"))
        \\(allow file-read-data (subpath "/private/tmp"))
        \\(allow file-write-data (subpath "/private/var"))
        \\(allow file-write-create (subpath "/private/var"))
        \\(allow file* (subpath (param "CWD")))
        \\
        \\(deny file* (subpath "/private/tmp/com.apple.launchd"))
    );

    try apply_filesystem_config(allocator, w, cwd, config);

    try w.print(
        \\; Allow reading opencode binary
        \\(allow file-read* (literal "{s}"))
        \\
    , .{opencode_path});

    return buffer.toOwnedSlice(allocator);
}
