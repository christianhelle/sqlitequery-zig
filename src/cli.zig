const std = @import("std");
const database = @import("database.zig");
const analyzer = @import("analyzer.zig");
const export_mod = @import("export.zig");
const settings = @import("settings.zig");

const version = "1.0.0";

const help_text =
    \\Usage: sqlitequery [options] [database]
    \\
    \\A fast and lightweight cross-platform command line and GUI tool
    \\for querying and manipulating SQLite databases.
    \\
    \\Options:
    \\  -h, --help              Display this help and exit
    \\  -v, --version           Display version information and exit
    \\  -p, --progress          Show progress during export
    \\  -e, --export-csv        Export all tables to CSV files
    \\  -d, --target-directory   Target directory for export (default: current directory)
    \\  -r, --run-sql           Execute SQL file against the database
    \\  -s, --export-schema     Export database schema as SQL
    \\  --export-data           Export data as SQL INSERT statements
    \\
    \\Arguments:
    \\  database                Database file to open
    \\
    \\Examples:
    \\  sqlitequery database.db
    \\  sqlitequery --export-csv database.db
    \\  sqlitequery --export-csv --progress --target-directory ./export database.db
    \\  sqlitequery --run-sql script.sql database.db
    \\  sqlitequery --export-schema --target-directory ./export database.db
    \\
;

pub const CliOptions = struct {
    show_help: bool = false,
    show_version: bool = false,
    show_progress: bool = false,
    export_csv: bool = false,
    export_schema: bool = false,
    export_data: bool = false,
    run_sql: bool = false,
    target_directory: ?[]const u8 = null,
    database_file: ?[]const u8 = null,
    sql_file: ?[]const u8 = null,
};

pub fn parseArgs(args: []const []const u8) CliOptions {
    var opts = CliOptions{};
    var positionals: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.show_help = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            opts.show_version = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--progress")) {
            opts.show_progress = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--export-csv")) {
            opts.export_csv = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--export-schema")) {
            opts.export_schema = true;
        } else if (std.mem.eql(u8, arg, "--export-data")) {
            opts.export_data = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--run-sql")) {
            opts.run_sql = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--target-directory")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.target_directory = args[i];
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (positionals == 0) {
                if (opts.run_sql) {
                    opts.sql_file = arg;
                } else {
                    opts.database_file = arg;
                }
            } else if (positionals == 1 and opts.run_sql) {
                opts.database_file = arg;
            }
            positionals += 1;
        }
    }

    return opts;
}

pub fn run(allocator: std.mem.Allocator) !void {
    const all_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, all_args);

    const args = if (all_args.len > 1) all_args[1..] else all_args[0..0];
    const opts = parseArgs(args);

    if (opts.show_help) {
        const f = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        try f.writeAll(help_text);
        return;
    }

    if (opts.show_version) {
        const f = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "SQLite Query Analyzer {s}\n", .{version});
        try f.writeAll(msg);
        return;
    }

    if (opts.export_csv) {
        try runExportCsv(allocator, &opts);
        return;
    }

    if (opts.export_schema) {
        try runExportSchema(allocator, &opts);
        return;
    }

    if (opts.export_data) {
        try runExportData(allocator, &opts);
        return;
    }

    if (opts.run_sql) {
        try runSqlScript(allocator, &opts);
        return;
    }

    // GUI mode - launch the GUI
    const gui = @import("gui.zig");
    try gui.runGui(allocator, opts.database_file);
}

fn writeStdout(msg: []const u8) !void {
    const f = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try f.writeAll(msg);
}

fn writeStderr(msg: []const u8) !void {
    const f = std.fs.File{ .handle = std.posix.STDERR_FILENO };
    try f.writeAll(msg);
}

fn runExportCsv(allocator: std.mem.Allocator, opts: *const CliOptions) !void {
    const db_path = opts.database_file orelse {
        try writeStderr("Error: Database file is required for CSV export.\n");
        return;
    };

    const target_dir = opts.target_directory orelse ".";

    var db = database.Database.init(allocator);
    defer db.deinit();
    try db.open(db_path);

    var a = analyzer.Analyzer.init(allocator);
    var info = try a.analyze(&db);
    defer info.deinit();

    const total = try export_mod.exportAllToCsv(
        allocator,
        &db,
        &info,
        target_dir,
        ",",
        opts.show_progress,
    );

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Exported {d} row(s)\n", .{total});
    try writeStdout(msg);
}

fn runExportSchema(allocator: std.mem.Allocator, opts: *const CliOptions) !void {
    const db_path = opts.database_file orelse {
        try writeStderr("Error: Database file is required for schema export.\n");
        return;
    };

    var db = database.Database.init(allocator);
    defer db.deinit();
    try db.open(db_path);

    var a = analyzer.Analyzer.init(allocator);
    var info = try a.analyze(&db);
    defer info.deinit();

    if (opts.target_directory) |dir| {
        const path = try std.fmt.allocPrint(allocator, "{s}/schema.sql", .{dir});
        defer allocator.free(path);
        try export_mod.exportSchemaToFile(allocator, &info, path);
        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Schema exported to {s}\n", .{path});
        try writeStdout(msg);
    } else {
        const schema = try export_mod.exportSchema(allocator, &info);
        defer allocator.free(schema);
        try writeStdout(schema);
        try writeStdout("\n");
    }
}

fn runExportData(allocator: std.mem.Allocator, opts: *const CliOptions) !void {
    const db_path = opts.database_file orelse {
        try writeStderr("Error: Database file is required for data export.\n");
        return;
    };

    const target_dir = opts.target_directory orelse ".";
    const path = try std.fmt.allocPrint(allocator, "{s}/data.sql", .{target_dir});
    defer allocator.free(path);

    var db = database.Database.init(allocator);
    defer db.deinit();
    try db.open(db_path);

    var a = analyzer.Analyzer.init(allocator);
    var info = try a.analyze(&db);
    defer info.deinit();

    const total = try export_mod.exportDataToSqlFile(allocator, &db, &info, path);
    var buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Exported {d} row(s) to {s}\n", .{ total, path });
    try writeStdout(msg);
}

fn runSqlScript(allocator: std.mem.Allocator, opts: *const CliOptions) !void {
    const sql_file = opts.sql_file orelse {
        try writeStderr("Error: SQL file is required.\n");
        return;
    };

    const db_path = opts.database_file orelse {
        try writeStderr("Error: Database file is required.\n");
        return;
    };

    const sql_contents = std.fs.cwd().readFileAlloc(allocator, sql_file, 10 * 1024 * 1024) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: Cannot read SQL file '{s}': {s}\n", .{ sql_file, @errorName(err) }) catch "Error reading SQL file\n";
        try writeStderr(msg);
        return;
    };
    defer allocator.free(sql_contents);

    var db = database.Database.init(allocator);
    defer db.deinit();
    try db.open(db_path);

    var it = std.mem.splitScalar(u8, sql_contents, ';');
    var executed: usize = 0;
    while (it.next()) |stmt_raw| {
        const stmt = std.mem.trim(u8, stmt_raw, " \t\n\r");
        if (stmt.len == 0) continue;

        const full_stmt = try std.fmt.allocPrint(allocator, "{s};", .{stmt});
        defer allocator.free(full_stmt);

        db.execute(full_stmt) catch |err| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error executing statement: {s}\n", .{@errorName(err)}) catch "Error\n";
            writeStderr(msg) catch {};
            continue;
        };
        executed += 1;
    }

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Executed {d} statement(s)\n", .{executed});
    try writeStdout(msg);
}

// --- Tests ---

test "parse args help" {
    const args = [_][]const u8{"--help"};
    const opts = parseArgs(&args);
    try std.testing.expect(opts.show_help);
}

test "parse args version" {
    const args = [_][]const u8{"-v"};
    const opts = parseArgs(&args);
    try std.testing.expect(opts.show_version);
}

test "parse args export csv" {
    const args = [_][]const u8{ "--export-csv", "--progress", "test.db" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.export_csv);
    try std.testing.expect(opts.show_progress);
    try std.testing.expectEqualStrings("test.db", opts.database_file.?);
}

test "parse args export csv with target dir" {
    const args = [_][]const u8{ "-e", "-d", "/tmp/export", "test.db" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.export_csv);
    try std.testing.expectEqualStrings("/tmp/export", opts.target_directory.?);
    try std.testing.expectEqualStrings("test.db", opts.database_file.?);
}

test "parse args run sql" {
    const args = [_][]const u8{ "--run-sql", "script.sql", "test.db" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.run_sql);
    try std.testing.expectEqualStrings("script.sql", opts.sql_file.?);
    try std.testing.expectEqualStrings("test.db", opts.database_file.?);
}

test "parse args database file only" {
    const args = [_][]const u8{"database.db"};
    const opts = parseArgs(&args);
    try std.testing.expectEqualStrings("database.db", opts.database_file.?);
    try std.testing.expect(!opts.export_csv);
    try std.testing.expect(!opts.show_help);
}

test "parse args no args" {
    const args = [_][]const u8{};
    const opts = parseArgs(&args);
    try std.testing.expect(opts.database_file == null);
}

test "parse args short flags" {
    const args = [_][]const u8{ "-h" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.show_help);
}

test "parse args export schema" {
    const args = [_][]const u8{ "--export-schema", "test.db" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.export_schema);
    try std.testing.expectEqualStrings("test.db", opts.database_file.?);
}

test "parse args export data" {
    const args = [_][]const u8{ "--export-data", "-d", "/tmp", "test.db" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.export_data);
    try std.testing.expectEqualStrings("/tmp", opts.target_directory.?);
    try std.testing.expectEqualStrings("test.db", opts.database_file.?);
}
