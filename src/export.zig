const std = @import("std");
const database = @import("database.zig");
const analyzer = @import("analyzer.zig");

const text_types = [_][]const u8{ "TEXT", "VARCHAR", "CHAR", "CLOB", "NVARCHAR", "NCHAR" };

fn isTextType(data_type: []const u8) bool {
    for (&text_types) |text_type| {
        if (std.ascii.indexOfIgnoreCase(data_type, text_type) != null) {
            return true;
        }
    }
    return false;
}

pub fn exportSchema(allocator: std.mem.Allocator, info: *const analyzer.DatabaseInfo) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (info.tables, 0..) |table, table_idx| {
        if (table_idx > 0) try buf.appendSlice(allocator, "\n\n");

        const header = try std.fmt.allocPrint(allocator, "CREATE TABLE {s} (", .{table.name});
        defer allocator.free(header);
        try buf.appendSlice(allocator, header);

        for (table.columns, 0..) |col, col_idx| {
            const col_def = try std.fmt.allocPrint(allocator, "\n  {s} {s}", .{ col.name, col.data_type });
            defer allocator.free(col_def);
            try buf.appendSlice(allocator, col_def);
            if (col.primary_key) try buf.appendSlice(allocator, " PRIMARY KEY");
            if (col.not_null) try buf.appendSlice(allocator, " NOT NULL");
            if (col_idx < table.columns.len - 1) try buf.appendSlice(allocator, ",");
        }
        try buf.appendSlice(allocator, "\n);");
    }

    return buf.toOwnedSlice(allocator);
}

pub fn exportSchemaToFile(allocator: std.mem.Allocator, info: *const analyzer.DatabaseInfo, path: []const u8) !void {
    const schema = try exportSchema(allocator, info);
    defer allocator.free(schema);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(schema);
}

pub fn exportDataToSqlFile(
    allocator: std.mem.Allocator,
    db: *database.Database,
    info: *const analyzer.DatabaseInfo,
    path: []const u8,
) !usize {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var total_rows: usize = 0;

    for (info.tables) |table| {
        const comment = try std.fmt.allocPrint(allocator, "-- {s}\n", .{table.name});
        defer allocator.free(comment);
        try file.writeAll(comment);

        const sql = try std.fmt.allocPrint(allocator, "SELECT * FROM \"{s}\"", .{table.name});
        defer allocator.free(sql);

        var result = db.executeQuery(sql) catch continue;
        defer result.deinit();

        for (result.rows) |row| {
            var line: std.ArrayListUnmanaged(u8) = .empty;
            defer line.deinit(allocator);

            const prefix = try std.fmt.allocPrint(allocator, "INSERT INTO \"{s}\"(", .{table.name});
            defer allocator.free(prefix);
            try line.appendSlice(allocator, prefix);

            for (result.columns, 0..) |col, i| {
                if (i > 0) try line.appendSlice(allocator, ", ");
                try line.appendSlice(allocator, col);
            }
            try line.appendSlice(allocator, ") VALUES (");

            for (row, 0..) |cell, i| {
                if (i > 0) try line.appendSlice(allocator, ", ");
                if (cell) |val| {
                    const col_type = if (i < table.columns.len) table.columns[i].data_type else "";
                    if (isTextType(col_type)) {
                        try line.append(allocator, '"');
                        for (val) |ch| {
                            if (ch == '"') {
                                try line.appendSlice(allocator, "\"\"");
                            } else {
                                try line.append(allocator, ch);
                            }
                        }
                        try line.append(allocator, '"');
                    } else {
                        try line.appendSlice(allocator, val);
                    }
                } else {
                    try line.appendSlice(allocator, "NULL");
                }
            }
            try line.appendSlice(allocator, ");\n");
            try file.writeAll(line.items);
            total_rows += 1;
        }

        try file.writeAll("\n");
    }

    return total_rows;
}

pub fn exportDataToCsvFile(
    allocator: std.mem.Allocator,
    db: *database.Database,
    table: *const analyzer.Table,
    output_folder: []const u8,
    delimiter: []const u8,
) !usize {
    const filename = try std.fmt.allocPrint(allocator, "{s}/{s}.csv", .{ output_folder, table.name });
    defer allocator.free(filename);

    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    // Write header
    {
        var header: std.ArrayListUnmanaged(u8) = .empty;
        defer header.deinit(allocator);
        for (table.columns, 0..) |col, i| {
            if (i > 0) try header.appendSlice(allocator, delimiter);
            try header.appendSlice(allocator, col.name);
        }
        try header.append(allocator, '\n');
        try file.writeAll(header.items);
    }

    const sql = try std.fmt.allocPrint(allocator, "SELECT * FROM \"{s}\"", .{table.name});
    defer allocator.free(sql);

    var result = db.executeQuery(sql) catch return 0;
    defer result.deinit();

    var row_count: usize = 0;
    for (result.rows) |row| {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(allocator);

        for (row, 0..) |cell, i| {
            if (i > 0) try line.appendSlice(allocator, delimiter);
            if (cell) |val| {
                if (std.mem.indexOfScalar(u8, val, ',') != null or
                    std.mem.indexOfScalar(u8, val, '"') != null or
                    std.mem.indexOfScalar(u8, val, '\n') != null)
                {
                    try line.append(allocator, '"');
                    for (val) |ch| {
                        if (ch == '"') {
                            try line.appendSlice(allocator, "\"\"");
                        } else {
                            try line.append(allocator, ch);
                        }
                    }
                    try line.append(allocator, '"');
                } else {
                    try line.appendSlice(allocator, val);
                }
            }
        }
        try line.append(allocator, '\n');
        try file.writeAll(line.items);
        row_count += 1;
    }

    return row_count;
}

pub fn exportAllToCsv(
    allocator: std.mem.Allocator,
    db: *database.Database,
    info: *const analyzer.DatabaseInfo,
    output_folder: []const u8,
    delimiter: []const u8,
    show_progress: bool,
) !usize {
    var total_rows: usize = 0;

    for (info.tables) |*table| {
        const rows = try exportDataToCsvFile(allocator, db, table, output_folder, delimiter);
        total_rows += rows;
        if (show_progress) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Exported {s}: {d} row(s)\n", .{ table.name, rows }) catch continue;
            const f = std.fs.File{ .handle = std.posix.STDERR_FILENO };
            f.writeAll(msg) catch {};
        }
    }

    return total_rows;
}

// --- Tests ---

test "export schema" {
    const alloc = std.testing.allocator;
    var db = database.Database.init(alloc);
    defer db.deinit();
    try db.open(":memory:");

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT)");

    var a = analyzer.Analyzer.init(alloc);
    var info = try a.analyze(&db);
    defer info.deinit();

    const schema = try exportSchema(alloc, &info);
    defer alloc.free(schema);

    try std.testing.expect(std.mem.indexOf(u8, schema, "CREATE TABLE users") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "id INTEGER PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "name TEXT NOT NULL") != null);
}

test "export schema to file" {
    const alloc = std.testing.allocator;
    const path = "/tmp/zig_test_schema.sql";
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = database.Database.init(alloc);
    defer db.deinit();
    try db.open(":memory:");
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)");

    var a = analyzer.Analyzer.init(alloc);
    var info = try a.analyze(&db);
    defer info.deinit();

    try exportSchemaToFile(alloc, &info, path);

    const contents = try std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "CREATE TABLE test") != null);
}

test "export data to SQL file" {
    const alloc = std.testing.allocator;
    const path = "/tmp/zig_test_data.sql";
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = database.Database.init(alloc);
    defer db.deinit();
    try db.open(":memory:");
    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users VALUES (1, 'Alice')");
    try db.execute("INSERT INTO users VALUES (2, 'Bob')");

    var a = analyzer.Analyzer.init(alloc);
    var info = try a.analyze(&db);
    defer info.deinit();

    const rows = try exportDataToSqlFile(alloc, &db, &info, path);
    try std.testing.expectEqual(@as(usize, 2), rows);

    const contents = try std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "INSERT INTO") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Alice") != null);
}

test "export data to CSV" {
    const alloc = std.testing.allocator;
    const dir = "/tmp/zig_test_csv";
    std.fs.cwd().makeDir(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    var db = database.Database.init(alloc);
    defer db.deinit();
    try db.open(":memory:");
    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users VALUES (1, 'Alice')");
    try db.execute("INSERT INTO users VALUES (2, 'Bob')");

    var a = analyzer.Analyzer.init(alloc);
    var info = try a.analyze(&db);
    defer info.deinit();

    const rows = try exportDataToCsvFile(alloc, &db, &info.tables[0], dir, ",");
    try std.testing.expectEqual(@as(usize, 2), rows);

    const csv_path = dir ++ "/users.csv";
    const contents = try std.fs.cwd().readFileAlloc(alloc, csv_path, 1024 * 1024);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "id,name") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Alice") != null);
}

test "is text type" {
    try std.testing.expect(isTextType("TEXT"));
    try std.testing.expect(isTextType("VARCHAR(255)"));
    try std.testing.expect(isTextType("NVARCHAR"));
    try std.testing.expect(!isTextType("INTEGER"));
    try std.testing.expect(!isTextType("REAL"));
    try std.testing.expect(!isTextType("BLOB"));
}
