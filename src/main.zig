const std = @import("std");
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Profile = config_mod.Profile;
const sandbox = @import("sandbox.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const profile = blk: {
        var args = std.process.args();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--network-only")) break :blk Profile.network_only;
        }
        break :blk Profile.default;
    };

    var cfg = try Config.default(allocator, cwd);
    defer if (cfg) |*c| c.deinit();

    try sandbox.start_sandbox(allocator, cwd, cfg, profile);
}
