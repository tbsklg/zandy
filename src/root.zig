const std = @import("std");

const sb_file = @embedFile("opencode.sb");

pub fn start_sandbox(allocator: std.mem.Allocator) !void {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const cwd_env = try std.fmt.allocPrint(allocator, "CWD={s}", .{cwd});
    defer allocator.free(cwd_env);

    const argv = [_][]const u8{ "/usr/bin/sandbox-exec", "-D", cwd_env, "-p", sb_file, "/opt/homebrew/bin/opencode" };

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
