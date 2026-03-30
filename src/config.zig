const std = @import("std");

const config_path = ".config/zandy/config.json";

pub const Profile = enum {
    default,
    network_only,
};

pub const FileSystemConfig = struct {
    allowRead: []const []const u8,
    denyRead: []const []const u8,
    allowWrite: []const []const u8,
    denyWrite: []const []const u8,
};

pub const Config = struct {
    filesystem: ?FileSystemConfig,
    parsed: ?std.json.Parsed(std.json.Value),

    pub fn default(allocator: std.mem.Allocator, cwd: []const u8) !?Config {
        const local_path = try std.fs.path.join(allocator, &.{ cwd, ".zandy.json" });
        defer allocator.free(local_path);

        if (load_from_path(allocator, local_path)) |cfg| return cfg else |_| {}

        const global_path = try resolve_config_path(allocator);
        defer allocator.free(global_path);

        if (load_from_path(allocator, global_path)) |cfg| return cfg else |_| {}

        return null;
    }

    fn load_from_path(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        defer file.close();

        const raw = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(raw);

        return from_json(allocator, raw);
    }

    pub fn resolve_config_path(allocator: std.mem.Allocator) ![]u8 {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, config_path });
    }

    fn from_json(allocator: std.mem.Allocator, raw: []const u8) !Config {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            raw,
            .{ .ignore_unknown_fields = true },
        );
        errdefer parsed.deinit();

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

    pub fn deinit(self: *Config) void {
        if (self.parsed) |*p| p.deinit();
    }
};

fn parse_string_array(allocator: std.mem.Allocator, val: ?std.json.Value) ![]const []const u8 {
    const arr = if (val) |v| v.array else return &[_][]const u8{};
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    for (arr.items) |item| {
        try list.append(allocator, item.string);
    }
    return try list.toOwnedSlice(allocator);
}
