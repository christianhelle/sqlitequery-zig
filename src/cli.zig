//! CLI argument parsing and command execution.

const std = @import("std");
const Database = @import("database.zig").Database;
const export_mod = @import("export.zig");

pub const CliOptions = struct {
    db_path: ?[]const u8 = null,
    export_csv: bool = false,
    target_directory: ?[]const u8 = null,
    run_sql: ?[]const u8 = null,
    show_progress: bool = false,
    show_help: bool = false,
    show_version: bool = false,
    /// True when any CLI-only flag was given (triggers headless mode).
    cli_mode: bool = false,
};

pub const VERSION = "0.1.0";

const HELP_TEXT =
    \\Usage: sqlitequery [options] [database]
    \\A fast and lightweight cross-platform command-line and GUI tool for
    \\querying and manipulating SQLite databases.
    \\
    \\Options:
    \\  -h, --help              Show this help message
    \\  -v, --version           Show version information
    \\  -p, --progress          Show progress during operations
    \\  -e, --export-csv        Export all tables to CSV files
    \\  -d, --target-directory  Target directory for exported files
    \\  -r, --run-sql           Execute a SQL script file
    \\
    \\Arguments:
    \\  database                Path to the SQLite database file
    \\
    \\Examples:
    \\  sqlitequery /path/to/database.db
    \\  sqlitequery --export-csv /path/to/database.db
    \\  sqlitequery --export-csv --target-directory /tmp/export /path/to/database.db
    \\  sqlitequery --run-sql /path/to/script.sql /path/to/database.db
    \\
;

/// Parses command-line arguments into CliOptions.
/// The returned paths are slices into the args array (not owned).
pub fn parseArgs(args: []const []const u8) CliOptions {
    var opts = CliOptions{};
    var i: usize = 1; // skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.show_help = true;
            opts.cli_mode = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            opts.show_version = true;
            opts.cli_mode = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--progress")) {
            opts.show_progress = true;
            opts.cli_mode = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--export-csv")) {
            opts.export_csv = true;
            opts.cli_mode = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--target-directory")) {
            i += 1;
            if (i < args.len) {
                opts.target_directory = args[i];
                opts.cli_mode = true;
            }
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--run-sql")) {
            i += 1;
            if (i < args.len) {
                opts.run_sql = args[i];
                opts.cli_mode = true;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.db_path = arg;
        }
    }
    return opts;
}

/// Executes CLI commands. Returns 0 on success, non-zero on failure.
pub fn run(opts: CliOptions, allocator: std.mem.Allocator) !u8 {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    if (opts.show_help) {
        stdout.writeAll(HELP_TEXT) catch {};
        return 0;
    }
    if (opts.show_version) {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "sqlitequery {s}\n", .{VERSION}) catch return 1;
        stdout.writeAll(s) catch {};
        return 0;
    }

    const db_path = opts.db_path orelse {
        stderr.writeAll("Error: no database file specified.\n") catch {};
        stderr.writeAll("Run 'sqlitequery --help' for usage.\n") catch {};
        return 1;
    };

    var db = Database.open(db_path, allocator) catch |err| {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "Error opening '{s}': {}\n", .{ db_path, err }) catch "";
        stderr.writeAll(s) catch {};
        return 1;
    };
    defer db.close();

    if (opts.run_sql) |sql_file| {
        const sql = std.fs.cwd().readFileAlloc(allocator, sql_file, 1024 * 1024) catch |err| {
            var buf: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "Error reading '{s}': {}\n", .{ sql_file, err }) catch "";
            stderr.writeAll(s) catch {};
            return 1;
        };
        defer allocator.free(sql);

        var result = db.execute(sql, allocator) catch {
            var buf: [512]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "SQL error: {s}\n", .{db.lastError()}) catch "";
            stderr.writeAll(s) catch {};
            return 1;
        };
        defer result.deinit();

        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "SQL executed. Rows affected: {d}\n", .{result.affected_rows}) catch "";
        stdout.writeAll(s) catch {};
    }

    if (opts.export_csv) {
        const target = opts.target_directory orelse ".";
        export_mod.exportDatabaseCsv(&db, target, opts.show_progress, allocator) catch |err| {
            var buf: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "Export error: {}\n", .{err}) catch "";
            stderr.writeAll(s) catch {};
            return 1;
        };
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "CSV exported to: {s}\n", .{target}) catch "";
        stdout.writeAll(s) catch {};
    }

    return 0;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "parse --help sets show_help and cli_mode" {
    const args = [_][]const u8{ "prog", "--help" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.show_help);
    try std.testing.expect(opts.cli_mode);
    try std.testing.expect(!opts.show_version);
}

test "parse -v sets show_version" {
    const args = [_][]const u8{ "prog", "-v" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.show_version);
    try std.testing.expect(opts.cli_mode);
}

test "parse --export-csv with db path" {
    const args = [_][]const u8{ "prog", "--export-csv", "/path/to/db.sqlite" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.export_csv);
    try std.testing.expect(opts.cli_mode);
    try std.testing.expectEqualStrings("/path/to/db.sqlite", opts.db_path.?);
}

test "parse -d target directory" {
    const args = [_][]const u8{ "prog", "-e", "-d", "/tmp/export", "db.sqlite" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.export_csv);
    try std.testing.expectEqualStrings("/tmp/export", opts.target_directory.?);
    try std.testing.expectEqualStrings("db.sqlite", opts.db_path.?);
}

test "parse --run-sql" {
    const args = [_][]const u8{ "prog", "--run-sql", "script.sql", "db.sqlite" };
    const opts = parseArgs(&args);
    try std.testing.expectEqualStrings("script.sql", opts.run_sql.?);
    try std.testing.expectEqualStrings("db.sqlite", opts.db_path.?);
    try std.testing.expect(opts.cli_mode);
}

test "parse --progress flag" {
    const args = [_][]const u8{ "prog", "-p", "--export-csv", "db.sqlite" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.show_progress);
    try std.testing.expect(opts.export_csv);
}

test "parse db path only does not set cli_mode" {
    const args = [_][]const u8{ "prog", "/path/to/db.sqlite" };
    const opts = parseArgs(&args);
    try std.testing.expect(!opts.cli_mode);
    try std.testing.expectEqualStrings("/path/to/db.sqlite", opts.db_path.?);
}

test "parse no args" {
    const args = [_][]const u8{"prog"};
    const opts = parseArgs(&args);
    try std.testing.expect(!opts.cli_mode);
    try std.testing.expect(opts.db_path == null);
}

test "parse combined flags" {
    const args = [_][]const u8{ "prog", "-e", "-p", "-d", "/out", "test.db" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.export_csv);
    try std.testing.expect(opts.show_progress);
    try std.testing.expectEqualStrings("/out", opts.target_directory.?);
    try std.testing.expectEqualStrings("test.db", opts.db_path.?);
}

test "parse -h short form" {
    const args = [_][]const u8{ "prog", "-h" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.show_help);
}
