const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
        @compileError("zandy runs on macOS on Apple Silicon only");
    }
}

/// /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sandbox.h
pub extern "c" fn sandbox_init(profile: [*c]const u8, flags: u64, errorbuf: [*c][*c]u8) c_int;

/// https://chromium.googlesource.com/chromium/src/+/main/sandbox/mac/seatbelt.cc
pub extern "c" fn sandbox_init_with_parameters(
    profile: [*:0]const u8,
    flags: u64,
    parameters: [*:null]const ?[*:0]const u8,
    errorbuf: *?[*:0]u8,
) c_int;

/// /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sandbox.h
pub extern fn sandbox_free_error(errorbuf: [*c]u8) void;

pub extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

const cs_darwin_user_temp_dir = 65537;
extern "c" fn confstr(name: c_int, buf: ?[*]u8, len: usize) usize;

pub fn userTempDir(arena: std.mem.Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = confstr(cs_darwin_user_temp_dir, &buf, buf.len);
    if (len == 0 or len > buf.len) return error.NoUserTempDir;
    return arena.dupe(u8, buf[0 .. len - 1]);
}

pub fn realPath(arena: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    const path_z = try arena.dupeZ(u8, path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(path_z.ptr, &buf) orelse return error.InvalidPath;
    return arena.dupeZ(u8, std.mem.span(resolved));
}

test "realPath resolves /tmp to /private/tmp" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectEqualStrings("/private/tmp", try realPath(arena_state.allocator(), "/tmp"));
}

test "userTempDir resolves into /private/var/folders" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try realPath(arena, try userTempDir(arena));
    try std.testing.expect(std.mem.startsWith(u8, dir, "/private/var/folders/"));
}
