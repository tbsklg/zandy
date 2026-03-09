const std = @import("std");
const zandy_next = @import("zandy_next");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    try zandy_next.start_standbox(allocator);
}
