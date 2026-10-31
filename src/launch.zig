const std = @import("std");
const macos = @import("macos.zig");
const sbpl = @import("sandbox/sbpl.zig");
const broker = @import("broker/server.zig");
const rpc = @import("broker/rpc.zig");
const registry = @import("broker/registry.zig");
const gateway = @import("gateway.zig");
const secret = @import("secret.zig");

const Env = @import("env/env.zig");
const SandboxEnv = @import("env/sandbox_env.zig");
const Preset = @import("env/manifest.zig").Preset;

const log = std.log.scoped(.zandy);

const Argv = [:null]const ?[*:0]const u8;
const Parameters = [8:null]?[*:0]const u8;

pub fn launch(init: std.process.Init, sandbox_env: SandboxEnv, user_args: []const [:0]const u8, profile: sbpl.Profile, env: Env) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const environ = init.environ_map;
    const manifest = sandbox_env.manifest;
    const preset = manifest.preset;

    const session = std.c.getpid();
    const started = std.Io.Clock.awake.now(io);
    const tag = try std.fmt.allocPrint(arena, "zandy-{d}", .{session});
    log.info("session {d}: env {s}, preset {s}, cwd {s}", .{ session, sandbox_env.root.path, preset.name, env.cwd });

    var dir_buf: [std.fs.max_name_bytes]u8 = undefined;
    const dir_path = try broker.sessionDirPath(&dir_buf, env.home, session);
    try broker.createSocketDir(io, dir_path);
    defer broker.removeSessionDir(io, dir_path) catch |err| log.warn("session cleanup failed: {t}", .{err});

    const adapter_pipes = try materializeAdapters(arena, io, env.home, dir_path, manifest.adapters);

    var running = try startGateway(arena, io, manifest.gateway, environ, env.home, dir_path);
    defer if (running) |*r| r.stop(io);

    var sock_buf: [std.fs.max_name_bytes]u8 = undefined;
    const sock_path = try std.fmt.bufPrintZ(&sock_buf, "{s}/broker.sock", .{dir_path});
    var server = try broker.listen(io, sock_path);
    const ticket = broker.newTicket(io);

    const profile_z = try finalProfile(arena, profile, running, tag);
    const path = try std.fs.path.joinZ(arena, &.{ sandbox_env.bin, preset.binary });
    const argv = try buildArgv(arena, preset, user_args);
    const envp = try sandboxEnviron(arena, environ, preset, sandbox_env.bin, sock_path, &ticket, running);
    const parameters = profileParameters(env, sock_path);

    const ctx: rpc.Context = .{ .ticket = &ticket, .registry = .{ .capabilities = try registry.parseAdapters(arena, manifest.adapters, adapter_pipes, dir_path) }, .environ = environ };

    const pid = try spawnSandboxed(profile_z, &parameters, path, argv, envp);

    const thread = try std.Thread.spawn(.{}, broker.serveLoop, .{ io, init.gpa, &server, &ctx });
    thread.detach();

    const status = waitAgent(pid) catch |err| {
        log.err("waiting for agent failed: {t}", .{err});
        return;
    };
    logExit(status, started.untilNow(io, .awake).toMilliseconds());
}

fn waitAgent(pid: std.c.pid_t) !u32 {
    var status: c_int = 0;
    while (true) {
        switch (std.posix.errno(std.c.waitpid(pid, &status, 0))) {
            .SUCCESS => return @bitCast(status),
            .INTR => continue,
            else => return error.WaitFailed,
        }
    }
}

fn logExit(status: u32, duration_ms: i64) void {
    if (std.c.W.IFEXITED(status)) {
        log.info("agent exited with {d} after {d}ms", .{ std.c.W.EXITSTATUS(status), duration_ms });
    } else if (std.c.W.IFSIGNALED(status)) {
        log.info("agent killed by {t} after {d}ms", .{ std.c.W.TERMSIG(status), duration_ms });
    } else {
        log.info("agent ended with status {d} after {d}ms", .{ status, duration_ms });
    }
}

fn materializeAdapters(arena: std.mem.Allocator, io: std.Io, home: []const u8, dir_path: []const u8, adapters: []const registry.Adapter) ![]const []const secret.Pipe {
    const adapter_pipes = try arena.alloc([]const secret.Pipe, adapters.len);
    for (adapters, adapter_pipes) |adapter, *pipes| {
        log.info("adapter {s}: secrets {f}", .{ adapter.name, secretNames(adapter.secrets) });
        pipes.* = secret.materialize(arena, io, home, try registry.dirFor(arena, dir_path, adapter), adapter.secrets, adapter.files) catch |err| {
            log.err("adapter '{s}' could not get its secrets: {t}", .{ adapter.name, err });
            return err;
        };
    }
    return adapter_pipes;
}

fn startGateway(arena: std.mem.Allocator, io: std.Io, config: ?gateway.Gateway, environ: *const std.process.Environ.Map, home: []const u8, dir_path: []const u8) !?gateway.Running {
    const c = config orelse return null;
    log.info("gateway {s}: secrets {f}", .{ c.name, secretNames(c.secrets) });
    return gateway.start(arena, io, c, environ, home, try secret.dirFor(arena, dir_path, "gateway")) catch |err| {
        log.err("gateway '{s}' could not start: {t}", .{ c.name, err });
        return err;
    };
}

fn secretNames(sources: secret.Sources) std.fmt.Alt(secret.Sources, writeSecretNames) {
    return .{ .data = sources };
}

fn writeSecretNames(sources: secret.Sources, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (sources.map.keys(), 0..) |name, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(name);
    }
}

fn finalProfile(arena: std.mem.Allocator, profile: sbpl.Profile, running: ?gateway.Running, tag: []const u8) ![:0]u8 {
    const gateway_rules: []const sbpl.Rule = if (running) |r| try arena.dupe(sbpl.Rule, &.{
        sbpl.Rule.allow(.network_outbound, .{ .remote_tcp = try std.fmt.allocPrint(arena, "localhost:{d}", .{r.port}) }),
    }) else &.{};

    const final: sbpl.Profile = .{
        .version = profile.version,
        .deny_default = profile.deny_default,
        .rules = try std.mem.concat(arena, sbpl.Rule, &.{ profile.rules, gateway_rules }),
        .message = tag,
    };

    var aw = std.Io.Writer.Allocating.init(arena);
    try final.write(&aw.writer);

    return arena.dupeZ(u8, aw.written());
}

fn buildArgv(arena: std.mem.Allocator, preset: Preset, user_args: []const [:0]const u8) !Argv {
    const extra_args = try std.mem.concat(arena, [:0]const u8, &.{ preset.args, user_args });
    const argv = try arena.allocSentinel(?[*:0]const u8, 1 + extra_args.len, null);
    argv[0] = preset.binary.ptr;
    for (extra_args, argv[1..]) |arg, *slot| slot.* = arg.ptr;
    return argv;
}

fn sandboxEnviron(arena: std.mem.Allocator, environ: *const std.process.Environ.Map, preset: Preset, bin_dir: []const u8, sock_path: []const u8, ticket: []const u8, running: ?gateway.Running) !Argv {
    var map = std.process.Environ.Map.init(arena);
    for (preset.env) |name| {
        if (environ.get(name)) |value| try map.put(name, value);
    }
    try map.put("PATH", bin_dir);
    try map.put("SHELL", try std.fs.path.join(arena, &.{ bin_dir, "bash" }));
    try map.put("BROKER_SOCK", sock_path);
    try map.put("BROKER_TICKET", ticket);
    if (running) |r| for (try gateway.environFor(arena, preset.gatewayEnv, r)) |entry| try map.put(entry.name, entry.value);
    return (try map.createPosixBlock(arena, .{})).slice;
}

fn profileParameters(env: Env, sock_path: [:0]const u8) Parameters {
    return .{
        "CWD",         env.cwd.ptr,
        "HOME",        env.home.ptr,
        "TMPDIR",      env.tmpdir.ptr,
        "BROKER_SOCK", sock_path.ptr,
    };
}

fn spawnSandboxed(profile: [:0]const u8, parameters: *const Parameters, path: [:0]const u8, argv: Argv, envp: Argv) !std.c.pid_t {
    const pid = std.c.fork();
    if (pid == -1) return error.ForkFailed;
    if (pid != 0) return pid;

    var errbuf: ?[*:0]u8 = null;
    const rc = macos.sandbox_init_with_parameters(profile.ptr, 0, parameters, &errbuf);
    defer if (errbuf) |buf| macos.sandbox_free_error(buf);

    if (rc != 0) {
        if (errbuf) |buf| {
            const msg = std.mem.span(buf);
            _ = std.c.write(2, "sandbox initialization failed: ", 31);
            _ = std.c.write(2, msg.ptr, msg.len);
            _ = std.c.write(2, "\n", 1);
        }
        std.c._exit(1);
    }

    _ = std.c.execve(path.ptr, argv.ptr, envp.ptr);
    std.c._exit(127);
}
