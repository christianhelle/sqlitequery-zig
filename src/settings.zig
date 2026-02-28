const std = @import("std");

pub const SessionState = struct {
    sqlite_file: ?[]const u8,
    query: ?[]const u8,
    last_export_path: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SessionState) void {
        if (self.sqlite_file) |f| self.allocator.free(f);
        if (self.query) |q| self.allocator.free(q);
        if (self.last_export_path) |p| self.allocator.free(p);
        self.sqlite_file = null;
        self.query = null;
        self.last_export_path = null;
    }
};

pub const WindowState = struct {
    width: u32,
    height: u32,

    pub const default = WindowState{
        .width = 1280,
        .height = 720,
    };
};

fn getSettingsDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return std.fmt.allocPrint(allocator, "{s}/.sqlite_query_analyzer", .{home});
}

fn getSettingsPath(allocator: std.mem.Allocator) ![]const u8 {
    const dir = try getSettingsDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/settings.json", .{dir});
}

pub fn ensureSettingsDir(allocator: std.mem.Allocator) !void {
    const dir = try getSettingsDir(allocator);
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};
}

pub fn saveSession(allocator: std.mem.Allocator, state: *const SessionState) !void {
    try ensureSettingsDir(allocator);
    const path = try getSettingsPath(allocator);
    defer allocator.free(path);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    try content.appendSlice(allocator, "{\n");
    if (state.sqlite_file) |f| {
        try content.appendSlice(allocator, "  \"sqlite_file\": \"");
        try content.appendSlice(allocator, f);
        try content.appendSlice(allocator, "\",\n");
    }
    if (state.query) |q| {
        try content.appendSlice(allocator, "  \"query\": \"");
        try appendJsonEscaped(&content, allocator, q);
        try content.appendSlice(allocator, "\",\n");
    }
    if (state.last_export_path) |p| {
        try content.appendSlice(allocator, "  \"last_export_path\": \"");
        try content.appendSlice(allocator, p);
        try content.appendSlice(allocator, "\"\n");
    }
    try content.appendSlice(allocator, "}\n");

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content.items);
}

fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, ch),
        }
    }
}

pub fn loadSession(allocator: std.mem.Allocator) !SessionState {
    const path = try getSettingsPath(allocator);
    defer allocator.free(path);

    const contents = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch {
        return SessionState{
            .sqlite_file = null,
            .query = null,
            .last_export_path = null,
            .allocator = allocator,
        };
    };
    defer allocator.free(contents);

    return parseSession(allocator, contents);
}

fn parseSession(allocator: std.mem.Allocator, json_str: []const u8) !SessionState {
    var state = SessionState{
        .sqlite_file = null,
        .query = null,
        .last_export_path = null,
        .allocator = allocator,
    };
    errdefer state.deinit();

    state.sqlite_file = try extractJsonValue(allocator, json_str, "sqlite_file");
    state.query = try extractJsonValue(allocator, json_str, "query");
    state.last_export_path = try extractJsonValue(allocator, json_str, "last_export_path");

    return state;
}

fn extractJsonValue(allocator: std.mem.Allocator, json: []const u8, key: []const u8) !?[]const u8 {
    const search_key = std.fmt.allocPrint(allocator, "\"{s}\"", .{key}) catch return null;
    defer allocator.free(search_key);

    const key_pos = std.mem.indexOf(u8, json, search_key) orelse return null;
    const after_key = key_pos + search_key.len;

    var pos = after_key;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) {
        pos += 1;
    }

    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;

    var value_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer value_buf.deinit(allocator);

    while (pos < json.len and json[pos] != '"') {
        if (json[pos] == '\\' and pos + 1 < json.len) {
            pos += 1;
            switch (json[pos]) {
                'n' => try value_buf.append(allocator, '\n'),
                'r' => try value_buf.append(allocator, '\r'),
                't' => try value_buf.append(allocator, '\t'),
                '"' => try value_buf.append(allocator, '"'),
                '\\' => try value_buf.append(allocator, '\\'),
                else => try value_buf.append(allocator, json[pos]),
            }
        } else {
            try value_buf.append(allocator, json[pos]);
        }
        pos += 1;
    }

    if (value_buf.items.len == 0) {
        value_buf.deinit(allocator);
        return null;
    }

    const result = try value_buf.toOwnedSlice(allocator);
    return @as([]const u8, result);
}

pub fn saveWindowState(allocator: std.mem.Allocator, state: *const WindowState) !void {
    try ensureSettingsDir(allocator);
    const dir = try getSettingsDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/window.json", .{dir});
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var wbuf: [256]u8 = undefined;
    const content = try std.fmt.bufPrint(&wbuf, "{{\n  \"width\": {d},\n  \"height\": {d}\n}}\n", .{ state.width, state.height });
    try file.writeAll(content);
}

pub fn loadWindowState(allocator: std.mem.Allocator) WindowState {
    const dir = getSettingsDir(allocator) catch return WindowState.default;
    defer allocator.free(dir);
    const path = std.fmt.allocPrint(allocator, "{s}/window.json", .{dir}) catch return WindowState.default;
    defer allocator.free(path);

    const contents = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return WindowState.default;
    defer allocator.free(contents);

    var state = WindowState.default;
    if (extractUintFromJson(contents, "width")) |w| state.width = @intCast(w);
    if (extractUintFromJson(contents, "height")) |h| state.height = @intCast(h);
    return state;
}

fn extractUintFromJson(json: []const u8, key: []const u8) ?u64 {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    var pos = key_pos + search.len;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) {
        pos += 1;
    }
    var end = pos;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') {
        end += 1;
    }
    if (end == pos) return null;
    return std.fmt.parseInt(u64, json[pos..end], 10) catch null;
}

// --- Tests ---

test "save and load session" {
    const allocator = std.testing.allocator;

    var state = SessionState{
        .sqlite_file = try allocator.dupe(u8, "/tmp/test.db"),
        .query = try allocator.dupe(u8, "SELECT * FROM users"),
        .last_export_path = try allocator.dupe(u8, "/tmp/export"),
        .allocator = allocator,
    };
    defer state.deinit();

    try saveSession(allocator, &state);

    var loaded = try loadSession(allocator);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("/tmp/test.db", loaded.sqlite_file.?);
    try std.testing.expectEqualStrings("SELECT * FROM users", loaded.query.?);
    try std.testing.expectEqualStrings("/tmp/export", loaded.last_export_path.?);
}

test "load session with no file" {
    const allocator = std.testing.allocator;

    const dir = try getSettingsDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{dir});
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch {};

    var loaded = try loadSession(allocator);
    defer loaded.deinit();

    try std.testing.expect(loaded.sqlite_file == null);
    try std.testing.expect(loaded.query == null);
}

test "parse session with escaped characters" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "sqlite_file": "/tmp/test.db",
        \\  "query": "SELECT *\nFROM users"
        \\}
    ;

    var state = try parseSession(allocator, json);
    defer state.deinit();

    try std.testing.expectEqualStrings("/tmp/test.db", state.sqlite_file.?);
    try std.testing.expect(std.mem.indexOf(u8, state.query.?, "\n") != null);
}

test "window state defaults" {
    const state = WindowState.default;
    try std.testing.expectEqual(@as(u32, 1280), state.width);
    try std.testing.expectEqual(@as(u32, 720), state.height);
}

test "save and load window state" {
    const allocator = std.testing.allocator;

    const state = WindowState{ .width = 1920, .height = 1080 };
    try saveWindowState(allocator, &state);

    const loaded = loadWindowState(allocator);
    try std.testing.expectEqual(@as(u32, 1920), loaded.width);
    try std.testing.expectEqual(@as(u32, 1080), loaded.height);
}
