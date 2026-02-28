//! Application state: holds all mutable runtime data.

const std = @import("std");
const Database = @import("database.zig").Database;
const QueryResult = @import("database.zig").QueryResult;
const Config = @import("config.zig").Config;

pub const AppTab = enum { Query, Tables, Schema };

pub const AppState = struct {
    allocator: std.mem.Allocator,

    // Database
    db: ?Database,
    db_path_buf: [1024]u8,
    db_path_len: usize,

    // Session config
    config: Config,

    // Tab selection
    tab: AppTab,

    // Table list (owned, freed when DB is closed/reloaded)
    tables: [][]const u8,
    selected_table: i32,

    // Query editor
    query_buf: [65536]u8,
    query_len: usize,
    query_cursor: usize,
    query_scroll_y: f32,

    // Query results
    result: ?QueryResult,
    result_scroll_x: f32,
    result_scroll_y: f32,
    result_error: [512]u8,
    result_error_len: usize,
    query_time_ms: i64,

    // Table/schema view scroll
    table_scroll_y: f32,
    schema_buf: ?[]const u8,
    schema_scroll_y: f32,

    // Status bar
    status_buf: [256]u8,
    status_len: usize,
    status_is_error: bool,

    // Open-database dialog
    show_open_dialog: bool,
    open_path_buf: [1024]u8,
    open_path_len: usize,

    // Window size
    window_w: i32,
    window_h: i32,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return AppState{
            .allocator = allocator,
            .db = null,
            .db_path_buf = std.mem.zeroes([1024]u8),
            .db_path_len = 0,
            .config = Config{},
            .tab = .Query,
            .tables = &[0][]const u8{},
            .selected_table = -1,
            .query_buf = std.mem.zeroes([65536]u8),
            .query_len = 0,
            .query_cursor = 0,
            .query_scroll_y = 0,
            .result = null,
            .result_scroll_x = 0,
            .result_scroll_y = 0,
            .result_error = std.mem.zeroes([512]u8),
            .result_error_len = 0,
            .query_time_ms = 0,
            .table_scroll_y = 0,
            .schema_buf = null,
            .schema_scroll_y = 0,
            .status_buf = std.mem.zeroes([256]u8),
            .status_len = 0,
            .status_is_error = false,
            .show_open_dialog = false,
            .open_path_buf = std.mem.zeroes([1024]u8),
            .open_path_len = 0,
            .window_w = 1280,
            .window_h = 720,
        };
    }

    pub fn deinit(self: *AppState) void {
        if (self.db) |*db| {
            db.close();
            self.db = null;
        }
        self.freeTables();
        if (self.result) |*r| {
            r.deinit();
            self.result = null;
        }
        if (self.schema_buf) |s| {
            self.allocator.free(s);
            self.schema_buf = null;
        }
        self.config.deinit(self.allocator);
    }

    pub fn dbPath(self: *const AppState) []const u8 {
        return self.db_path_buf[0..self.db_path_len];
    }

    pub fn statusMessage(self: *const AppState) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn queryText(self: *const AppState) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn resultError(self: *const AppState) []const u8 {
        return self.result_error[0..self.result_error_len];
    }

    /// Opens a database at the given path, replacing any current connection.
    pub fn openDatabase(self: *AppState, path: []const u8) !void {
        if (self.db) |*db| db.close();
        self.db = null;
        self.freeTables();
        if (self.result) |*r| {
            r.deinit();
            self.result = null;
        }
        if (self.schema_buf) |s| {
            self.allocator.free(s);
            self.schema_buf = null;
        }

        const new_db = try Database.open(path, self.allocator);

        const copy_len = @min(path.len, self.db_path_buf.len);
        @memcpy(self.db_path_buf[0..copy_len], path[0..copy_len]);
        self.db_path_len = copy_len;
        self.db = new_db;

        try self.reloadTables();
        self.setStatus(false, "Opened: {s}", .{path});
    }

    pub fn reloadTables(self: *AppState) !void {
        self.freeTables();
        if (self.db) |*db| {
            self.tables = try db.getTables(self.allocator);
        }
    }

    /// Executes the current query text and stores results.
    pub fn executeQuery(self: *AppState) void {
        if (self.db == null or self.query_len == 0) return;

        if (self.result) |*r| {
            r.deinit();
            self.result = null;
        }
        self.result_error_len = 0;

        const sql = self.query_buf[0..self.query_len];
        const t0 = std.time.milliTimestamp();

        self.result = self.db.?.execute(sql, self.allocator) catch |err| {
            const errmsg = self.db.?.lastError();
            const n = @min(errmsg.len, self.result_error.len);
            @memcpy(self.result_error[0..n], errmsg[0..n]);
            self.result_error_len = n;
            self.setStatus(true, "Query error: {}", .{err});
            return;
        };
        self.result_scroll_x = 0;
        self.result_scroll_y = 0;
        self.query_time_ms = std.time.milliTimestamp() - t0;

        const rows = if (self.result) |r| r.rows.len else 0;
        self.setStatus(false, "{d} rows returned in {d}ms", .{ rows, self.query_time_ms });
    }

    /// Selects a table and fills the query editor with SELECT *.
    pub fn selectTable(self: *AppState, idx: usize) void {
        if (idx >= self.tables.len) return;
        self.selected_table = @intCast(idx);
        const t = self.tables[idx];
        const q = std.fmt.bufPrint(&self.query_buf, "SELECT * FROM \"{s}\";", .{t}) catch return;
        self.query_len = q.len;
        self.query_cursor = self.query_len;
        self.table_scroll_y = 0;
    }

    /// Loads the full schema into schema_buf.
    pub fn loadSchema(self: *AppState) void {
        if (self.schema_buf) |s| {
            self.allocator.free(s);
            self.schema_buf = null;
        }
        if (self.db) |*db| {
            self.schema_buf = db.getFullSchema(self.allocator) catch null;
        }
        self.schema_scroll_y = 0;
    }

    /// Inserts a character at the cursor position.
    pub fn insertChar(self: *AppState, ch: u8) void {
        if (self.query_len >= self.query_buf.len - 1) return;
        if (self.query_cursor < self.query_len) {
            std.mem.copyBackwards(
                u8,
                self.query_buf[self.query_cursor + 1 .. self.query_len + 1],
                self.query_buf[self.query_cursor..self.query_len],
            );
        }
        self.query_buf[self.query_cursor] = ch;
        self.query_len += 1;
        self.query_cursor += 1;
    }

    /// Deletes the character before the cursor (backspace).
    pub fn backspace(self: *AppState) void {
        if (self.query_cursor == 0) return;
        if (self.query_cursor < self.query_len) {
            std.mem.copyForwards(
                u8,
                self.query_buf[self.query_cursor - 1 .. self.query_len - 1],
                self.query_buf[self.query_cursor..self.query_len],
            );
        }
        self.query_len -= 1;
        self.query_cursor -= 1;
    }

    /// Deletes the character at the cursor (delete key).
    pub fn deleteForward(self: *AppState) void {
        if (self.query_cursor >= self.query_len) return;
        std.mem.copyForwards(
            u8,
            self.query_buf[self.query_cursor .. self.query_len - 1],
            self.query_buf[self.query_cursor + 1 .. self.query_len],
        );
        self.query_len -= 1;
    }

    /// Writes a status message.
    pub fn setStatus(self: *AppState, is_error: bool, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.status_buf, fmt, args) catch return;
        self.status_len = msg.len;
        self.status_is_error = is_error;
    }

    fn freeTables(self: *AppState) void {
        for (self.tables) |t| self.allocator.free(t);
        if (self.tables.len > 0) self.allocator.free(self.tables);
        self.tables = &[0][]const u8{};
        self.selected_table = -1;
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "AppState init has zero tables" {
    var app = AppState.init(std.testing.allocator);
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 0), app.tables.len);
    try std.testing.expectEqual(@as(i32, -1), app.selected_table);
    try std.testing.expectEqual(@as(usize, 0), app.query_len);
}

test "insertChar appends to query" {
    var app = AppState.init(std.testing.allocator);
    defer app.deinit();
    app.insertChar('S');
    app.insertChar('E');
    app.insertChar('L');
    try std.testing.expectEqualStrings("SEL", app.queryText());
    try std.testing.expectEqual(@as(usize, 3), app.query_cursor);
}

test "backspace removes last character" {
    var app = AppState.init(std.testing.allocator);
    defer app.deinit();
    app.insertChar('A');
    app.insertChar('B');
    app.backspace();
    try std.testing.expectEqualStrings("A", app.queryText());
}

test "deleteForward removes character at cursor" {
    var app = AppState.init(std.testing.allocator);
    defer app.deinit();
    app.insertChar('A');
    app.insertChar('B');
    app.insertChar('C');
    app.query_cursor = 1; // cursor between A and B
    app.deleteForward();
    try std.testing.expectEqualStrings("AC", app.queryText());
}

test "setStatus stores message" {
    var app = AppState.init(std.testing.allocator);
    defer app.deinit();
    app.setStatus(false, "Hello {s}", .{"world"});
    try std.testing.expectEqualStrings("Hello world", app.statusMessage());
    try std.testing.expect(!app.status_is_error);
}

test "setStatus error flag" {
    var app = AppState.init(std.testing.allocator);
    defer app.deinit();
    app.setStatus(true, "oops", .{});
    try std.testing.expect(app.status_is_error);
}

test "openDatabase loads tables" {
    var app = AppState.init(std.testing.allocator);
    defer app.deinit();
    try app.openDatabase(":memory:");
    // In-memory DB has no tables yet
    try std.testing.expectEqual(@as(usize, 0), app.tables.len);
    try std.testing.expect(app.db != null);
}

test "selectTable fills query buffer" {
    var app = AppState.init(std.testing.allocator);
    defer app.deinit();
    try app.openDatabase(":memory:");

    // Create a table so getTables has something
    var r = try app.db.?.execute("CREATE TABLE my_table (id INTEGER);", std.testing.allocator);
    r.deinit();
    try app.reloadTables();
    try std.testing.expectEqual(@as(usize, 1), app.tables.len);

    app.selectTable(0);
    const q = app.queryText();
    try std.testing.expect(std.mem.indexOf(u8, q, "my_table") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "SELECT") != null);
}

test "executeQuery stores result" {
    var app = AppState.init(std.testing.allocator);
    defer app.deinit();
    try app.openDatabase(":memory:");

    const sql = "SELECT 1+1 AS result;";
    @memcpy(app.query_buf[0..sql.len], sql);
    app.query_len = sql.len;
    app.executeQuery();

    try std.testing.expect(app.result != null);
    try std.testing.expectEqual(@as(usize, 1), app.result.?.rows.len);
    try std.testing.expectEqualStrings("2", app.result.?.rows[0][0]);
}
