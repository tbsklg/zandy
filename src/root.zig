const std = @import("std");

const sb_file = @embedFile("opencode.sb");

pub fn start_standbox(allocator: std.mem.Allocator) !void {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const cwd_env = try std.fmt.allocPrint(allocator, "CWD={s}", .{cwd});
    defer allocator.free(cwd_env);

    const argv = [_][]const u8{ "/usr/bin/sandbox-exec", "-D", cwd_env, "-p", sb_file, "/opt/homebrew/bin/opencode" };

    var process = std.process.Child.init(&argv, allocator);
    try process.spawn();
    _ = try process.wait();
}
