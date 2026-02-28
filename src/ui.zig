//! Immediate-mode GUI renderer using SDL2 and SDL2_ttf.
//! Every frame all UI elements are drawn from scratch based on current app state.

const std = @import("std");
const sdl = @import("sdl.zig");
const c = sdl.c;
const AppState = @import("app.zig").AppState;
const AppTab = @import("app.zig").AppTab;
const export_mod = @import("export.zig");
const Config = @import("config.zig").Config;

// ─── SDL key constants ────────────────────────────────────────────────────────
const SDLK_RETURN: i32 = 13;
const SDLK_BACKSPACE: i32 = 8;
const SDLK_ESCAPE: i32 = 27;
const SDLK_TAB: i32 = 9;
const SDLK_DELETE: i32 = (1 << 30) | 76;
const SDLK_LEFT: i32 = (1 << 30) | 80;
const SDLK_RIGHT: i32 = (1 << 30) | 79;
const SDLK_HOME: i32 = (1 << 30) | 74;
const SDLK_END: i32 = (1 << 30) | 77;

// ─── Layout ───────────────────────────────────────────────────────────────────
const TOOLBAR_H: i32 = 45;
const TABBAR_H: i32 = 35;
const STATUSBAR_H: i32 = 28;
const SIDEBAR_W: i32 = 200;
const EDITOR_FRACTION: f32 = 0.35;
const FONT_SIZE: i32 = 15;
const PADDING: i32 = 8;
const ROW_H: i32 = 22;
const SCROLL_SPEED: f32 = 30.0;
const BUTTON_H: i32 = 30;

// ─── Color theme (dark) ───────────────────────────────────────────────────────
fn col(r: u8, g: u8, b: u8) c.SDL_Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}
const COL_BG = col(30, 30, 35);
const COL_PANEL = col(40, 40, 48);
const COL_TOOLBAR = col(35, 35, 43);
const COL_SIDEBAR = col(38, 38, 46);
const COL_EDITOR = col(24, 24, 30);
const COL_RESULTS = col(28, 28, 34);
const COL_HEADER = col(50, 50, 62);
const COL_ROW_ALT = col(32, 32, 40);
const COL_BUTTON = col(60, 100, 180);
const COL_BUTTON_HOV = col(80, 120, 210);
const COL_BUTTON_ACT = col(50, 85, 155);
const COL_TAB_ACT = col(60, 100, 180);
const COL_TAB_INACT = col(50, 50, 62);
const COL_SEL_ROW = col(55, 90, 160);
const COL_TEXT = col(220, 220, 220);
const COL_TEXT_DIM = col(140, 140, 150);
const COL_CURSOR = col(200, 200, 80);
const COL_ERROR = col(200, 60, 60);
const COL_BORDER = col(60, 60, 75);

// ─── Font paths ───────────────────────────────────────────────────────────────
const FONT_PATHS = [_][*:0]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
};
const MONO_PATHS = [_][*:0]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
};

// ─── UI context ───────────────────────────────────────────────────────────────
pub const Ui = struct {
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    font_mono: *c.TTF_Font,
    mx: i32,
    my: i32,
    mouse_down: bool,
    mouse_clicked: bool,
    scroll_dy: f32,
    allocator: std.mem.Allocator,

    pub fn init(renderer: *c.SDL_Renderer, allocator: std.mem.Allocator) !Ui {
        if (c.TTF_Init() < 0) return error.TTFInitFailed;
        const font = loadFont(FONT_SIZE) orelse return error.FontLoadFailed;
        const mono = loadMonoFont(FONT_SIZE) orelse font;
        return Ui{
            .renderer = renderer,
            .font = font,
            .font_mono = mono,
            .mx = 0,
            .my = 0,
            .mouse_down = false,
            .mouse_clicked = false,
            .scroll_dy = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Ui) void {
        c.TTF_CloseFont(self.font);
        if (self.font_mono != self.font) c.TTF_CloseFont(self.font_mono);
        c.TTF_Quit();
    }

    pub fn beginFrame(self: *Ui) void {
        self.mouse_clicked = false;
        self.scroll_dy = 0;
    }

    pub fn fillRect(self: *Ui, x: i32, y: i32, w: i32, h: i32, color: c.SDL_Color) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, color.r, color.g, color.b, color.a);
        const r = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
        _ = c.SDL_RenderFillRect(self.renderer, &r);
    }

    pub fn drawRectOutline(self: *Ui, x: i32, y: i32, w: i32, h: i32, color: c.SDL_Color) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, color.r, color.g, color.b, color.a);
        const r = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
        _ = c.SDL_RenderDrawRect(self.renderer, &r);
    }

    pub fn drawText(self: *Ui, x: i32, y: i32, text: []const u8, color: c.SDL_Color, mono: bool) i32 {
        if (text.len == 0) return 0;
        var buf: [1024]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        const font = if (mono) self.font_mono else self.font;
        const surf = c.TTF_RenderUTF8_Blended(font, &buf, color) orelse return 0;
        defer c.SDL_FreeSurface(surf);
        const tex = c.SDL_CreateTextureFromSurface(self.renderer, surf) orelse return 0;
        defer c.SDL_DestroyTexture(tex);
        var tw: c_int = 0;
        var th: c_int = 0;
        _ = c.SDL_QueryTexture(tex, null, null, &tw, &th);
        const dst = c.SDL_Rect{ .x = x, .y = y, .w = tw, .h = th };
        _ = c.SDL_RenderCopy(self.renderer, tex, null, &dst);
        return @intCast(tw);
    }

    pub fn drawTextClipped(self: *Ui, x: i32, y: i32, max_w: i32, text: []const u8, color: c.SDL_Color, mono: bool) void {
        if (text.len == 0 or max_w <= 0) return;
        const approx: usize = @intCast(@max(1, @divTrunc(max_w, 9)));
        const n = @min(text.len, @min(approx, @as(usize, 1023)));
        var buf: [1024]u8 = undefined;
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        const font = if (mono) self.font_mono else self.font;
        const surf = c.TTF_RenderUTF8_Blended(font, &buf, color) orelse return;
        defer c.SDL_FreeSurface(surf);
        const tex = c.SDL_CreateTextureFromSurface(self.renderer, surf) orelse return;
        defer c.SDL_DestroyTexture(tex);
        var tw: c_int = 0;
        var th: c_int = 0;
        _ = c.SDL_QueryTexture(tex, null, null, &tw, &th);
        const w = @min(tw, max_w);
        const dst = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = th };
        const src = c.SDL_Rect{ .x = 0, .y = 0, .w = w, .h = th };
        _ = c.SDL_RenderCopy(self.renderer, tex, &src, &dst);
    }

    pub fn button(self: *Ui, x: i32, y: i32, w: i32, h: i32, label: []const u8) bool {
        const hov = self.isHovered(x, y, w, h);
        const color = if (hov and self.mouse_down) COL_BUTTON_ACT else if (hov) COL_BUTTON_HOV else COL_BUTTON;
        self.fillRect(x, y, w, h, color);
        self.drawRectOutline(x, y, w, h, COL_BORDER);
        var buf: [256]u8 = undefined;
        const n = @min(label.len, buf.len - 1);
        @memcpy(buf[0..n], label[0..n]);
        buf[n] = 0;
        var tw: c_int = 0;
        _ = c.TTF_SizeUTF8(self.font, &buf, &tw, null);
        _ = self.drawText(x + @divTrunc(w - tw, 2), y + @divTrunc(h - FONT_SIZE, 2), label, COL_TEXT, false);
        return hov and self.mouse_clicked;
    }

    pub fn isClicked(self: *const Ui, x: i32, y: i32, w: i32, h: i32) bool {
        return self.mouse_clicked and self.mx >= x and self.mx < x + w and
            self.my >= y and self.my < y + h;
    }

    pub fn isHovered(self: *const Ui, x: i32, y: i32, w: i32, h: i32) bool {
        return self.mx >= x and self.mx < x + w and self.my >= y and self.my < y + h;
    }

    pub fn measureText(self: *Ui, text: []const u8) i32 {
        if (text.len == 0) return 0;
        var buf: [1024]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        var tw: c_int = 0;
        _ = c.TTF_SizeUTF8(self.font_mono, &buf, &tw, null);
        return @intCast(tw);
    }
};

fn loadFont(size: i32) ?*c.TTF_Font {
    for (FONT_PATHS) |p| {
        const f = c.TTF_OpenFont(p, size);
        if (f != null) return f;
    }
    return null;
}

fn loadMonoFont(size: i32) ?*c.TTF_Font {
    for (MONO_PATHS) |p| {
        const f = c.TTF_OpenFont(p, size);
        if (f != null) return f;
    }
    return null;
}

// ─── GUI entry point ──────────────────────────────────────────────────────────

pub fn runGui(initial_db: ?[]const u8, allocator: std.mem.Allocator) !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS) != 0) {
        std.debug.print("SDL_Init error: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    var config = Config.load(allocator) catch Config{};
    defer config.deinit(allocator);

    const win_w: c_int = @intCast(config.window_width);
    const win_h: c_int = @intCast(config.window_height);

    const window = c.SDL_CreateWindow(
        "SQLite Query Analyzer",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        win_w,
        win_h,
        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_RESIZABLE,
    ) orelse {
        std.debug.print("SDL_CreateWindow error: {s}\n", .{c.SDL_GetError()});
        return error.WindowCreateFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(
        window,
        -1,
        c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC,
    ) orelse {
        std.debug.print("SDL_CreateRenderer error: {s}\n", .{c.SDL_GetError()});
        return error.RendererCreateFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "1");

    var ui = try Ui.init(renderer, allocator);
    defer ui.deinit();

    var app = AppState.init(allocator);
    defer app.deinit();

    app.window_w = @intCast(win_w);
    app.window_h = @intCast(win_h);
    app.config = config;

    const db_path = initial_db orelse if (config.last_db_path.len > 0) config.last_db_path else null;
    if (db_path) |path| app.openDatabase(path) catch {};

    if (config.last_query.len > 0) {
        const n = @min(config.last_query.len, app.query_buf.len - 1);
        @memcpy(app.query_buf[0..n], config.last_query[0..n]);
        app.query_len = n;
        app.query_cursor = n;
    }

    c.SDL_StartTextInput();
    defer c.SDL_StopTextInput();

    var running = true;
    while (running) {
        ui.beginFrame();
        running = handleEvents(&ui, &app);
        if (!running) break;

        _ = c.SDL_SetRenderDrawColor(renderer, 30, 30, 35, 255);
        _ = c.SDL_RenderClear(renderer);
        renderFrame(&ui, &app);
        c.SDL_RenderPresent(renderer);
    }

    var save_cfg = Config{
        .last_db_path = app.dbPath(),
        .window_width = @intCast(app.window_w),
        .window_height = @intCast(app.window_h),
        .last_query = app.queryText(),
        .last_table = if (app.selected_table >= 0 and
            app.selected_table < @as(i32, @intCast(app.tables.len)))
            app.tables[@intCast(app.selected_table)]
        else
            "",
    };
    save_cfg.save(allocator) catch {};
}

// ─── Frame rendering ──────────────────────────────────────────────────────────

pub fn renderFrame(ui: *Ui, app: *AppState) void {
    const w = app.window_w;
    const h = app.window_h;

    ui.fillRect(0, 0, w, h, COL_BG);
    renderToolbar(ui, app, w);
    renderStatusBar(ui, app, w, h);

    const content_top = TOOLBAR_H;
    const content_bottom = h - STATUSBAR_H;
    const content_h = content_bottom - content_top;

    if (app.db == null and !app.show_open_dialog) {
        renderWelcome(ui, w, content_top, content_h);
    } else {
        renderTabBar(ui, app, SIDEBAR_W, content_top, w - SIDEBAR_W);
        const tab_bottom = content_top + TABBAR_H;
        const main_h = content_bottom - tab_bottom;
        renderSidebar(ui, app, content_top, content_h);
        switch (app.tab) {
            .Query => renderQueryTab(ui, app, SIDEBAR_W, tab_bottom, w - SIDEBAR_W, main_h),
            .Tables => renderTablesTab(ui, app, SIDEBAR_W, tab_bottom, w - SIDEBAR_W, main_h),
            .Schema => renderSchemaTab(ui, app, SIDEBAR_W, tab_bottom, w - SIDEBAR_W, main_h),
        }
    }

    if (app.show_open_dialog) renderOpenDialog(ui, app, w, h);
}

fn renderToolbar(ui: *Ui, app: *AppState, w: i32) void {
    ui.fillRect(0, 0, w, TOOLBAR_H, COL_TOOLBAR);
    ui.fillRect(0, TOOLBAR_H - 1, w, 1, COL_BORDER);

    const by: i32 = @divTrunc(TOOLBAR_H - BUTTON_H, 2);
    var bx: i32 = PADDING;

    if (ui.button(bx, by, 90, BUTTON_H, "Open DB")) {
        app.show_open_dialog = true;
        const last = app.config.last_db_path;
        const n = @min(last.len, app.open_path_buf.len - 1);
        @memcpy(app.open_path_buf[0..n], last[0..n]);
        app.open_path_len = n;
    }
    bx += 100;

    if (app.db != null and app.query_len > 0) {
        if (ui.button(bx, by, 90, BUTTON_H, "Execute")) app.executeQuery();
    } else {
        ui.fillRect(bx, by, 90, BUTTON_H, COL_TAB_INACT);
        ui.drawRectOutline(bx, by, 90, BUTTON_H, COL_BORDER);
        _ = ui.drawText(bx + 18, by + @divTrunc(BUTTON_H - FONT_SIZE, 2), "Execute", COL_TEXT_DIM, false);
    }
    bx += 100;

    if (app.db != null) {
        if (ui.button(bx, by, 100, BUTTON_H, "Export CSV")) exportDb(app);
        bx += 110;
    }

    const text_y = by + @divTrunc(BUTTON_H - FONT_SIZE, 2);
    if (app.db_path_len > 0) {
        _ = ui.drawText(bx + 10, text_y, "DB: ", COL_TEXT_DIM, false);
        ui.drawTextClipped(bx + 44, text_y, w - bx - 54, app.dbPath(), COL_TEXT, false);
    } else {
        _ = ui.drawText(bx + 10, text_y, "No database open", COL_TEXT_DIM, false);
    }
}

fn renderTabBar(ui: *Ui, app: *AppState, x: i32, y: i32, w: i32) void {
    ui.fillRect(x, y, w, TABBAR_H, COL_PANEL);
    ui.fillRect(x, y + TABBAR_H - 1, w, 1, COL_BORDER);

    const labels = [_][]const u8{ "Query", "Tables", "Schema" };
    const tab_vals = [_]AppTab{ .Query, .Tables, .Schema };
    var tx = x + PADDING;
    for (labels, 0..) |lbl, i| {
        const tw: i32 = 90;
        const is_active = app.tab == tab_vals[i];
        ui.fillRect(tx, y + 4, tw, TABBAR_H - 4, if (is_active) COL_TAB_ACT else COL_TAB_INACT);
        if (is_active) ui.fillRect(tx, y + TABBAR_H - 3, tw, 3, COL_BUTTON);
        _ = ui.drawText(tx + @divTrunc(tw - 50, 2), y + @divTrunc(TABBAR_H - FONT_SIZE, 2), lbl, COL_TEXT, false);
        if (ui.isClicked(tx, y, tw, TABBAR_H)) {
            app.tab = tab_vals[i];
            if (app.tab == .Schema) app.loadSchema();
        }
        tx += tw + 4;
    }
}

fn renderSidebar(ui: *Ui, app: *AppState, top: i32, h: i32) void {
    ui.fillRect(0, top, SIDEBAR_W, h, COL_SIDEBAR);
    ui.fillRect(SIDEBAR_W - 1, top, 1, h, COL_BORDER);
    _ = ui.drawText(PADDING, top + PADDING, "Tables", COL_TEXT_DIM, false);

    const list_top = top + TABBAR_H + 4;
    var ry = list_top - @as(i32, @intFromFloat(app.table_scroll_y));

    for (app.tables, 0..) |tbl, i| {
        if (ry + ROW_H < top) { ry += ROW_H; continue; }
        if (ry >= top + h) break;
        const sel = app.selected_table == @as(i32, @intCast(i));
        ui.fillRect(0, ry, SIDEBAR_W - 1, ROW_H, if (sel) COL_SEL_ROW else if (i % 2 == 0) COL_SIDEBAR else COL_PANEL);
        ui.drawTextClipped(PADDING, ry + @divTrunc(ROW_H - FONT_SIZE, 2), SIDEBAR_W - 2 * PADDING, tbl, COL_TEXT, false);
        if (ui.isClicked(0, ry, SIDEBAR_W - 1, ROW_H)) {
            app.selectTable(i);
            app.executeQuery();
        }
        ry += ROW_H;
    }

    if (ui.isHovered(0, top, SIDEBAR_W, h)) {
        app.table_scroll_y -= ui.scroll_dy;
        const max_s: f32 = @max(0, @as(f32, @floatFromInt(app.tables.len * ROW_H)) - @as(f32, @floatFromInt(h - TABBAR_H)));
        app.table_scroll_y = std.math.clamp(app.table_scroll_y, 0, max_s);
    }
}

fn renderQueryTab(ui: *Ui, app: *AppState, x: i32, y: i32, w: i32, h: i32) void {
    const editor_h: i32 = @intFromFloat(@as(f32, @floatFromInt(h)) * EDITOR_FRACTION);
    renderEditor(ui, app, x, y, w, editor_h);
    ui.fillRect(x, y + editor_h - 1, w, 1, COL_BORDER);
    renderResults(ui, app, x, y + editor_h, w, h - editor_h);
}

fn renderEditor(ui: *Ui, app: *AppState, x: i32, y: i32, w: i32, h: i32) void {
    ui.fillRect(x, y, w, h, COL_EDITOR);
    ui.fillRect(x, y, w, ROW_H, COL_HEADER);
    _ = ui.drawText(x + PADDING, y + @divTrunc(ROW_H - FONT_SIZE, 2), "SQL Query  (Ctrl+Enter to execute)", COL_TEXT_DIM, false);

    const ta_y = y + ROW_H;
    const ta_h = h - ROW_H;
    const clip = c.SDL_Rect{ .x = x + 1, .y = ta_y, .w = w - 2, .h = ta_h };
    _ = c.SDL_RenderSetClipRect(ui.renderer, &clip);

    const text = app.queryText();
    var line_y = ta_y + PADDING - @as(i32, @intFromFloat(app.query_scroll_y));
    var pos: usize = 0;
    var cursor_drawn = false;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const line_end = pos + line.len;
        if (line_y + ROW_H >= ta_y and line_y < ta_y + ta_h) {
            _ = ui.drawText(x + PADDING, line_y, line, COL_TEXT, true);
            if (!cursor_drawn and app.query_cursor >= pos and
                (app.query_cursor <= line_end or line_end == text.len))
            {
                const col_off = app.query_cursor - pos;
                const cx = x + PADDING + ui.measureText(line[0..@min(col_off, line.len)]);
                ui.fillRect(cx, line_y, 2, ROW_H, COL_CURSOR);
                cursor_drawn = true;
            }
        }
        line_y += ROW_H;
        pos += line.len + 1;
    }

    if (ui.isHovered(x, ta_y, w, ta_h)) {
        app.query_scroll_y -= ui.scroll_dy;
        app.query_scroll_y = @max(0, app.query_scroll_y);
    }
    _ = c.SDL_RenderSetClipRect(ui.renderer, null);
}

fn renderResults(ui: *Ui, app: *AppState, x: i32, y: i32, w: i32, h: i32) void {
    ui.fillRect(x, y, w, h, COL_RESULTS);
    ui.fillRect(x, y, w, ROW_H, COL_HEADER);

    if (app.result_error_len > 0) {
        _ = ui.drawText(x + PADDING, y + @divTrunc(ROW_H - FONT_SIZE, 2), app.resultError(), COL_ERROR, false);
    } else if (app.result) |res| {
        var hdr_buf: [128]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "Results: {d} rows, {d} cols  ({d}ms)", .{
            res.rows.len, res.columns.len, app.query_time_ms,
        }) catch "Results";
        _ = ui.drawText(x + PADDING, y + @divTrunc(ROW_H - FONT_SIZE, 2), hdr, COL_TEXT_DIM, false);
    } else {
        _ = ui.drawText(x + PADDING, y + @divTrunc(ROW_H - FONT_SIZE, 2), "Results", COL_TEXT_DIM, false);
    }

    const result = app.result orelse return;
    const ncols = result.columns.len;
    if (ncols == 0) return;

    const col_w: i32 = @max(100, @divTrunc(w - PADDING, @as(i32, @intCast(ncols))));
    const header_y = y + ROW_H;
    const data_y = header_y + ROW_H;
    const data_h = h - 2 * ROW_H;

    const clip = c.SDL_Rect{ .x = x + 1, .y = header_y, .w = w - 2, .h = data_h + ROW_H };
    _ = c.SDL_RenderSetClipRect(ui.renderer, &clip);

    const sx: i32 = @intFromFloat(app.result_scroll_x);
    for (result.columns, 0..) |name, ci| {
        const cx = x + @as(i32, @intCast(ci)) * col_w - sx;
        if (cx + col_w < x or cx > x + w) continue;
        ui.fillRect(cx, header_y, col_w - 1, ROW_H, COL_HEADER);
        ui.fillRect(cx + col_w - 1, header_y, 1, ROW_H, COL_BORDER);
        ui.drawTextClipped(cx + PADDING, header_y + @divTrunc(ROW_H - FONT_SIZE, 2), col_w - 2 * PADDING, name, COL_TEXT, false);
    }

    const sy: i32 = @intFromFloat(app.result_scroll_y);
    for (result.rows, 0..) |row, ri| {
        const ry = data_y + @as(i32, @intCast(ri)) * ROW_H - sy;
        if (ry + ROW_H < data_y) continue;
        if (ry > data_y + data_h) break;
        ui.fillRect(x, ry, w, ROW_H, if (ri % 2 == 0) COL_RESULTS else COL_ROW_ALT);
        for (row, 0..) |cell, ci| {
            const cx = x + @as(i32, @intCast(ci)) * col_w - sx;
            if (cx + col_w < x or cx > x + w) continue;
            ui.fillRect(cx + col_w - 1, ry, 1, ROW_H, COL_BORDER);
            const tc = if (std.mem.eql(u8, cell, "NULL")) COL_TEXT_DIM else COL_TEXT;
            ui.drawTextClipped(cx + PADDING, ry + @divTrunc(ROW_H - FONT_SIZE, 2), col_w - 2 * PADDING, cell, tc, true);
        }
    }

    if (ui.isHovered(x, data_y, w, data_h)) {
        app.result_scroll_y -= ui.scroll_dy;
        const max_sy: f32 = @max(0, @as(f32, @floatFromInt(result.rows.len * ROW_H)) - @as(f32, @floatFromInt(data_h)));
        app.result_scroll_y = std.math.clamp(app.result_scroll_y, 0, max_sy);
    }
    _ = c.SDL_RenderSetClipRect(ui.renderer, null);
}

fn renderTablesTab(ui: *Ui, app: *AppState, x: i32, y: i32, w: i32, h: i32) void {
    if (app.result != null) {
        renderResults(ui, app, x, y, w, h);
    } else {
        ui.fillRect(x, y, w, h, COL_RESULTS);
        _ = ui.drawText(x + PADDING, y + ROW_H + PADDING, "Select a table from the sidebar to view its data.", COL_TEXT_DIM, false);
    }
}

fn renderSchemaTab(ui: *Ui, app: *AppState, x: i32, y: i32, w: i32, h: i32) void {
    ui.fillRect(x, y, w, h, COL_EDITOR);
    ui.fillRect(x, y, w, ROW_H, COL_HEADER);
    _ = ui.drawText(x + PADDING, y + @divTrunc(ROW_H - FONT_SIZE, 2), "Database Schema", COL_TEXT_DIM, false);

    const schema = app.schema_buf orelse {
        _ = ui.drawText(x + PADDING, y + ROW_H + PADDING, "No schema available.", COL_TEXT_DIM, false);
        return;
    };

    const ta_y = y + ROW_H;
    const ta_h = h - ROW_H;
    const clip = c.SDL_Rect{ .x = x + 1, .y = ta_y, .w = w - 2, .h = ta_h };
    _ = c.SDL_RenderSetClipRect(ui.renderer, &clip);

    const sy: i32 = @intFromFloat(app.schema_scroll_y);
    var ly = ta_y + PADDING - sy;
    var it = std.mem.splitScalar(u8, schema, '\n');
    while (it.next()) |line| {
        if (ly + ROW_H >= ta_y and ly < ta_y + ta_h) _ = ui.drawText(x + PADDING, ly, line, COL_TEXT, true);
        ly += ROW_H;
        if (ly > ta_y + ta_h + ROW_H) break;
    }

    if (ui.isHovered(x, ta_y, w, ta_h)) {
        app.schema_scroll_y -= ui.scroll_dy;
        app.schema_scroll_y = @max(0, app.schema_scroll_y);
    }
    _ = c.SDL_RenderSetClipRect(ui.renderer, null);
}

fn renderWelcome(ui: *Ui, w: i32, y: i32, h: i32) void {
    const cx = @divTrunc(w, 2);
    const cy = y + @divTrunc(h, 2);
    _ = ui.drawText(cx - 175, cy - 25, "SQLite Query Analyzer", COL_TEXT, false);
    _ = ui.drawText(cx - 155, cy + 5, "Click 'Open DB' to open a database", COL_TEXT_DIM, false);
}

fn renderStatusBar(ui: *Ui, app: *AppState, w: i32, h: i32) void {
    const sy = h - STATUSBAR_H;
    ui.fillRect(0, sy, w, STATUSBAR_H, COL_TOOLBAR);
    ui.fillRect(0, sy, w, 1, COL_BORDER);
    const color = if (app.status_is_error) COL_ERROR else COL_TEXT_DIM;
    _ = ui.drawText(PADDING, sy + @divTrunc(STATUSBAR_H - FONT_SIZE, 2), app.statusMessage(), color, false);
}

fn renderOpenDialog(ui: *Ui, app: *AppState, w: i32, h: i32) void {
    _ = c.SDL_SetRenderDrawBlendMode(ui.renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(ui.renderer, 0, 0, 0, 160);
    const ov = c.SDL_Rect{ .x = 0, .y = 0, .w = w, .h = h };
    _ = c.SDL_RenderFillRect(ui.renderer, &ov);
    _ = c.SDL_SetRenderDrawBlendMode(ui.renderer, c.SDL_BLENDMODE_NONE);

    const dw: i32 = 560;
    const dh: i32 = 140;
    const dx = @divTrunc(w - dw, 2);
    const dy = @divTrunc(h - dh, 2);

    ui.fillRect(dx, dy, dw, dh, COL_PANEL);
    ui.drawRectOutline(dx, dy, dw, dh, COL_BORDER);
    _ = ui.drawText(dx + PADDING, dy + PADDING, "Open Database File", COL_TEXT, false);
    _ = ui.drawText(dx + PADDING, dy + 30, "Enter path to .sqlite / .db file:", COL_TEXT_DIM, false);

    const ib_x = dx + PADDING;
    const ib_y = dy + 55;
    const ib_w = dw - 2 * PADDING;
    const ib_h = 30;
    ui.fillRect(ib_x, ib_y, ib_w, ib_h, COL_EDITOR);
    ui.drawRectOutline(ib_x, ib_y, ib_w, ib_h, COL_BUTTON);
    ui.drawTextClipped(ib_x + PADDING, ib_y + @divTrunc(ib_h - FONT_SIZE, 2), ib_w - 2 * PADDING, app.open_path_buf[0..app.open_path_len], COL_TEXT, false);
    const cursor_px = ib_x + PADDING + ui.measureText(app.open_path_buf[0..app.open_path_len]);
    ui.fillRect(cursor_px, ib_y + 4, 2, ib_h - 8, COL_CURSOR);

    const btn_y = dy + dh - BUTTON_H - PADDING;
    if (ui.button(dx + PADDING, btn_y, 80, BUTTON_H, "Open")) commitOpenDialog(app);
    if (ui.button(dx + PADDING + 90, btn_y, 80, BUTTON_H, "Cancel")) app.show_open_dialog = false;
}

fn commitOpenDialog(app: *AppState) void {
    const path = app.open_path_buf[0..app.open_path_len];
    if (path.len == 0) return;
    app.openDatabase(path) catch |err| {
        app.setStatus(true, "Failed to open: {}", .{err});
    };
    app.show_open_dialog = false;
}

fn exportDb(app: *AppState) void {
    if (app.db == null) return;
    export_mod.exportDatabaseCsv(&app.db.?, ".", false, app.allocator) catch |err| {
        app.setStatus(true, "Export failed: {}", .{err});
        return;
    };
    app.setStatus(false, "CSV exported to current directory", .{});
}

// ─── Input handling ───────────────────────────────────────────────────────────

pub fn handleEvents(ui: *Ui, app: *AppState) bool {
    var event: c.SDL_Event = undefined;
    var prev_down = ui.mouse_down;

    while (c.SDL_PollEvent(&event) != 0) {
        switch (event.type) {
            c.SDL_QUIT => return false,

            c.SDL_WINDOWEVENT => {
                if (event.window.event == c.SDL_WINDOWEVENT_RESIZED) {
                    app.window_w = event.window.data1;
                    app.window_h = event.window.data2;
                }
            },

            c.SDL_MOUSEBUTTONDOWN => ui.mouse_down = true,

            c.SDL_MOUSEBUTTONUP => {
                ui.mouse_down = false;
                if (prev_down) ui.mouse_clicked = true;
            },

            c.SDL_MOUSEMOTION => {
                ui.mx = event.motion.x;
                ui.my = event.motion.y;
            },

            c.SDL_MOUSEWHEEL => {
                ui.scroll_dy += @as(f32, @floatFromInt(event.wheel.y)) * SCROLL_SPEED;
            },

            c.SDL_KEYDOWN => {
                const key = event.key.keysym.sym;
                const ctrl = (event.key.keysym.mod & c.KMOD_CTRL) != 0;
                if (app.show_open_dialog) handleDialogKey(app, key) else handleEditorKey(app, key, ctrl);
            },

            c.SDL_TEXTINPUT => {
                const text = std.mem.sliceTo(&event.text.text, 0);
                if (app.show_open_dialog) {
                    for (text) |ch| {
                        if (app.open_path_len < app.open_path_buf.len - 1) {
                            app.open_path_buf[app.open_path_len] = ch;
                            app.open_path_len += 1;
                        }
                    }
                } else {
                    for (text) |ch| app.insertChar(ch);
                }
            },

            else => {},
        }
        prev_down = ui.mouse_down;
    }
    return true;
}

fn handleEditorKey(app: *AppState, key: i32, ctrl: bool) void {
    if (ctrl) {
        if (key == SDLK_RETURN) app.executeQuery();
        return;
    }
    switch (key) {
        SDLK_BACKSPACE => app.backspace(),
        SDLK_DELETE => app.deleteForward(),
        SDLK_LEFT => { if (app.query_cursor > 0) app.query_cursor -= 1; },
        SDLK_RIGHT => { if (app.query_cursor < app.query_len) app.query_cursor += 1; },
        SDLK_HOME => app.query_cursor = 0,
        SDLK_END => app.query_cursor = app.query_len,
        SDLK_RETURN => app.insertChar('\n'),
        SDLK_TAB => { for (0..4) |_| app.insertChar(' '); },
        SDLK_ESCAPE => { if (app.show_open_dialog) app.show_open_dialog = false; },
        else => {},
    }
}

fn handleDialogKey(app: *AppState, key: i32) void {
    switch (key) {
        SDLK_BACKSPACE => { if (app.open_path_len > 0) app.open_path_len -= 1; },
        SDLK_RETURN => commitOpenDialog(app),
        SDLK_ESCAPE => app.show_open_dialog = false,
        else => {},
    }
}
