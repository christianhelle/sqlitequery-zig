# SQLite Query Analyzer – Copilot Instructions

## Project

**sqlitequery-zig** is a high-performance, cross-platform SQLite database GUI and
CLI tool written in [Zig](https://ziglang.org/) targeting **Zig 0.15.x**.  
It is a full rewrite of the original C++/Qt project
[christianhelle/sqlitequery](https://github.com/christianhelle/sqlitequery).

The UI is immediate-mode, rendered with **SDL2 + SDL2_ttf** – every frame is
drawn from scratch based on application state, with no retained widget tree.

---

## Repository layout

```
src/
  main.zig      Entry point: CLI dispatch or GUI launch
  app.zig       Mutable application state (AppState)
  database.zig  SQLite C-FFI wrapper with QueryResult
  export.zig    CSV / SQL-INSERT / schema export helpers
  cli.zig       Argument parsing and headless CLI runner
  config.zig    JSON session persistence (~/.config/sqlitequery/)
  ui.zig        SDL2 immediate-mode renderer + event loop
  sdl.zig       Shared SDL2 @cImport (avoids duplicate-type errors)
  tests.zig     Test aggregator (refAllDecls on all modules)
snap/
  snapcraft.yaml  Snap packaging for Ubuntu App Store
.github/
  workflows/build.yml  CI: build + test on every push/PR
```

---

## Zig version and API notes

- **Target: Zig 0.15.2** (beta channel snap).
- `std.ArrayList(T)` is the **unmanaged** variant: every method (`append`,
  `deinit`, `toOwnedSlice`, …) receives the allocator as a parameter.
- `main()` takes **no parameters** (`pub fn main() !void`).
- JSON serialisation uses `std.json.Stringify` (not the removed `std.json.stringify`).
- Formatted output uses `std.fs.File.stdout().writeAll(...)` with pre-formatted
  `std.fmt.bufPrint` buffers — not `std.io.getStdOut()`.
- File creation: `std.fs.cwd().createFile(...)` / `std.fs.createFileAbsolute(...)`.
- Directory creation: `std.fs.makeDirAbsolute(...)`.
- **Never** use `std.io.getStdOut()` — it does not exist in 0.15.x.
- **Never** use two separate `@cImport` blocks for the same headers across
  modules — import via `sdl.zig` to share one cImport context.

---

## Code conventions

- `allocator` is a `std.mem.Allocator` passed explicitly; **no global allocators**.
- Functions that allocate return errors or own their memory; callers own returned
  slices and must free them.
- All C strings from SQLite are converted with `cStrToSlice` from `database.zig`.
- Error types are narrow enums (e.g. `DatabaseError`, `ExportError`) rather than
  `anyerror`.
- Unit tests live **inline** in each source file; `tests.zig` aggregates them
  with `refAllDecls`.
- SDL2 key constants are declared locally in `ui.zig` using SDL2 scancode
  arithmetic rather than raw integer literals.

---

## Adding features

1. **New query**: add to `database.zig`, test inline, reference in `tests.zig`.
2. **New export format**: add `exportTable…Buf` in `export.zig`; call from CLI
   and/or toolbar.
3. **New UI widget**: implement in `ui.zig`; update `AppState` if state is needed.
4. **New CLI flag**: add to `CliOptions` in `cli.zig`, parse in `parseArgs`,
   handle in `run`.

---

## Building

```bash
# Install deps (Ubuntu)
sudo apt-get install libsqlite3-dev libsdl2-dev libsdl2-ttf-dev

# Build release
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Run
./zig-out/bin/sqlitequery [database.db]
```
