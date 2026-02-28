const std = @import("std");
const database = @import("database.zig");
const analyzer = @import("analyzer.zig");
const export_mod = @import("export.zig");
const settings = @import("settings.zig");

const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("raygui.h");
});

const APP_TITLE = "SQLite Query Analyzer";
const MAX_QUERY_LEN = 4096;
const FONT_SIZE = 16;
const HEADER_HEIGHT = 30;
const STATUS_HEIGHT = 25;
const TREE_WIDTH_DEFAULT = 250;
const MENU_HEIGHT = 30;

const AppState = struct {
    allocator: std.mem.Allocator,
    db: database.Database,
    db_analyzer: analyzer.Analyzer,
    db_info: ?analyzer.DatabaseInfo,
    query_result: ?database.QueryResult,
    query_buf: [MAX_QUERY_LEN]u8,
    query_len: usize,
    status_message: [512]u8,
    status_len: usize,
    tree_scroll: c_int,
    result_scroll_y: c_int,
    result_scroll_x: c_int,
    selected_table: ?[]const u8,
    tree_width: f32,
    show_file_dialog: bool,
    query_edit_mode: bool,
    dark_mode: bool,
    file_path_buf: [1024]u8,
    file_path_len: usize,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return AppState{
            .allocator = allocator,
            .db = database.Database.init(allocator),
            .db_analyzer = analyzer.Analyzer.init(allocator),
            .db_info = null,
            .query_result = null,
            .query_buf = [_]u8{0} ** MAX_QUERY_LEN,
            .query_len = 0,
            .status_message = [_]u8{0} ** 512,
            .status_len = 0,
            .tree_scroll = 0,
            .result_scroll_y = 0,
            .result_scroll_x = 0,
            .selected_table = null,
            .tree_width = TREE_WIDTH_DEFAULT,
            .show_file_dialog = false,
            .query_edit_mode = false,
            .dark_mode = true,
            .file_path_buf = [_]u8{0} ** 1024,
            .file_path_len = 0,
        };
    }

    pub fn deinit(self: *AppState) void {
        if (self.query_result) |*qr| qr.deinit();
        if (self.db_info) |*info| info.deinit();
        self.db.deinit();
    }

    pub fn setStatus(self: *AppState, msg: []const u8) void {
        const len = @min(msg.len, self.status_message.len - 1);
        @memcpy(self.status_message[0..len], msg[0..len]);
        self.status_message[len] = 0;
        self.status_len = len;
    }

    pub fn openDatabase(self: *AppState, path: []const u8) void {
        if (self.query_result) |*qr| {
            qr.deinit();
            self.query_result = null;
        }
        if (self.db_info) |*info| {
            info.deinit();
            self.db_info = null;
        }

        self.db.open(path) catch {
            self.setStatus("Failed to open database");
            return;
        };

        self.analyzeDatabase();

        var state = settings.SessionState{
            .sqlite_file = self.db.getPath(),
            .query = null,
            .last_export_path = null,
            .allocator = self.allocator,
        };
        settings.saveSession(self.allocator, &state) catch {};
        // Don't deinit state - the strings are borrowed from db

        self.setStatus("Database opened successfully");
    }

    pub fn analyzeDatabase(self: *AppState) void {
        if (self.db_info) |*info| {
            info.deinit();
            self.db_info = null;
        }

        self.db_info = self.db_analyzer.analyze(&self.db) catch {
            self.setStatus("Failed to analyze database");
            return;
        };
    }

    pub fn executeQuery(self: *AppState) void {
        if (self.query_result) |*qr| {
            qr.deinit();
            self.query_result = null;
        }

        const query = self.query_buf[0..self.query_len];
        if (query.len == 0) {
            self.setStatus("No query to execute");
            return;
        }

        var timer = std.time.Timer.start() catch {
            self.setStatus("Timer error");
            return;
        };

        self.query_result = self.db.executeQuery(query) catch {
            self.db.execute(query) catch {
                self.setStatus("Query execution failed");
                return;
            };
            self.analyzeDatabase();

            const elapsed = timer.read();
            const ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Statement executed in {d:.2}ms", .{ms}) catch "Done";
            self.setStatus(msg);
            return;
        };

        const elapsed = timer.read();
        const ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
        const row_count = if (self.query_result) |qr| qr.row_count else 0;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Query returned {d} row(s) in {d:.2}ms", .{ row_count, ms }) catch "Done";
        self.setStatus(msg);
    }
};

pub fn runGui(allocator: std.mem.Allocator, initial_db: ?[]const u8) !void {
    const win_state = settings.loadWindowState(allocator);

    c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE | c.FLAG_VSYNC_HINT);
    c.InitWindow(@intCast(win_state.width), @intCast(win_state.height), APP_TITLE);
    defer c.CloseWindow();

    c.SetTargetFPS(60);

    var state = AppState.init(allocator);
    defer state.deinit();

    if (initial_db) |path| {
        state.openDatabase(path);
    } else {
        var session = settings.loadSession(allocator) catch settings.SessionState{
            .sqlite_file = null,
            .query = null,
            .last_export_path = null,
            .allocator = allocator,
        };
        defer session.deinit();

        if (session.sqlite_file) |path| {
            state.openDatabase(path);
        }
        if (session.query) |query| {
            const len = @min(query.len, MAX_QUERY_LEN);
            @memcpy(state.query_buf[0..len], query[0..len]);
            state.query_len = len;
        }
    }

    // Apply dark mode theme
    applyTheme(state.dark_mode);

    while (!c.WindowShouldClose()) {
        handleInput(&state);

        c.BeginDrawing();
        if (state.dark_mode) {
            c.ClearBackground(c.Color{ .r = 30, .g = 30, .b = 30, .a = 255 });
        } else {
            c.ClearBackground(c.RAYWHITE);
        }

        drawMenuBar(&state);
        drawTreePanel(&state);
        drawQueryPanel(&state);
        drawResultsPanel(&state);
        drawStatusBar(&state);

        if (state.show_file_dialog) {
            drawFileDialog(&state);
        }

        c.EndDrawing();
    }

    // Save state on exit
    const w: u32 = @intCast(c.GetScreenWidth());
    const h: u32 = @intCast(c.GetScreenHeight());
    const wstate = settings.WindowState{ .width = w, .height = h };
    settings.saveWindowState(allocator, &wstate) catch {};

    var session = settings.SessionState{
        .sqlite_file = state.db.getPath(),
        .query = if (state.query_len > 0) state.query_buf[0..state.query_len] else null,
        .last_export_path = null,
        .allocator = allocator,
    };
    settings.saveSession(allocator, &session) catch {};
}

fn applyTheme(dark: bool) void {
    if (dark) {
        c.GuiSetStyle(c.DEFAULT, c.BACKGROUND_COLOR, colorToInt(c.Color{ .r = 40, .g = 40, .b = 40, .a = 255 }));
        c.GuiSetStyle(c.DEFAULT, c.TEXT_COLOR_NORMAL, colorToInt(c.Color{ .r = 220, .g = 220, .b = 220, .a = 255 }));
        c.GuiSetStyle(c.DEFAULT, c.BASE_COLOR_NORMAL, colorToInt(c.Color{ .r = 50, .g = 50, .b = 50, .a = 255 }));
        c.GuiSetStyle(c.DEFAULT, c.BORDER_COLOR_NORMAL, colorToInt(c.Color{ .r = 80, .g = 80, .b = 80, .a = 255 }));
    } else {
        c.GuiSetStyle(c.DEFAULT, c.BACKGROUND_COLOR, colorToInt(c.RAYWHITE));
        c.GuiSetStyle(c.DEFAULT, c.TEXT_COLOR_NORMAL, colorToInt(c.DARKGRAY));
        c.GuiSetStyle(c.DEFAULT, c.BASE_COLOR_NORMAL, colorToInt(c.Color{ .r = 245, .g = 245, .b = 245, .a = 255 }));
        c.GuiSetStyle(c.DEFAULT, c.BORDER_COLOR_NORMAL, colorToInt(c.LIGHTGRAY));
    }
}

fn colorToInt(color: c.Color) c_int {
    return @bitCast(@as(u32, @as(u32, color.r) << 24 | @as(u32, color.g) << 16 | @as(u32, color.b) << 8 | @as(u32, color.a)));
}

fn handleInput(state: *AppState) void {
    // Ctrl+E - Focus query editor
    if (c.IsKeyDown(c.KEY_LEFT_CONTROL) and c.IsKeyPressed(c.KEY_E)) {
        state.query_edit_mode = true;
    }

    // Ctrl+Enter or F5 - Execute query
    if ((c.IsKeyDown(c.KEY_LEFT_CONTROL) and c.IsKeyPressed(c.KEY_ENTER)) or
        c.IsKeyPressed(c.KEY_F5))
    {
        state.executeQuery();
    }

    // Ctrl+O - Open file
    if (c.IsKeyDown(c.KEY_LEFT_CONTROL) and c.IsKeyPressed(c.KEY_O)) {
        state.show_file_dialog = !state.show_file_dialog;
    }

    // Ctrl+N - New database
    if (c.IsKeyDown(c.KEY_LEFT_CONTROL) and c.IsKeyPressed(c.KEY_N)) {
        state.show_file_dialog = true;
    }

    // Ctrl+Q - Quit
    if (c.IsKeyDown(c.KEY_LEFT_CONTROL) and c.IsKeyPressed(c.KEY_Q)) {
        c.CloseWindow();
    }

    // Ctrl+D - Toggle dark mode
    if (c.IsKeyDown(c.KEY_LEFT_CONTROL) and c.IsKeyPressed(c.KEY_D)) {
        state.dark_mode = !state.dark_mode;
        applyTheme(state.dark_mode);
    }
}

fn drawMenuBar(state: *AppState) void {
    const screen_w: f32 = @floatFromInt(c.GetScreenWidth());
    const bg = if (state.dark_mode) c.Color{ .r = 45, .g = 45, .b = 45, .a = 255 } else c.Color{ .r = 230, .g = 230, .b = 230, .a = 255 };

    c.DrawRectangleRec(.{ .x = 0, .y = 0, .width = screen_w, .height = MENU_HEIGHT }, bg);

    var x_offset: f32 = 5;

    if (c.GuiButton(.{ .x = x_offset, .y = 2, .width = 60, .height = MENU_HEIGHT - 4 }, "Open") != 0) {
        state.show_file_dialog = !state.show_file_dialog;
    }
    x_offset += 65;

    if (c.GuiButton(.{ .x = x_offset, .y = 2, .width = 70, .height = MENU_HEIGHT - 4 }, "Execute") != 0) {
        state.executeQuery();
    }
    x_offset += 75;

    if (c.GuiButton(.{ .x = x_offset, .y = 2, .width = 65, .height = MENU_HEIGHT - 4 }, "Shrink") != 0) {
        state.db.shrink() catch {
            state.setStatus("VACUUM failed");
            return;
        };
        state.setStatus("Database compacted (VACUUM)");
    }
    x_offset += 70;

    if (c.GuiButton(.{ .x = x_offset, .y = 2, .width = 75, .height = MENU_HEIGHT - 4 }, "Refresh") != 0) {
        state.analyzeDatabase();
        state.setStatus("Database refreshed");
    }
    x_offset += 80;

    const theme_label = if (state.dark_mode) "Light" else "Dark";
    if (c.GuiButton(.{ .x = x_offset, .y = 2, .width = 55, .height = MENU_HEIGHT - 4 }, theme_label) != 0) {
        state.dark_mode = !state.dark_mode;
        applyTheme(state.dark_mode);
    }
}

fn drawTreePanel(state: *AppState) void {
    const screen_h: f32 = @floatFromInt(c.GetScreenHeight());
    const panel_h = screen_h - MENU_HEIGHT - STATUS_HEIGHT;

    const border = if (state.dark_mode) c.Color{ .r = 60, .g = 60, .b = 60, .a = 255 } else c.LIGHTGRAY;
    c.DrawRectangleLinesEx(.{ .x = 0, .y = MENU_HEIGHT, .width = state.tree_width, .height = panel_h }, 1, border);

    const text_color = if (state.dark_mode) c.Color{ .r = 200, .g = 200, .b = 200, .a = 255 } else c.DARKGRAY;
    const header_color = if (state.dark_mode) c.Color{ .r = 100, .g = 180, .b = 255, .a = 255 } else c.BLUE;

    var y: f32 = MENU_HEIGHT + 5;

    const info = state.db_info orelse {
        c.DrawTextEx(c.GetFontDefault(), "No database loaded", .{ .x = 10, .y = y }, FONT_SIZE, 1, text_color);
        return;
    };

    // Database Info section
    c.DrawTextEx(c.GetFontDefault(), "Database Info", .{ .x = 10, .y = y }, FONT_SIZE, 1, header_color);
    y += FONT_SIZE + 4;

    var buf: [256]u8 = undefined;
    const filename_text = std.fmt.bufPrintZ(&buf, "  {s}", .{info.filename}) catch "  <unknown>";
    c.DrawTextEx(c.GetFontDefault(), filename_text, .{ .x = 10, .y = y }, FONT_SIZE - 2, 1, text_color);
    y += FONT_SIZE;

    const size_text = formatFileSize(&buf, info.size);
    c.DrawTextEx(c.GetFontDefault(), size_text, .{ .x = 10, .y = y }, FONT_SIZE - 2, 1, text_color);
    y += FONT_SIZE + 8;

    // Tables section
    c.DrawTextEx(c.GetFontDefault(), "Tables", .{ .x = 10, .y = y }, FONT_SIZE, 1, header_color);
    y += FONT_SIZE + 4;

    for (info.tables) |table| {
        if (y > MENU_HEIGHT + panel_h - FONT_SIZE) break;

        const table_text = std.fmt.bufPrintZ(&buf, "  {s}", .{table.name}) catch "  <table>";
        const is_selected = if (state.selected_table) |sel| std.mem.eql(u8, sel, table.name) else false;

        if (is_selected) {
            const sel_color = if (state.dark_mode) c.Color{ .r = 60, .g = 60, .b = 80, .a = 255 } else c.Color{ .r = 200, .g = 220, .b = 255, .a = 255 };
            c.DrawRectangleRec(.{ .x = 5, .y = y - 1, .width = state.tree_width - 10, .height = FONT_SIZE + 2 }, sel_color);
        }

        c.DrawTextEx(c.GetFontDefault(), table_text, .{ .x = 10, .y = y }, FONT_SIZE - 2, 1, text_color);

        // Click detection for table selection
        const mouse = c.GetMousePosition();
        if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            if (mouse.x >= 5 and mouse.x <= state.tree_width - 5 and
                mouse.y >= y - 1 and mouse.y <= y + FONT_SIZE + 1)
            {
                state.selected_table = table.name;
                loadTableData(state, table.name);
            }
        }

        y += FONT_SIZE + 2;

        // Show columns for selected table
        if (is_selected) {
            for (table.columns) |col| {
                if (y > MENU_HEIGHT + panel_h - FONT_SIZE) break;
                const col_text = std.fmt.bufPrintZ(&buf, "    {s} ({s})", .{ col.name, col.data_type }) catch "    <col>";
                const col_color = if (state.dark_mode) c.Color{ .r = 150, .g = 150, .b = 150, .a = 255 } else c.GRAY;
                c.DrawTextEx(c.GetFontDefault(), col_text, .{ .x = 10, .y = y }, FONT_SIZE - 4, 1, col_color);
                y += FONT_SIZE - 2;
            }
        }
    }
}

fn drawQueryPanel(state: *AppState) void {
    const screen_w: f32 = @floatFromInt(c.GetScreenWidth());
    const screen_h: f32 = @floatFromInt(c.GetScreenHeight());
    const panel_x = state.tree_width + 2;
    const panel_w = screen_w - panel_x;
    const panel_h = (screen_h - MENU_HEIGHT - STATUS_HEIGHT) * 0.3;

    const bg = if (state.dark_mode) c.Color{ .r = 35, .g = 35, .b = 40, .a = 255 } else c.Color{ .r = 255, .g = 255, .b = 245, .a = 255 };
    c.DrawRectangleRec(.{ .x = panel_x, .y = MENU_HEIGHT, .width = panel_w, .height = panel_h }, bg);

    const border = if (state.dark_mode) c.Color{ .r = 60, .g = 60, .b = 60, .a = 255 } else c.LIGHTGRAY;
    c.DrawRectangleLinesEx(.{ .x = panel_x, .y = MENU_HEIGHT, .width = panel_w, .height = panel_h }, 1, border);

    // Query label
    const label_color = if (state.dark_mode) c.Color{ .r = 150, .g = 150, .b = 150, .a = 255 } else c.GRAY;
    c.DrawTextEx(c.GetFontDefault(), "SQL Query (F5 or Ctrl+Enter to execute)", .{ .x = panel_x + 5, .y = MENU_HEIGHT + 2 }, FONT_SIZE - 4, 1, label_color);

    // Text editing area
    const edit_rect = c.Rectangle{
        .x = panel_x + 5,
        .y = MENU_HEIGHT + FONT_SIZE,
        .width = panel_w - 10,
        .height = panel_h - FONT_SIZE - 5,
    };

    // Use raygui text box
    _ = c.GuiTextBox(edit_rect, &state.query_buf, MAX_QUERY_LEN, state.query_edit_mode);

    // Update query length
    state.query_len = std.mem.indexOfScalar(u8, &state.query_buf, 0) orelse MAX_QUERY_LEN;

    // Click to focus/unfocus
    const mouse = c.GetMousePosition();
    if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
        state.query_edit_mode = c.CheckCollisionPointRec(mouse, edit_rect);
    }
}

fn drawResultsPanel(state: *AppState) void {
    const screen_w: f32 = @floatFromInt(c.GetScreenWidth());
    const screen_h: f32 = @floatFromInt(c.GetScreenHeight());
    const panel_x = state.tree_width + 2;
    const panel_w = screen_w - panel_x;
    const query_panel_h = (screen_h - MENU_HEIGHT - STATUS_HEIGHT) * 0.3;
    const panel_y = MENU_HEIGHT + query_panel_h + 2;
    const panel_h = screen_h - panel_y - STATUS_HEIGHT;

    const bg = if (state.dark_mode) c.Color{ .r = 30, .g = 30, .b = 30, .a = 255 } else c.RAYWHITE;
    c.DrawRectangleRec(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, bg);

    const border = if (state.dark_mode) c.Color{ .r = 60, .g = 60, .b = 60, .a = 255 } else c.LIGHTGRAY;
    c.DrawRectangleLinesEx(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, 1, border);

    const result = state.query_result orelse {
        const text_color = if (state.dark_mode) c.Color{ .r = 100, .g = 100, .b = 100, .a = 255 } else c.GRAY;
        c.DrawTextEx(c.GetFontDefault(), "No results", .{ .x = panel_x + 10, .y = panel_y + 10 }, FONT_SIZE, 1, text_color);
        return;
    };

    const col_width: f32 = 150;
    const row_height: f32 = FONT_SIZE + 6;
    var buf: [512]u8 = undefined;

    // Draw column headers
    const header_bg = if (state.dark_mode) c.Color{ .r = 50, .g = 50, .b = 60, .a = 255 } else c.Color{ .r = 220, .g = 220, .b = 240, .a = 255 };
    c.DrawRectangleRec(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = row_height }, header_bg);

    for (result.columns, 0..) |col, i| {
        const x = panel_x + 5 + @as(f32, @floatFromInt(i)) * col_width;
        if (x > panel_x + panel_w) break;
        const text = std.fmt.bufPrintZ(&buf, "{s}", .{col}) catch "<col>";
        const header_text_color = if (state.dark_mode) c.Color{ .r = 220, .g = 220, .b = 255, .a = 255 } else c.DARKBLUE;
        c.DrawTextEx(c.GetFontDefault(), text, .{ .x = x, .y = panel_y + 3 }, FONT_SIZE - 2, 1, header_text_color);
    }

    // Draw rows
    const text_color = if (state.dark_mode) c.Color{ .r = 200, .g = 200, .b = 200, .a = 255 } else c.DARKGRAY;
    const alt_row = if (state.dark_mode) c.Color{ .r = 35, .g = 35, .b = 40, .a = 255 } else c.Color{ .r = 245, .g = 245, .b = 250, .a = 255 };

    for (result.rows, 0..) |row, row_idx| {
        const y = panel_y + row_height + @as(f32, @floatFromInt(row_idx)) * row_height;
        if (y > panel_y + panel_h) break;

        if (row_idx % 2 == 1) {
            c.DrawRectangleRec(.{ .x = panel_x, .y = y, .width = panel_w, .height = row_height }, alt_row);
        }

        for (row, 0..) |cell, col_idx| {
            const x = panel_x + 5 + @as(f32, @floatFromInt(col_idx)) * col_width;
            if (x > panel_x + panel_w) break;

            const val = cell orelse "NULL";
            const text = std.fmt.bufPrintZ(&buf, "{s}", .{val}) catch "<val>";
            c.DrawTextEx(c.GetFontDefault(), text, .{ .x = x, .y = y + 3 }, FONT_SIZE - 2, 1, text_color);
        }
    }
}

fn drawStatusBar(state: *AppState) void {
    const screen_w: f32 = @floatFromInt(c.GetScreenWidth());
    const screen_h: f32 = @floatFromInt(c.GetScreenHeight());
    const y = screen_h - STATUS_HEIGHT;

    const bg = if (state.dark_mode) c.Color{ .r = 40, .g = 40, .b = 50, .a = 255 } else c.Color{ .r = 230, .g = 230, .b = 240, .a = 255 };
    c.DrawRectangleRec(.{ .x = 0, .y = y, .width = screen_w, .height = STATUS_HEIGHT }, bg);

    const text_color = if (state.dark_mode) c.Color{ .r = 180, .g = 180, .b = 200, .a = 255 } else c.DARKGRAY;

    if (state.status_len > 0) {
        c.DrawTextEx(c.GetFontDefault(), &state.status_message, .{ .x = 10, .y = y + 4 }, FONT_SIZE - 2, 1, text_color);
    }
}

fn drawFileDialog(state: *AppState) void {
    const screen_w: f32 = @floatFromInt(c.GetScreenWidth());
    const screen_h: f32 = @floatFromInt(c.GetScreenHeight());
    const dialog_w: f32 = 500;
    const dialog_h: f32 = 120;
    const dialog_x = (screen_w - dialog_w) / 2;
    const dialog_y = (screen_h - dialog_h) / 2;

    // Overlay
    c.DrawRectangleRec(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, c.Color{ .r = 0, .g = 0, .b = 0, .a = 128 });

    // Dialog background
    const bg = if (state.dark_mode) c.Color{ .r = 50, .g = 50, .b = 55, .a = 255 } else c.Color{ .r = 245, .g = 245, .b = 245, .a = 255 };
    c.DrawRectangleRec(.{ .x = dialog_x, .y = dialog_y, .width = dialog_w, .height = dialog_h }, bg);
    c.DrawRectangleLinesEx(.{ .x = dialog_x, .y = dialog_y, .width = dialog_w, .height = dialog_h }, 2, c.DARKGRAY);

    const text_color = if (state.dark_mode) c.Color{ .r = 220, .g = 220, .b = 220, .a = 255 } else c.DARKGRAY;
    c.DrawTextEx(c.GetFontDefault(), "Enter database file path:", .{ .x = dialog_x + 10, .y = dialog_y + 10 }, FONT_SIZE, 1, text_color);

    // File path input
    const edit_rect = c.Rectangle{
        .x = dialog_x + 10,
        .y = dialog_y + 35,
        .width = dialog_w - 20,
        .height = 30,
    };
    _ = c.GuiTextBox(edit_rect, &state.file_path_buf, 1024, true);
    state.file_path_len = std.mem.indexOfScalar(u8, &state.file_path_buf, 0) orelse 0;

    // OK button
    if (c.GuiButton(.{ .x = dialog_x + dialog_w - 170, .y = dialog_y + 80, .width = 75, .height = 30 }, "Open") != 0) {
        if (state.file_path_len > 0) {
            state.openDatabase(state.file_path_buf[0..state.file_path_len]);
        }
        state.show_file_dialog = false;
    }

    // Cancel button
    if (c.GuiButton(.{ .x = dialog_x + dialog_w - 85, .y = dialog_y + 80, .width = 75, .height = 30 }, "Cancel") != 0) {
        state.show_file_dialog = false;
    }

    // Escape to close
    if (c.IsKeyPressed(c.KEY_ESCAPE)) {
        state.show_file_dialog = false;
    }

    // Enter to confirm
    if (c.IsKeyPressed(c.KEY_ENTER) and state.file_path_len > 0) {
        state.openDatabase(state.file_path_buf[0..state.file_path_len]);
        state.show_file_dialog = false;
    }
}

fn loadTableData(state: *AppState, table_name: []const u8) void {
    if (state.query_result) |*qr| {
        qr.deinit();
        state.query_result = null;
    }

    var buf: [512]u8 = undefined;
    const sql = std.fmt.bufPrint(&buf, "SELECT * FROM \"{s}\" LIMIT 1000", .{table_name}) catch return;
    const len = @min(sql.len, MAX_QUERY_LEN);
    @memcpy(state.query_buf[0..len], sql[0..len]);
    state.query_buf[len] = 0;
    state.query_len = len;

    state.executeQuery();
}

fn formatFileSize(buf: *[256]u8, size: u64) [*:0]const u8 {
    if (size == 0) {
        return std.fmt.bufPrintZ(buf, "  Size: N/A", .{}) catch "  Size: N/A";
    }

    const units = [_][]const u8{ "bytes", "KB", "MB", "GB", "TB" };
    var num: f64 = @floatFromInt(size);
    var unit_idx: usize = 0;

    while (num >= 1024 and unit_idx < units.len - 1) {
        num /= 1024.0;
        unit_idx += 1;
    }

    return std.fmt.bufPrintZ(buf, "  Size: {d:.2} {s}", .{ num, units[unit_idx] }) catch "  Size: unknown";
}
