# SQLite Query Analyzer

[![Build](https://github.com/christianhelle/sqlitequery-zig/actions/workflows/build.yml/badge.svg)](https://github.com/christianhelle/sqlitequery-zig/actions/workflows/build.yml)

A fast, cross-platform SQLite database query analyzer and browser written in
[Zig](https://ziglang.org/) using an SDL2 immediate-mode GUI.  
Full-feature Zig rewrite of the original
[C++/Qt SQLite Query Analyzer](https://github.com/christianhelle/sqlitequery).

## Features

- **Immediate-mode SDL2 GUI** — dark-themed, fully redrawn every frame for
  maximum responsiveness
- **SQL query editor** — multi-line with cursor, scrolling and Ctrl+Enter to execute
- **Table browser** — sidebar with all tables; click to `SELECT *` instantly
- **Data grid** — scrollable, alternating-row result table with column headers
- **Schema viewer** — full `CREATE TABLE` DDL for all tables
- **CSV export** — one file per table, correctly quoted
- **SQL script execution** — run `.sql` files from the CLI
- **Session persistence** — last database path, query and window size restored on startup
- **Headless CLI mode** — no GUI required for scripting and automation

## Build

```bash
# Install dependencies (Ubuntu / Debian)
sudo apt-get install libsqlite3-dev libsdl2-dev libsdl2-ttf-dev

# Build (requires Zig 0.15.x)
zig build

# Optimized release build
zig build -Doptimize=ReleaseFast

# Run unit tests
zig build test
```

## Usage

### GUI mode

```bash
./zig-out/bin/sqlitequery /path/to/database.db
./zig-out/bin/sqlitequery          # opens welcome screen
```

### CLI / headless mode

```bash
# Show help
sqlitequery --help

# Export all tables as CSV
sqlitequery --export-csv --target-directory /tmp/export mydb.sqlite

# Execute a SQL script
sqlitequery --run-sql schema.sql mydb.sqlite

# Show progress during export
sqlitequery -p -e -d /tmp/export mydb.sqlite
```

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| Ctrl+Enter | Execute query |
| Click table in sidebar | `SELECT *` from that table |
| Backspace / Delete | Edit query |
| Tab | Insert 4 spaces |
| Enter | New line in query |
| Escape | Close open dialog |

## Snap packaging

This application is packaged as a [snap](https://snapcraft.io/) for Ubuntu.

```bash
snapcraft
sudo snap install sqlitequery_*.snap --dangerous
```

## License

MIT
