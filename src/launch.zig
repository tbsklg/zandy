const std = @import("std");
const macos = @import("macos.zig");
const sbpl = @import("sbpl.zig");
const broker = @import("broker.zig");
const rpc = @import("rpc.zig");
const registry = @import("registry.zig");

const Env = @import("env.zig");
const SandboxEnv = @import("sandbox_env.zig");

pub fn launch(init: std.process.Init, sandbox_env: SandboxEnv, user_args: []const [:0]const u8, profile: sbpl.Profile, env: Env) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const environ = init.environ_map;
    const manifest = sandbox_env.manifest;
    const preset = manifest.preset;
    const bin_dir = sandbox_env.bin;

    const profile_z = try serialize(arena, profile);
    const path = try std.fs.path.joinZ(arena, &.{ bin_dir, preset.binary });

    const extra_args = try std.mem.concat(arena, [:0]const u8, &.{ preset.args, user_args });
    const argv = try arena.allocSentinel(?[*:0]const u8, 1 + extra_args.len, null);
    argv[0] = preset.binary.ptr;
    for (extra_args, argv[1..]) |arg, *slot| slot.* = arg.ptr;

    var dir_buf: [std.fs.max_name_bytes]u8 = undefined;
    const dir_path = try broker.sessionDirPath(&dir_buf, env.home, std.c.getpid());
    try broker.createSocketDir(io, dir_path);
    defer broker.removeSocketDir(io, dir_path) catch |err| std.log.warn("broker cleanup failed: {t}", .{err});

    var sock_buf: [std.fs.max_name_bytes]u8 = undefined;
    const sock_path = try std.fmt.bufPrintZ(&sock_buf, "{s}/broker.sock", .{dir_path});

    const parameters = [_:null]?[*:0]const u8{
        "CWD",
        env.cwd.ptr,
        "HOME",
        env.home.ptr,
        "TMPDIR",
        env.tmpdir.ptr,
        "BROKER_SOCK",
        sock_path.ptr,
    };

    var server = try broker.listen(io, sock_path);

    const ticket = broker.newTicket(io);
    var sandbox_environ = std.process.Environ.Map.init(arena);
    for (preset.env) |name| {
        if (environ.get(name)) |value| try sandbox_environ.put(name, value);
    }
    try sandbox_environ.put("PATH", bin_dir);
    try sandbox_environ.put("SHELL", try std.fs.path.join(arena, &.{ bin_dir, "bash" }));
    try sandbox_environ.put("BROKER_SOCK", sock_path);
    try sandbox_environ.put("BROKER_TICKET", &ticket);
    const envp = try sandbox_environ.createPosixBlock(arena, .{});

    const ctx: rpc.Context = .{ .ticket = &ticket, .registry = .{ .capabilities = try registry.parseAdapters(arena, manifest.adapters) }, .environ = environ };

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
            return std.c._exit(1);
        }

        _ = std.c.execve(path.ptr, argv.ptr, envp.slice.ptr);
        return std.c._exit(127);
    }

    const thread = try std.Thread.spawn(.{}, broker.serveLoop, .{ io, init.gpa, &server, &ctx });
    thread.detach();

    _ = std.c.waitpid(pid, null, 0);

    std.log.debug("Child process terminated", .{});
}

fn serialize(allocator: std.mem.Allocator, profile: sbpl.Profile) ![:0]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try profile.write(&aw.writer);

    return allocator.dupeZ(u8, aw.written());
}
