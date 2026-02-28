# sqlitequery – Copilot Instructions

`sqlitequery` is a fast, cross-platform SQLite Query Analyzer written in Zig (minimum version 0.15.2). It provides both a CLI and an immediate-mode GUI (via raylib/raygui) for querying and manipulating SQLite databases.

## Build, run, and test

```sh
# Install system dependencies (Ubuntu/Debian)
sudo apt-get install -y libsqlite3-dev libglfw3-dev libgl1-mesa-dev libx11-dev

# Install raylib (download pre-built release or build from source)
# See README.md for detailed instructions

zig build              # compile → zig-out/bin/sqlitequery
zig build run          # build + run (opens GUI)
zig build run -- db.db # build + run with a database file
zig build test         # run all tests
```

There is no per-file test runner; individual test blocks are inline in their source files. To iterate on a single module's tests, temporarily set `root_source_file` in the `test_exe` step in `build.zig` to that file, or just run `zig build test` — it's fast.

## Architecture

All source files live flat in `src/`. The module structure is:

```
main.zig  →  cli.zig  →  gui.zig (raylib/raygui)
                ↓
          database.zig  ←  analyzer.zig
                ↓              ↓
          export.zig    settings.zig
```

| File | Responsibility |
|---|---|
| `main.zig` | Entry point; owns the `GeneralPurposeAllocator`; dispatches to CLI |
| `cli.zig` | CLI argument parsing; dispatches to export functions or GUI |
| `database.zig` | SQLite3 wrapper via `@cImport`; provides `Database` and `QueryResult` structs |
| `analyzer.zig` | Database schema analysis; loads tables and columns via PRAGMA queries |
| `export.zig` | Export functionality: schema as SQL, data as INSERT statements, data as CSV |
| `settings.zig` | Session and window state persistence (JSON files in `~/.sqlite_query_analyzer/`) |
| `gui.zig` | Immediate-mode GUI using raylib for rendering and raygui for widgets |
| `raygui_impl.c` | C file that includes raygui.h with RAYGUI_IMPLEMENTATION defined |

## Key conventions

**Tests are inline.** Every `.zig` file that has logic contains `test` blocks directly in that file. `main.zig` has a `test "imports compile"` block that imports all modules, ensuring the test binary transitively covers all inline tests.

**Memory management is explicit.** Every heap allocation has a corresponding `defer` or `errdefer` free. The `Database`, `QueryResult`, `DatabaseInfo`, `Table`, `Column`, and `SessionState` structs all have `deinit()` methods that must be called.

**SQLite is accessed via C interop.** The `database.zig` module uses `@cImport(@cInclude("sqlite3.h"))` and links against the system `libsqlite3`. Zig strings are converted to null-terminated C strings for SQLite API calls.

**GUI uses immediate mode rendering.** The GUI in `gui.zig` uses raylib for the rendering loop and raygui for UI widgets. No retained-mode widget tree — everything is drawn each frame. The raygui implementation is in a separate C file to avoid duplicate symbol issues.

**File I/O uses direct writeAll.** In Zig 0.15.2, the `File.writer()` API changed. All file writing uses `file.writeAll()` with pre-formatted buffers instead of the buffered writer API.

**Settings use simple JSON.** Session state and window state are persisted as JSON files in `~/.sqlite_query_analyzer/`. A simple custom JSON parser/writer is used rather than the std library JSON module.

**Source control:** Commit progress to git in small logical chunks with clear one-liner messages. Do not change the committer to Copilot and do not add a Co-Author line.
