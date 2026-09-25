const std = @import("std");
const macos = @import("macos.zig");
const sbpl = @import("sbpl.zig");

const Env = @import("env.zig");

pub fn launch(arena: std.mem.Allocator, io: std.Io, binary: [:0]const u8, profile: sbpl.Profile, env: Env) !void {
    const profile_z = try serialize(arena, profile);
    const path = try findBinary(arena, io, binary);

    const parameters = [_:null]?[*:0]const u8{
        "CWD",
        env.cwd.ptr,
        "HOME",
        env.home.ptr,
        "TMPDIR",
        env.tmpdir.ptr,
    };

    const argv = [_:null]?[*:0]const u8{binary.ptr};

    const pid = std.c.fork();
    if (pid == -1) return error.ForkFailed;

    if (pid == 0) {
        var errbuf: ?[*:0]u8 = null;

        const rc = macos.sandbox_init_with_parameters(profile_z.ptr, 0, &parameters, &errbuf);
        defer if (errbuf) |buf| macos.sandbox_free_error(buf);

        if (rc != 0) {
            if (errbuf) |buf| {
                const msg = std.mem.span(buf);
                _ = std.c.write(2, "sandbox initialization failed: ", 31);
                _ = std.c.write(2, msg.ptr, msg.len);
                _ = std.c.write(2, "\n", 1);
            }
            return error.SandboxInitFailed;
        }

        _ = std.c.execve(path.ptr, argv[0..argv.len], @ptrCast(std.c.environ));
        return error.ExecFailed;
    }

    _ = std.c.waitpid(pid, null, 0);
    std.log.debug("Child process terminated", .{});
}

fn serialize(allocator: std.mem.Allocator, profile: sbpl.Profile) ![:0]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try profile.write(&aw.writer);

    return allocator.dupeZ(u8, aw.written());
}

fn findBinary(allocator: std.mem.Allocator, io: std.Io, binary: []const u8) ![:0]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "/usr/bin/which", binary } });

    const path = std.mem.trimEnd(u8, result.stdout, "\n\r ");
    if (path.len == 0) return error.BinaryNotFound;

    return allocator.dupeZ(u8, path);
}
