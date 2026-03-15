const std = @import("std");
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const sandbox = @import("sandbox.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    var cfg = try Config.load(allocator, cwd);
    defer if (cfg) |*c| c.deinit();

    try sandbox.start_sandbox(allocator, cwd, cfg);
}
