//! Root test aggregator: imports all modules so their inline tests are run.

const std = @import("std");

test {
    std.testing.refAllDecls(@import("database.zig"));
    std.testing.refAllDecls(@import("export.zig"));
    std.testing.refAllDecls(@import("cli.zig"));
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("app.zig"));
}
