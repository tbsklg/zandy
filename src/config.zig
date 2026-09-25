const std = @import("std");

const Config = @This();

const config_path = ".config/zandy/config.json";

filesystem: ?FileSystem,
parsed: ?std.json.Parsed(std.json.Value),

pub const FileSystem = struct {
    allowRead: []const []const u8,
    denyRead: []const []const u8,
    allowWrite: []const []const u8,
    denyWrite: []const []const u8,
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, home: []const u8, cwd: []const u8) !?Config {
    const local_path = try std.fs.path.join(allocator, &.{ cwd, ".zandy.json" });
    if (load_from_path(allocator, io, local_path)) |cfg| return cfg else |_| {}

    const global_path = try std.fs.path.join(allocator, &.{ home, config_path });
    if (load_from_path(allocator, io, global_path)) |cfg| return cfg else |_| {}

    return null;
}

fn load_from_path(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(raw);

    return from_json(allocator, raw);
}

fn from_json(allocator: std.mem.Allocator, raw: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );

    const root = parsed.value.object;
    const fs_val = root.get("filesystem") orelse return .{ .filesystem = null, .parsed = parsed };
    const file_system = fs_val.object;

    return .{
        .filesystem = .{
            .allowRead = try parse_string_array(allocator, file_system.get("allowRead")),
            .denyRead = try parse_string_array(allocator, file_system.get("denyRead")),
            .allowWrite = try parse_string_array(allocator, file_system.get("allowWrite")),
            .denyWrite = try parse_string_array(allocator, file_system.get("denyWrite")),
        },
        .parsed = parsed,
    };
}

fn parse_string_array(allocator: std.mem.Allocator, val: ?std.json.Value) ![]const []const u8 {
    const arr = if (val) |v| v.array else return &[_][]const u8{};
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    for (arr.items) |item| {
        try list.append(allocator, item.string);
    }
    return try list.toOwnedSlice(allocator);
}
