const std = @import("std");
const config_mod = @import("config.zig");
const Config = config_mod.Config;

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

pub fn start_sandbox(allocator: std.mem.Allocator, cwd: []const u8, config: ?Config) !void {
    const cwd_env = try std.fmt.allocPrint(allocator, "CWD={s}", .{cwd});
    defer allocator.free(cwd_env);

    const opencode_path = find_opencode(allocator) catch |err| {
        std.debug.print("zandy: could not find opencode in PATH: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(opencode_path);

    const policy = try build_policy(allocator, cwd, config);
    defer allocator.free(policy);
    const argv = [_][]const u8{ "/usr/bin/sandbox-exec", "-D", cwd_env, "-p", policy, opencode_path };

    var process = std.process.Child.init(&argv, allocator);
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

fn resolve_path(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }

    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);

    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn build_policy(allocator: std.mem.Allocator, cwd: []const u8, config: ?Config) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    const w = buffer.writer(allocator);

    try w.writeAll(
        \\(version 1)
        \\(deny default)
        \\
        \\(allow process-exec)
        \\(allow process-fork)
        \\(allow process-info* (target same-sandbox))
        \\(allow signal (target same-sandbox))
        \\(allow mach-priv-task-port (target same-sandbox))
        \\(allow sysctl*)
        \\(allow file-ioctl)
        \\(allow file-read-metadata)
        \\(allow file-map-executable)
        \\
        \\; Network
        \\(allow network-outbound)
        \\(allow system-socket (socket-domain 32))
        \\
        \\; Mach services required by Bun runtime and opencode
        \\(allow mach-lookup (global-name "com.apple.SecurityServer"))
        \\(allow mach-lookup (global-name "com.apple.securityd.xpc"))
        \\(allow mach-lookup (global-name "com.apple.bsd.dirhelper"))
        \\(allow mach-lookup (global-name "com.apple.logd"))
        \\
        \\; ============================================
        \\; READ - allow broad, deny sensitive (last-match-wins)
        \\; ============================================
        \\(allow file-read*)
        \\
        \\; Secrets & credentials
        \\(deny file-read* (regex #"/Users/[^/]+/\.ssh(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.ssh(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.gnupg(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.gnupg(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.aws(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.aws(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.docker(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.docker(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.netrc$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.netrc$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.git-credentials$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.git-credentials$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.kube(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.kube(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.azure(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.azure(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.config/gcloud(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.config/gcloud(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.npmrc$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.npmrc$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.env(\.[^/]+)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.env(\.[^/]+)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.envrc$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.envrc$"))
        \\(deny file-read* (literal (string-append (param "CWD") "/.envrc")))
        \\(deny file-write-unlink (literal (string-append (param "CWD") "/.envrc")))
        \\(deny file-read* (literal (string-append (param "CWD") "/.env")))
        \\(deny file-write-unlink (literal (string-append (param "CWD") "/.env")))
        \\
        \\; Shell history
        \\(deny file-read* (regex #"/Users/[^/]+/\.(bash|zsh|fish|python|node_repl|psql|mysql|irb|lesshst)_?history$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.(bash|zsh|fish|python|node_repl|psql|mysql|irb|lesshst)_?history$"))
        \\(deny file-read* (regex #"/Users/[^/]+/\.zsh_sessions(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/\.zsh_sessions(/.*)?$"))
        \\
        \\; Keychain
        \\(deny file-read* (regex #"/Users/[^/]+/Library/Keychains(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Library/Keychains(/.*)?$"))
        \\
        \\; Browser data
        \\(deny file-read* (regex #"/Users/[^/]+/Library/Application Support/Google/Chrome(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Library/Application Support/Google/Chrome(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/Library/Application Support/Firefox(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Library/Application Support/Firefox(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/Library/Application Support/1Password(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Library/Application Support/1Password(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/Library/Safari(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Library/Safari(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/Library/Cookies(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Library/Cookies(/.*)?$"))
        \\
        \\; Personal folders
        \\(deny file-read* (regex #"/Users/[^/]+/Desktop(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Desktop(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/Documents(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Documents(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/Downloads(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Downloads(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/Pictures(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Pictures(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/Movies(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Movies(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/Music(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Music(/.*)?$"))
        \\
        \\; Mail & Messages
        \\(deny file-read* (regex #"/Users/[^/]+/Library/Messages(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Library/Messages(/.*)?$"))
        \\(deny file-read* (regex #"/Users/[^/]+/Library/Mail(/.*)?$"))
        \\(deny file-write-unlink (regex #"/Users/[^/]+/Library/Mail(/.*)?$"))
        \\
        \\; ============================================
        \\; WRITE - restricted
        \\; ============================================
        \\(allow file-write-data (literal "/dev/null"))
        \\(allow file-write-data (literal "/dev/dtracehelper"))
        \\(allow file-write* (subpath (param "CWD")))
        \\(allow file-write* (regex #"/Users/[^/]+/\.config/opencode/.*"))
        \\(allow file-write* (regex #"/Users/[^/]+/\.opencode/.*"))
        \\(allow file-write* (regex #"/Users/[^/]+/Library/Application Support/opencode/.*"))
        \\(allow file-write* (regex #"/Users/[^/]+/Library/Logs/opencode/.*"))
        \\(allow file-write* (regex #"/Users/[^/]+/\.local/share/.*"))
        \\(allow file-write* (regex #"/Users/[^/]+/\.local/state/.*"))
        \\(allow file-write* (regex #"/Users/[^/]+/\.cache/opencode/.*"))
        \\(allow file-write* (regex #"/Users/[^/]+/\.cache/bun/.*"))
        \\(allow file-write* (subpath "/private/tmp"))
        \\(allow file-write* (subpath "/private/var/folders"))
        \\
    );

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

    return buffer.toOwnedSlice(allocator);
}
