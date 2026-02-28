const std = @import("std");

pub const c = @cImport(@cInclude("sqlite3.h"));

pub const DatabaseError = error{ OpenFailed, QueryFailed, PrepareFailed, NotOpen, OutOfMemory };

pub const QueryResult = struct {
    columns: [][]const u8,
    rows: [][]?[]const u8,
    column_count: usize,
    row_count: usize,
    allocator: std.mem.Allocator,
    affected_rows: usize,

    pub fn deinit(self: *QueryResult) void {
        for (self.columns) |col| {
            self.allocator.free(col);
        }
        self.allocator.free(self.columns);

        for (self.rows) |row| {
            for (row) |cell| {
                if (cell) |val| {
                    self.allocator.free(val);
                }
            }
            self.allocator.free(row);
        }
        self.allocator.free(self.rows);
    }
};

pub const Database = struct {
    db: ?*c.sqlite3,
    path: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Database {
        return .{
            .db = null,
            .path = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Database) void {
        self.close();
        if (self.path) |p| {
            self.allocator.free(p);
            self.path = null;
        }
    }

    pub fn open(self: *Database, path: []const u8) !void {
        const c_path = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(c_path);

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        var db_handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(c_path.ptr, &db_handle);
        if (rc != c.SQLITE_OK) {
            if (db_handle) |h| {
                _ = c.sqlite3_close(h);
            }
            return DatabaseError.OpenFailed;
        }

        // Close existing connection if any
        self.close();
        if (self.path) |p| {
            self.allocator.free(p);
        }

        self.db = db_handle;
        self.path = owned_path;
    }

    pub fn close(self: *Database) void {
        if (self.db) |db_handle| {
            _ = c.sqlite3_close(db_handle);
            self.db = null;
        }
    }

    pub fn isOpen(self: *const Database) bool {
        return self.db != null;
    }

    pub fn getPath(self: *const Database) ?[]const u8 {
        return self.path;
    }

    pub fn shrink(self: *Database) !void {
        try self.execute("VACUUM");
    }

    pub fn execute(self: *Database, sql: []const u8) !void {
        if (self.db == null) return DatabaseError.NotOpen;

        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        const rc = c.sqlite3_exec(self.db.?, c_sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) {
            return DatabaseError.QueryFailed;
        }
    }

    pub fn executeQuery(self: *Database, sql: []const u8) !QueryResult {
        if (self.db == null) return DatabaseError.NotOpen;

        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var stmt: ?*c.sqlite3_stmt = null;
        const prepare_rc = c.sqlite3_prepare_v2(self.db.?, c_sql.ptr, @intCast(c_sql.len), &stmt, null);
        if (prepare_rc != c.SQLITE_OK) {
            return DatabaseError.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const col_count: usize = @intCast(c.sqlite3_column_count(stmt));

        // Allocate and populate column names
        const columns = try self.allocator.alloc([]const u8, col_count);
        var cols_initialized: usize = 0;
        errdefer {
            for (0..cols_initialized) |i| {
                self.allocator.free(columns[i]);
            }
            self.allocator.free(columns);
        }

        for (0..col_count) |i| {
            const name_ptr = c.sqlite3_column_name(stmt, @intCast(i));
            if (name_ptr) |ptr| {
                const slice = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
                columns[i] = try self.allocator.dupe(u8, slice);
            } else {
                columns[i] = try self.allocator.dupe(u8, "");
            }
            cols_initialized += 1;
        }

        // Collect rows
        var row_list: std.ArrayList([]?[]const u8) = .empty;
        errdefer {
            for (row_list.items) |row| {
                for (row) |cell| {
                    if (cell) |val| self.allocator.free(val);
                }
                self.allocator.free(row);
            }
            row_list.deinit(self.allocator);
        }

        while (true) {
            const step_rc = c.sqlite3_step(stmt);
            if (step_rc == c.SQLITE_DONE) break;
            if (step_rc != c.SQLITE_ROW) {
                return DatabaseError.QueryFailed;
            }

            const row = try self.allocator.alloc(?[]const u8, col_count);
            var cells_initialized: usize = 0;
            errdefer {
                for (0..cells_initialized) |j| {
                    if (row[j]) |val| self.allocator.free(val);
                }
                self.allocator.free(row);
            }

            for (0..col_count) |i| {
                const raw = c.sqlite3_column_text(stmt, @intCast(i));
                if (raw) |ptr| {
                    const slice = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
                    row[i] = try self.allocator.dupe(u8, slice);
                } else {
                    row[i] = null;
                }
                cells_initialized += 1;
            }

            try row_list.append(self.allocator, row);
        }

        const rows = try row_list.toOwnedSlice(self.allocator);
        const affected: usize = @intCast(c.sqlite3_changes(self.db.?));

        return QueryResult{
            .columns = columns,
            .rows = rows,
            .column_count = col_count,
            .row_count = rows.len,
            .allocator = self.allocator,
            .affected_rows = affected,
        };
    }
};

// --- Tests ---

test "open in-memory database" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    try db.open(":memory:");
    try std.testing.expect(db.isOpen());
}

test "create table" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    try db.open(":memory:");
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");
}

test "insert data" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    try db.open(":memory:");
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO test (id, name) VALUES (1, 'alice')");
    try db.execute("INSERT INTO test (id, name) VALUES (2, 'bob')");
}

test "query data" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    try db.open(":memory:");
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO test (id, name) VALUES (1, 'alice')");

    var result = try db.executeQuery("SELECT id, name FROM test");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.column_count);
    try std.testing.expectEqual(@as(usize, 1), result.row_count);
    try std.testing.expectEqualStrings("id", result.columns[0]);
    try std.testing.expectEqualStrings("name", result.columns[1]);
    try std.testing.expectEqualStrings("1", result.rows[0][0].?);
    try std.testing.expectEqualStrings("alice", result.rows[0][1].?);
}

test "multiple queries" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    try db.open(":memory:");
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)");
    try db.execute("INSERT INTO test (id, value) VALUES (1, 'a')");
    try db.execute("INSERT INTO test (id, value) VALUES (2, 'b')");

    var r1 = try db.executeQuery("SELECT * FROM test WHERE id = 1");
    defer r1.deinit();
    try std.testing.expectEqual(@as(usize, 1), r1.row_count);
    try std.testing.expectEqualStrings("a", r1.rows[0][1].?);

    var r2 = try db.executeQuery("SELECT * FROM test WHERE id = 2");
    defer r2.deinit();
    try std.testing.expectEqual(@as(usize, 1), r2.row_count);
    try std.testing.expectEqualStrings("b", r2.rows[0][1].?);
}

test "error handling bad SQL" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    try db.open(":memory:");

    const exec_result = db.execute("INVALID SQL STATEMENT");
    try std.testing.expectError(error.QueryFailed, exec_result);

    const query_result = db.executeQuery("ALSO INVALID");
    try std.testing.expectError(error.PrepareFailed, query_result);
}

test "shrink (VACUUM)" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    try db.open(":memory:");
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, data TEXT)");
    try db.execute("INSERT INTO test (id, data) VALUES (1, 'some data')");
    try db.execute("DELETE FROM test WHERE id = 1");
    try db.shrink();
}

test "open non-existent database creates file" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const path = "/tmp/zig_test_nonexistent.db";
    defer std.fs.cwd().deleteFile(path) catch {};

    try db.open(path);
    try std.testing.expect(db.isOpen());
}

test "close and reopen" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    try db.open(":memory:");
    try std.testing.expect(db.isOpen());

    db.close();
    try std.testing.expect(!db.isOpen());

    try db.open(":memory:");
    try std.testing.expect(db.isOpen());
}

test "query with multiple columns and rows" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    try db.open(":memory:");
    try db.execute(
        \\CREATE TABLE people (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT,
        \\  age INTEGER,
        \\  email TEXT
        \\)
    );
    try db.execute("INSERT INTO people VALUES (1, 'Alice', 30, 'alice@example.com')");
    try db.execute("INSERT INTO people VALUES (2, 'Bob', 25, 'bob@example.com')");
    try db.execute("INSERT INTO people VALUES (3, 'Charlie', 35, 'charlie@example.com')");

    var result = try db.executeQuery("SELECT id, name, age, email FROM people ORDER BY id");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.column_count);
    try std.testing.expectEqual(@as(usize, 3), result.row_count);

    try std.testing.expectEqualStrings("id", result.columns[0]);
    try std.testing.expectEqualStrings("name", result.columns[1]);
    try std.testing.expectEqualStrings("age", result.columns[2]);
    try std.testing.expectEqualStrings("email", result.columns[3]);

    try std.testing.expectEqualStrings("1", result.rows[0][0].?);
    try std.testing.expectEqualStrings("Alice", result.rows[0][1].?);
    try std.testing.expectEqualStrings("30", result.rows[0][2].?);
    try std.testing.expectEqualStrings("alice@example.com", result.rows[0][3].?);

    try std.testing.expectEqualStrings("2", result.rows[1][0].?);
    try std.testing.expectEqualStrings("Bob", result.rows[1][1].?);
    try std.testing.expectEqualStrings("25", result.rows[1][2].?);
    try std.testing.expectEqualStrings("bob@example.com", result.rows[1][3].?);

    try std.testing.expectEqualStrings("3", result.rows[2][0].?);
    try std.testing.expectEqualStrings("Charlie", result.rows[2][1].?);
    try std.testing.expectEqualStrings("35", result.rows[2][2].?);
    try std.testing.expectEqualStrings("charlie@example.com", result.rows[2][3].?);
}
