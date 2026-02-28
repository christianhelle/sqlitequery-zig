const std = @import("std");
const database = @import("database.zig");
const analyzer = @import("analyzer.zig");
const export_mod = @import("export.zig");
const cli = @import("cli.zig");
const settings = @import("settings.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try cli.run(allocator);
}

test "imports compile" {
    _ = database;
    _ = analyzer;
    _ = export_mod;
    _ = cli;
    _ = settings;
}
