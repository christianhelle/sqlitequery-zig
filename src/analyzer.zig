const std = @import("std");
const database = @import("database.zig");

pub const Column = struct {
    ordinal: usize,
    name: []const u8,
    data_type: []const u8,
    not_null: bool,
    default_value: ?[]const u8,
    primary_key: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Column) void {
        self.allocator.free(self.name);
        self.allocator.free(self.data_type);
        if (self.default_value) |dv| {
            self.allocator.free(dv);
        }
    }
};

pub const Table = struct {
    name: []const u8,
    columns: []Column,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Table) void {
        for (self.columns) |*col| {
            var c = col;
            c.deinit();
        }
        self.allocator.free(self.columns);
        self.allocator.free(self.name);
    }
};

pub const DatabaseInfo = struct {
    filename: []const u8,
    size: u64,
    tables: []Table,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DatabaseInfo) void {
        for (self.tables) |*t| {
            var table = t;
            table.deinit();
        }
        self.allocator.free(self.tables);
        self.allocator.free(self.filename);
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn analyze(self: *Analyzer, db: *database.Database) !DatabaseInfo {
        const path = db.getPath() orelse return error.NotOpen;

        const filename = blk: {
            if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
                break :blk try self.allocator.dupe(u8, path[idx + 1 ..]);
            }
            break :blk try self.allocator.dupe(u8, path);
        };
        errdefer self.allocator.free(filename);

        const size: u64 = blk: {
            if (std.mem.eql(u8, path, ":memory:")) {
                break :blk 0;
            }
            const file = std.fs.cwd().openFile(path, .{}) catch break :blk 0;
            defer file.close();
            const stat = file.stat() catch break :blk 0;
            break :blk stat.size;
        };

        const tables = try self.loadTables(db);
        errdefer {
            for (tables) |*t| {
                var table = t;
                table.deinit();
            }
            self.allocator.free(tables);
        }

        try self.loadColumns(db, tables);

        return DatabaseInfo{
            .filename = filename,
            .size = size,
            .tables = tables,
            .allocator = self.allocator,
        };
    }

    fn loadTables(self: *Analyzer, db: *database.Database) ![]Table {
        var result = try db.executeQuery("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
        defer result.deinit();

        var table_list: std.ArrayListUnmanaged(Table) = .empty;
        errdefer {
            for (table_list.items) |*t| {
                var table = t;
                table.deinit();
            }
            table_list.deinit(self.allocator);
        }

        for (result.rows) |row| {
            const name = row[0] orelse continue;
            if (std.mem.eql(u8, name, "sqlite_sequence") or std.mem.eql(u8, name, "sqlite_stat1")) {
                continue;
            }
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);

            try table_list.append(self.allocator, Table{
                .name = owned_name,
                .columns = &[_]Column{},
                .allocator = self.allocator,
            });
        }

        return table_list.toOwnedSlice(self.allocator);
    }

    fn loadColumns(self: *Analyzer, db: *database.Database, tables: []Table) !void {
        for (tables) |*table| {
            const sql = try std.fmt.allocPrint(self.allocator, "PRAGMA table_info (\"{s}\")", .{table.name});
            defer self.allocator.free(sql);

            var result = db.executeQuery(sql) catch continue;
            defer result.deinit();

            var col_list: std.ArrayListUnmanaged(Column) = .empty;
            errdefer {
                for (col_list.items) |*col| {
                    var cc = col;
                    cc.deinit();
                }
                col_list.deinit(self.allocator);
            }

            for (result.rows) |row| {
                const ordinal_str = row[0] orelse "0";
                const ordinal = std.fmt.parseInt(usize, ordinal_str, 10) catch 0;
                const col_name = try self.allocator.dupe(u8, row[1] orelse "");
                errdefer self.allocator.free(col_name);
                const data_type = try self.allocator.dupe(u8, row[2] orelse "");
                errdefer self.allocator.free(data_type);
                const not_null = std.mem.eql(u8, row[3] orelse "0", "1");
                const default_value = if (row[4]) |dv|
                    try self.allocator.dupe(u8, dv)
                else
                    null;
                errdefer if (default_value) |dv| self.allocator.free(dv);
                const primary_key = std.mem.eql(u8, row[5] orelse "0", "1");

                try col_list.append(self.allocator, Column{
                    .ordinal = ordinal,
                    .name = col_name,
                    .data_type = data_type,
                    .not_null = not_null,
                    .default_value = default_value,
                    .primary_key = primary_key,
                    .allocator = self.allocator,
                });
            }

            table.columns = try col_list.toOwnedSlice(self.allocator);
        }
    }
};

// --- Tests ---

test "analyze empty database" {
    const allocator = std.testing.allocator;
    var db = database.Database.init(allocator);
    defer db.deinit();
    try db.open(":memory:");

    var a = Analyzer.init(allocator);
    var info = try a.analyze(&db);
    defer info.deinit();

    try std.testing.expectEqualStrings(":memory:", info.filename);
    try std.testing.expectEqual(@as(u64, 0), info.size);
    try std.testing.expectEqual(@as(usize, 0), info.tables.len);
}

test "analyze database with tables" {
    const allocator = std.testing.allocator;
    var db = database.Database.init(allocator);
    defer db.deinit();
    try db.open(":memory:");

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT)");
    try db.execute("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT, user_id INTEGER)");

    var a = Analyzer.init(allocator);
    var info = try a.analyze(&db);
    defer info.deinit();

    try std.testing.expectEqual(@as(usize, 2), info.tables.len);

    const posts = info.tables[0];
    try std.testing.expectEqualStrings("posts", posts.name);
    try std.testing.expectEqual(@as(usize, 3), posts.columns.len);

    const users = info.tables[1];
    try std.testing.expectEqualStrings("users", users.name);
    try std.testing.expectEqual(@as(usize, 3), users.columns.len);
}

test "analyze column details" {
    const allocator = std.testing.allocator;
    var db = database.Database.init(allocator);
    defer db.deinit();
    try db.open(":memory:");

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL DEFAULT 0.0)");

    var a = Analyzer.init(allocator);
    var info = try a.analyze(&db);
    defer info.deinit();

    try std.testing.expectEqual(@as(usize, 1), info.tables.len);

    const table = info.tables[0];
    try std.testing.expectEqualStrings("test", table.name);
    try std.testing.expectEqual(@as(usize, 3), table.columns.len);

    const id_col = table.columns[0];
    try std.testing.expectEqualStrings("id", id_col.name);
    try std.testing.expectEqualStrings("INTEGER", id_col.data_type);
    try std.testing.expect(id_col.primary_key);

    const name_col = table.columns[1];
    try std.testing.expectEqualStrings("name", name_col.name);
    try std.testing.expectEqualStrings("TEXT", name_col.data_type);
    try std.testing.expect(name_col.not_null);

    const score_col = table.columns[2];
    try std.testing.expectEqualStrings("score", score_col.name);
    try std.testing.expectEqualStrings("REAL", score_col.data_type);
    try std.testing.expect(score_col.default_value != null);
}

test "analyze skips internal tables" {
    const allocator = std.testing.allocator;
    var db = database.Database.init(allocator);
    defer db.deinit();
    try db.open(":memory:");

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('test')");

    var a = Analyzer.init(allocator);
    var info = try a.analyze(&db);
    defer info.deinit();

    for (info.tables) |table| {
        try std.testing.expect(!std.mem.eql(u8, table.name, "sqlite_sequence"));
    }
}

test "analyze file-based database" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zig_test_analyzer.db";
    defer std.fs.cwd().deleteFile(path) catch {};

    var db = database.Database.init(allocator);
    defer db.deinit();
    try db.open(path);
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)");

    var a = Analyzer.init(allocator);
    var info = try a.analyze(&db);
    defer info.deinit();

    try std.testing.expectEqualStrings("zig_test_analyzer.db", info.filename);
    try std.testing.expect(info.size > 0);
}
