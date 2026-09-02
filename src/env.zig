const std = @import("std");

const Env = @This();

home: [:0]const u8,
cwd: [:0]const u8,
tmpdir: [:0]const u8,

pub fn init(arena: std.mem.Allocator, io: std.Io, envMap: *std.process.Environ.Map) !Env {
    const cwd = try std.process.currentPathAlloc(io, arena);
    const home = envMap.get("HOME") orelse return error.NoHome;
    const tmpdir = envMap.get("TMPDIR") orelse "/private/tmp";

    return .{
        .home = try arena.dupeZ(u8, home),
        .cwd = try arena.dupeZ(u8, cwd),
        .tmpdir = try arena.dupeZ(u8, tmpdir),
    };
}
