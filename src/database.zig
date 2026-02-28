//! SQLite database wrapper using C FFI.
//! Provides safe Zig abstractions over the SQLite C API.

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const DatabaseError = error{
    OpenFailed,
    PrepareFailed,
    BindFailed,
    OutOfMemory,
};

/// Holds query results: column names and row data.
/// All strings are owned by the arena allocator and freed on deinit.
pub const QueryResult = struct {
    arena: std.heap.ArenaAllocator,
    columns: [][]const u8,
    rows: [][][]const u8,
    affected_rows: i64,

    pub fn init(child_allocator: std.mem.Allocator) QueryResult {
        return .{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
            .columns = &[0][]const u8{},
            .rows = &[0][][]const u8{},
            .affected_rows = 0,
        };
    }

    pub fn deinit(self: *QueryResult) void {
        self.arena.deinit();
    }
};

/// Wraps a SQLite database connection.
pub const Database = struct {
    handle: *c.sqlite3,
    path: []const u8,
    allocator: std.mem.Allocator,

    /// Opens a SQLite database at the given path.
    /// Use ":memory:" for an in-memory database.
    pub fn open(path: []const u8, allocator: std.mem.Allocator) DatabaseError!Database {
        const path_z = allocator.dupeZ(u8, path) catch return DatabaseError.OutOfMemory;
        defer allocator.free(path_z);

        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path_z.ptr, &handle);
        if (rc != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return DatabaseError.OpenFailed;
        }

        const owned_path = allocator.dupe(u8, path) catch return DatabaseError.OutOfMemory;
        return Database{
            .handle = handle.?,
            .path = owned_path,
            .allocator = allocator,
        };
    }

    /// Closes the database connection and frees resources.
    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.handle);
        self.allocator.free(self.path);
    }

    /// Returns the last SQLite error message.
    pub fn lastError(self: *const Database) []const u8 {
        return cStrToSlice(c.sqlite3_errmsg(self.handle));
    }

    /// Executes a SQL statement and returns the result.
    /// The caller must call deinit() on the returned QueryResult.
    pub fn execute(self: *Database, sql: []const u8, allocator: std.mem.Allocator) DatabaseError!QueryResult {
        const sql_z = allocator.dupeZ(u8, sql) catch return DatabaseError.OutOfMemory;
        defer allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            return DatabaseError.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var result = QueryResult.init(allocator);
        errdefer result.deinit();

        const arena = result.arena.allocator();
        const col_count = c.sqlite3_column_count(stmt.?);

        // Column names
        var columns: std.ArrayList([]const u8) = .{};
        var i: i32 = 0;
        while (i < col_count) : (i += 1) {
            const name_z = c.sqlite3_column_name(stmt.?, i);
            const name = arena.dupe(u8, cStrToSlice(name_z)) catch return DatabaseError.OutOfMemory;
            columns.append(arena, name) catch return DatabaseError.OutOfMemory;
        }
        result.columns = columns.toOwnedSlice(arena) catch return DatabaseError.OutOfMemory;

        // Rows
        var rows: std.ArrayList([][]const u8) = .{};
        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            var row: std.ArrayList([]const u8) = .{};
            i = 0;
            while (i < col_count) : (i += 1) {
                const val = if (c.sqlite3_column_type(stmt.?, i) == c.SQLITE_NULL)
                    "NULL"
                else
                    cStrToSlice(c.sqlite3_column_text(stmt.?, i));
                const owned = arena.dupe(u8, val) catch return DatabaseError.OutOfMemory;
                row.append(arena, owned) catch return DatabaseError.OutOfMemory;
            }
            rows.append(arena, row.toOwnedSlice(arena) catch return DatabaseError.OutOfMemory) catch
                return DatabaseError.OutOfMemory;
        }
        result.rows = rows.toOwnedSlice(arena) catch return DatabaseError.OutOfMemory;
        result.affected_rows = @intCast(c.sqlite3_changes(self.handle));

        return result;
    }

    /// Returns a list of table names. Caller frees the returned slice and its strings.
    pub fn getTables(self: *Database, allocator: std.mem.Allocator) DatabaseError![][]const u8 {
        var result = try self.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;",
            allocator,
        );
        defer result.deinit();

        var tables: std.ArrayList([]const u8) = .{};
        for (result.rows) |row| {
            if (row.len > 0) {
                const name = allocator.dupe(u8, row[0]) catch return DatabaseError.OutOfMemory;
                tables.append(allocator, name) catch return DatabaseError.OutOfMemory;
            }
        }
        return tables.toOwnedSlice(allocator) catch return DatabaseError.OutOfMemory;
    }

    /// Returns the CREATE TABLE SQL for the given table. Caller owns the string.
    pub fn getTableSchema(self: *Database, table_name: []const u8, allocator: std.mem.Allocator) DatabaseError![]const u8 {
        const sql_z = allocator.dupeZ(u8, "SELECT sql FROM sqlite_master WHERE type='table' AND name=?1;") catch
            return DatabaseError.OutOfMemory;
        defer allocator.free(sql_z);
        const name_z = allocator.dupeZ(u8, table_name) catch return DatabaseError.OutOfMemory;
        defer allocator.free(name_z);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DatabaseError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt.?, 1, name_z.ptr, @intCast(name_z.len), null) != c.SQLITE_OK)
            return DatabaseError.BindFailed;

        if (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            return allocator.dupe(u8, cStrToSlice(c.sqlite3_column_text(stmt.?, 0))) catch
                return DatabaseError.OutOfMemory;
        }
        return allocator.dupe(u8, "-- No schema found") catch return DatabaseError.OutOfMemory;
    }

    /// Returns the full database schema as CREATE TABLE statements. Caller owns the string.
    pub fn getFullSchema(self: *Database, allocator: std.mem.Allocator) DatabaseError![]const u8 {
        var result = try self.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND sql IS NOT NULL ORDER BY name;",
            allocator,
        );
        defer result.deinit();

        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(allocator);
        for (result.rows) |row| {
            if (row.len > 0) {
                buf.appendSlice(allocator, row[0]) catch return DatabaseError.OutOfMemory;
                buf.appendSlice(allocator, ";\n\n") catch return DatabaseError.OutOfMemory;
            }
        }
        return buf.toOwnedSlice(allocator) catch return DatabaseError.OutOfMemory;
    }

    /// Returns PRAGMA table_info for the table. Caller calls deinit on result.
    pub fn getColumns(self: *Database, table_name: []const u8, allocator: std.mem.Allocator) DatabaseError!QueryResult {
        const sql = std.fmt.allocPrint(allocator, "PRAGMA table_info(\"{s}\");", .{table_name}) catch
            return DatabaseError.OutOfMemory;
        defer allocator.free(sql);
        return self.execute(sql, allocator);
    }
};

/// Converts a null-terminated C string pointer to a Zig slice.
pub fn cStrToSlice(ptr: [*c]const u8) []const u8 {
    if (ptr == null) return "";
    var i: usize = 0;
    while (ptr[i] != 0) : (i += 1) {}
    return ptr[0..i];
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "open in-memory database" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
}

test "create table and insert" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
    var r1 = try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);", std.testing.allocator);
    r1.deinit();
    var r2 = try db.execute("INSERT INTO users VALUES (1, 'Alice');", std.testing.allocator);
    defer r2.deinit();
    try std.testing.expectEqual(@as(i64, 1), r2.affected_rows);
}

test "query returns rows and columns" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
    var r1 = try db.execute("CREATE TABLE items (id INTEGER, val TEXT);", std.testing.allocator);
    r1.deinit();
    var r2 = try db.execute("INSERT INTO items VALUES (1, 'foo'), (2, 'bar');", std.testing.allocator);
    r2.deinit();
    var result = try db.execute("SELECT * FROM items ORDER BY id;", std.testing.allocator);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.columns.len);
    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqualStrings("id", result.columns[0]);
    try std.testing.expectEqualStrings("val", result.columns[1]);
    try std.testing.expectEqualStrings("1", result.rows[0][0]);
    try std.testing.expectEqualStrings("foo", result.rows[0][1]);
    try std.testing.expectEqualStrings("bar", result.rows[1][1]);
}

test "getTables returns sorted table names" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
    var r1 = try db.execute("CREATE TABLE beta (x INTEGER);", std.testing.allocator);
    r1.deinit();
    var r2 = try db.execute("CREATE TABLE alpha (y TEXT);", std.testing.allocator);
    r2.deinit();
    const tables = try db.getTables(std.testing.allocator);
    defer {
        for (tables) |t| std.testing.allocator.free(t);
        std.testing.allocator.free(tables);
    }
    try std.testing.expectEqual(@as(usize, 2), tables.len);
    try std.testing.expectEqualStrings("alpha", tables[0]);
    try std.testing.expectEqualStrings("beta", tables[1]);
}

test "getTableSchema contains CREATE TABLE" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
    var r1 = try db.execute("CREATE TABLE t1 (id INTEGER PRIMARY KEY);", std.testing.allocator);
    r1.deinit();
    const schema = try db.getTableSchema("t1", std.testing.allocator);
    defer std.testing.allocator.free(schema);
    try std.testing.expect(std.mem.indexOf(u8, schema, "CREATE TABLE") != null);
}

test "NULL column values become the string NULL" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
    var r1 = try db.execute("CREATE TABLE t (a INTEGER, b TEXT);", std.testing.allocator);
    r1.deinit();
    var r2 = try db.execute("INSERT INTO t VALUES (1, NULL);", std.testing.allocator);
    r2.deinit();
    var result = try db.execute("SELECT * FROM t;", std.testing.allocator);
    defer result.deinit();
    try std.testing.expectEqualStrings("NULL", result.rows[0][1]);
}

test "cStrToSlice handles null pointer" {
    try std.testing.expectEqualStrings("", cStrToSlice(null));
}

test "multiple statements via execute" {
    var db = try Database.open(":memory:", std.testing.allocator);
    defer db.close();
    var r1 = try db.execute("CREATE TABLE t (v INTEGER);", std.testing.allocator);
    r1.deinit();
    // Insert multiple rows
    var r2 = try db.execute("INSERT INTO t VALUES (10); INSERT INTO t VALUES (20);", std.testing.allocator);
    r2.deinit();
    var r3 = try db.execute("SELECT COUNT(*) FROM t;", std.testing.allocator);
    defer r3.deinit();
    try std.testing.expect(r3.rows.len > 0);
}
