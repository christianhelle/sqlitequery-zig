//! Export functionality: CSV, SQL INSERT scripts, and schema dumps.

const std = @import("std");
const Database = @import("database.zig").Database;

pub const ExportError = error{
    QueryFailed,
    WriteFailed,
    OutOfMemory,
};

/// Exports all rows of a table as CSV to the given ArrayList buffer.
pub fn exportTableCsvBuf(
    db: *Database,
    table_name: []const u8,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ExportError!void {
    const sql = std.fmt.allocPrint(allocator, "SELECT * FROM \"{s}\";", .{table_name}) catch
        return ExportError.OutOfMemory;
    defer allocator.free(sql);

    var result = db.execute(sql, allocator) catch return ExportError.QueryFailed;
    defer result.deinit();

    const w = buf.writer(allocator);

    // Header row
    for (result.columns, 0..) |col, i| {
        if (i > 0) w.writeByte(',') catch return ExportError.WriteFailed;
        writeCsvField(col, w) catch return ExportError.WriteFailed;
    }
    w.writeByte('\n') catch return ExportError.WriteFailed;

    // Data rows
    for (result.rows) |row| {
        for (row, 0..) |val, i| {
            if (i > 0) w.writeByte(',') catch return ExportError.WriteFailed;
            writeCsvField(val, w) catch return ExportError.WriteFailed;
        }
        w.writeByte('\n') catch return ExportError.WriteFailed;
    }
}

/// Exports all rows of a table as SQL INSERT statements to a buffer.
pub fn exportTableSqlBuf(
    db: *Database,
    table_name: []const u8,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ExportError!void {
    const sql = std.fmt.allocPrint(allocator, "SELECT * FROM \"{s}\";", .{table_name}) catch
        return ExportError.OutOfMemory;
    defer allocator.free(sql);

    var result = db.execute(sql, allocator) catch return ExportError.QueryFailed;
    defer result.deinit();

    const w = buf.writer(allocator);
    for (result.rows) |row| {
        w.print("INSERT INTO \"{s}\" VALUES (", .{table_name}) catch return ExportError.WriteFailed;
        for (row, 0..) |val, i| {
            if (i > 0) w.writeAll(", ") catch return ExportError.WriteFailed;
            if (std.mem.eql(u8, val, "NULL")) {
                w.writeAll("NULL") catch return ExportError.WriteFailed;
            } else {
                w.writeByte('\'') catch return ExportError.WriteFailed;
                writeSqlEscaped(val, w) catch return ExportError.WriteFailed;
                w.writeByte('\'') catch return ExportError.WriteFailed;
            }
        }
        w.writeAll(");\n") catch return ExportError.WriteFailed;
    }
}

/// Exports the full database schema to a buffer.
pub fn exportSchemaBuf(
    db: *Database,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ExportError!void {
    const schema = db.getFullSchema(allocator) catch return ExportError.QueryFailed;
    defer allocator.free(schema);
    buf.appendSlice(allocator, schema) catch return ExportError.OutOfMemory;
}

/// Exports all tables to CSV files in the given directory.
pub fn exportDatabaseCsv(
    db: *Database,
    dir_path: []const u8,
    show_progress: bool,
    allocator: std.mem.Allocator,
) ExportError!void {
    const tables = db.getTables(allocator) catch return ExportError.QueryFailed;
    defer {
        for (tables) |t| allocator.free(t);
        allocator.free(tables);
    }

    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return ExportError.WriteFailed,
    };

    for (tables) |table| {
        if (show_progress) std.debug.print("Exporting: {s}\n", .{table});

        const filename = std.fmt.allocPrint(allocator, "{s}/{s}.csv", .{ dir_path, table }) catch
            return ExportError.OutOfMemory;
        defer allocator.free(filename);

        var csv_buf: std.ArrayList(u8) = .{};
        defer csv_buf.deinit(allocator);
        try exportTableCsvBuf(db, table, &csv_buf, allocator);

        const file = std.fs.createFileAbsolute(filename, .{}) catch return ExportError.WriteFailed;
        defer file.close();
        file.writeAll(csv_buf.items) catch return ExportError.WriteFailed;
    }
}

/// Writes a single CSV field, quoting if it contains commas, quotes, or newlines.
pub fn writeCsvField(value: []const u8, w: anytype) !void {
    if (std.mem.indexOfAny(u8, value, ",\"\n\r") != null) {
        try w.writeByte('"');
        for (value) |ch| {
            if (ch == '"') try w.writeByte('"');
            try w.writeByte(ch);
        }
        try w.writeByte('"');
    } else {
        try w.writeAll(value);
    }
}

/// Writes a SQL string value with single quotes escaped.
pub fn writeSqlEscaped(value: []const u8, w: anytype) !void {
    for (value) |ch| {
        if (ch == '\'') try w.writeByte('\'');
        try w.writeByte(ch);
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "export CSV produces header and rows" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
    var r1 = try db.execute("CREATE TABLE t (id INTEGER, name TEXT);", std.testing.allocator);
    r1.deinit();
    var r2 = try db.execute("INSERT INTO t VALUES (1, 'Alice'), (2, 'Bob');", std.testing.allocator);
    r2.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try exportTableCsvBuf(&db, "t", &buf, std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "id,name") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "1,Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "2,Bob") != null);
}

test "CSV value with comma is quoted" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
    var r1 = try db.execute("CREATE TABLE t (v TEXT);", std.testing.allocator);
    r1.deinit();
    var r2 = try db.execute("INSERT INTO t VALUES ('hello, world');", std.testing.allocator);
    r2.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try exportTableCsvBuf(&db, "t", &buf, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"hello, world\"") != null);
}

test "export SQL INSERT statements" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
    var r1 = try db.execute("CREATE TABLE t (id INTEGER, v TEXT);", std.testing.allocator);
    r1.deinit();
    var r2 = try db.execute("INSERT INTO t VALUES (1, 'hello');", std.testing.allocator);
    r2.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try exportTableSqlBuf(&db, "t", &buf, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "INSERT INTO \"t\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "'hello'") != null);
}

test "export SQL NULL value written as NULL keyword" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
    var r1 = try db.execute("CREATE TABLE t (a INTEGER, b TEXT);", std.testing.allocator);
    r1.deinit();
    var r2 = try db.execute("INSERT INTO t VALUES (1, NULL);", std.testing.allocator);
    r2.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try exportTableSqlBuf(&db, "t", &buf, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ", NULL)") != null);
}

test "export schema contains CREATE TABLE" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
    var r1 = try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);", std.testing.allocator);
    r1.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try exportSchemaBuf(&db, &buf, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "CREATE TABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "users") != null);
}

test "CSV field: no quoting for plain text" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try writeCsvField("plain", buf.writer(std.testing.allocator));
    try std.testing.expectEqualStrings("plain", buf.items);
}

test "CSV field: embedded quote is doubled" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try writeCsvField("say \"hi\"", buf.writer(std.testing.allocator));
    try std.testing.expectEqualStrings("\"say \"\"hi\"\"\"", buf.items);
}

test "SQL single-quote escaping" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try writeSqlEscaped("it's fine", buf.writer(std.testing.allocator));
    try std.testing.expectEqualStrings("it''s fine", buf.items);
}
