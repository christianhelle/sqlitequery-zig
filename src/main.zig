//! SQLite Query Analyzer - Zig rewrite
//! Entry point: selects CLI mode (headless) or GUI mode based on arguments.

const std = @import("std");
const cli = @import("cli.zig");
const ui_mod = @import("ui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const opts = cli.parseArgs(args);

    if (opts.cli_mode) {
        const exit_code = try cli.run(opts, allocator);
        std.process.exit(exit_code);
    }

    try ui_mod.runGui(opts.db_path, allocator);
}
