const std = @import("std");

pub const StorePath = struct {
    path: []const u8,
};

const prefix = "/nix/store/";
const hash_len = 32;
const hash_alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
const name_extra = "+-._?=";

pub fn parse(line: []const u8) !StorePath {
    if (!std.mem.startsWith(u8, line, prefix)) return error.InvalidStorePath;
    const rest = line[prefix.len..];
    if (rest.len < hash_len + 2) return error.InvalidStorePath;

    for (rest[0..hash_len]) |c| {
        if (std.mem.indexOfScalar(u8, hash_alphabet, c) == null) return error.InvalidStorePath;
    }
    if (rest[hash_len] != '-') return error.InvalidStorePath;

    for (rest[hash_len + 1 ..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, name_extra, c) == null) return error.InvalidStorePath;
    }
    return .{ .path = line };
}

pub fn owner(path: []const u8) !StorePath {
    if (!std.mem.startsWith(u8, path, prefix)) return error.InvalidStorePath;
    const end = std.mem.indexOfScalarPos(u8, path, prefix.len, '/') orelse path.len;
    return parse(path[0..end]);
}

pub fn parseStorePaths(arena: std.mem.Allocator, bytes: []const u8) ![]const StorePath {
    var paths: std.ArrayList(StorePath) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
    while (lines.next()) |line| try paths.append(arena, try parse(line));
    return paths.items;
}

test "parses a store path" {
    const p = try parse("/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0");
    try std.testing.expectEqualStrings("/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0", p.path);
}

test "rejects a path outside the store" {
    try std.testing.expectError(error.InvalidStorePath, parse("/usr/bin/rg"));
}

test "rejects a short hash" {
    try std.testing.expectError(error.InvalidStorePath, parse("/nix/store/lw5h7x6k-ripgrep-15.2.0"));
}

test "rejects a hash with characters outside nix base32" {
    try std.testing.expectError(error.InvalidStorePath, parse("/nix/store/ew5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0"));
}

test "rejects a missing dash after the hash" {
    try std.testing.expectError(error.InvalidStorePath, parse("/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j_ripgrep-15.2.0"));
}

test "rejects an empty name" {
    try std.testing.expectError(error.InvalidStorePath, parse("/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-"));
}

test "rejects a path below a store path" {
    try std.testing.expectError(error.InvalidStorePath, parse("/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0/bin"));
}

test "owner is the store path a file lives in" {
    const p = try owner("/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0/bin/rg");
    try std.testing.expectEqualStrings("/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0", p.path);
}

test "owner rejects a relative binary" {
    try std.testing.expectError(error.InvalidStorePath, owner("glab"));
}

test "parses one store path per line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const paths = try parseStorePaths(arena_state.allocator(),
        \\/nix/store/7f0sryhgq9arkgzmv2pfzyxn40p7j69f-pcre2-10.48
        \\/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0
        \\
    );

    try std.testing.expectEqual(2, paths.len);
    try std.testing.expectEqualStrings("/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0", paths[1].path);
}

test "rejects a file with an invalid line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.InvalidStorePath, parseStorePaths(arena_state.allocator(),
        \\/nix/store/7f0sryhgq9arkgzmv2pfzyxn40p7j69f-pcre2-10.48
        \\/opt/homebrew/bin
    ));
}

test "rejects an empty file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.InvalidStorePath, parseStorePaths(arena_state.allocator(), ""));
}
