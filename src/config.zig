//! Application session configuration: save and restore the last session.

const std = @import("std");

pub const Config = struct {
    last_db_path: []const u8 = "",
    window_width: u32 = 1280,
    window_height: u32 = 720,
    last_query: []const u8 = "",
    last_table: []const u8 = "",

    /// Loads config from the user config directory.
    /// Returns a default Config if the file is missing or unparseable.
    pub fn load(allocator: std.mem.Allocator) !Config {
        const path = try configPath(allocator);
        defer allocator.free(path);

        const data = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| switch (err) {
            error.FileNotFound => return Config{},
            else => return Config{},
        };
        defer allocator.free(data);

        const parsed = std.json.parseFromSlice(Config, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return Config{};
        defer parsed.deinit();

        return Config{
            .last_db_path = try allocator.dupe(u8, parsed.value.last_db_path),
            .window_width = parsed.value.window_width,
            .window_height = parsed.value.window_height,
            .last_query = try allocator.dupe(u8, parsed.value.last_query),
            .last_table = try allocator.dupe(u8, parsed.value.last_table),
        };
    }

    /// Saves the config to the user config directory.
    pub fn save(self: *const Config, allocator: std.mem.Allocator) !void {
        const path = try configPath(allocator);
        defer allocator.free(path);

        const dir = std.fs.path.dirname(path) orelse return;
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Serialize to memory buffer then write to file
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var ws = std.json.Stringify{
            .writer = &out.writer,
            .options = .{ .whitespace = .indent_2 },
        };
        try ws.write(self);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(out.written());
    }

    /// Frees all owned strings.
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.last_db_path.len > 0) allocator.free(self.last_db_path);
        if (self.last_query.len > 0) allocator.free(self.last_query);
        if (self.last_table.len > 0) allocator.free(self.last_table);
    }
};

/// Returns the path to the config file. Caller frees the returned string.
pub fn configPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const xdg = std.posix.getenv("XDG_CONFIG_HOME");
    const config_dir: []const u8 = if (xdg) |x| x else try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    defer if (xdg == null) allocator.free(config_dir);
    return std.fmt.allocPrint(allocator, "{s}/sqlitequery/config.json", .{config_dir});
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "default config has expected values" {
    const cfg = Config{};
    try std.testing.expectEqualStrings("", cfg.last_db_path);
    try std.testing.expectEqual(@as(u32, 1280), cfg.window_width);
    try std.testing.expectEqual(@as(u32, 720), cfg.window_height);
}

test "configPath contains sqlitequery and config.json" {
    const path = try configPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "sqlitequery") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "config.json") != null);
}

test "json serializes Config struct fields" {
    const cfg = Config{
        .last_db_path = "mydb.sqlite",
        .window_width = 800,
        .window_height = 600,
        .last_query = "SELECT 1;",
        .last_table = "t",
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var ws = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try ws.write(&cfg);

    const json = out.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "mydb.sqlite") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "800") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "SELECT 1;") != null);
}

test "save and load round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const cfg_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{tmp_path});
    defer std.testing.allocator.free(cfg_path);

    const orig = Config{
        .last_db_path = "/tmp/test.db",
        .window_width = 1920,
        .window_height = 1080,
        .last_query = "SELECT * FROM users;",
        .last_table = "users",
    };

    // Serialize to buffer
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var ws = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try ws.write(&orig);

    // Write to file
    {
        const file = try std.fs.createFileAbsolute(cfg_path, .{});
        defer file.close();
        try file.writeAll(out.written());
    }

    // Read back and parse
    const data = try std.fs.cwd().readFileAlloc(std.testing.allocator, cfg_path, 64 * 1024);
    defer std.testing.allocator.free(data);

    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("/tmp/test.db", parsed.value.last_db_path);
    try std.testing.expectEqual(@as(u32, 1920), parsed.value.window_width);
    try std.testing.expectEqual(@as(u32, 1080), parsed.value.window_height);
    try std.testing.expectEqualStrings("SELECT * FROM users;", parsed.value.last_query);
}
