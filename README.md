# SQLite Query Analyzer

A fast and lightweight cross-platform tool for querying and manipulating SQLite databases, written in [Zig](https://ziglang.org/) with an immediate-mode GUI powered by [raylib](https://www.raylib.com/).

[![CI](https://github.com/christianhelle/sqlitequery-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/christianhelle/sqlitequery-zig/actions/workflows/ci.yml)
[![Release](https://github.com/christianhelle/sqlitequery-zig/actions/workflows/release.yml/badge.svg)](https://github.com/christianhelle/sqlitequery-zig/actions/workflows/release.yml)

This is a Zig rewrite of the original [SQLite Query Analyzer](https://github.com/christianhelle/sqlitequery) (C++/Qt), designed for maximum performance using an immediate-mode rendering approach.

## Features

- **GUI Mode**: Immediate-mode GUI with dark/light themes using raylib/raygui
  - Database schema browser (tree view)
  - SQL query editor with execution timing
  - Query results table with alternating row colors
  - Table data preview on click
  - File open dialog
  - Session persistence (remembers last database and query)
  - Keyboard shortcuts (Ctrl+O, Ctrl+E, Ctrl+Enter/F5, Ctrl+D, Ctrl+Q)
- **CLI Mode**: Full command-line interface for scripting and automation
  - Execute SQL scripts against databases
  - Export all table data as CSV files
  - Export database schema as SQL CREATE TABLE statements
  - Export data as SQL INSERT statements
- **Database Operations**:
  - Open and query SQLite databases
  - Analyze database schema (tables, columns, types, constraints)
  - Compact databases (VACUUM)
- **Performance**: Written in Zig with zero garbage collection, immediate-mode rendering at 60fps
- **Cross-platform**: Linux (with potential for macOS and Windows support)

## Installation

### Build from source

Requires [Zig 0.15.2+](https://ziglang.org/download/) and system dependencies:

```sh
# Install system dependencies (Ubuntu/Debian)
sudo apt-get install -y libsqlite3-dev libglfw3-dev libgl1-mesa-dev \
  libx11-dev libxrandr-dev libxi-dev libxinerama-dev libxcursor-dev

# Install raylib (pre-built release)
curl -sL https://github.com/raysan5/raylib/releases/download/5.5/raylib-5.5_linux_amd64.tar.gz | \
  sudo tar xzf - -C /tmp && \
  sudo cp /tmp/raylib-5.5_linux_amd64/lib/* /usr/local/lib/ && \
  sudo cp /tmp/raylib-5.5_linux_amd64/include/* /usr/local/include/ && \
  sudo ldconfig

# Install raygui header
sudo curl -sL https://raw.githubusercontent.com/raysan5/raygui/master/src/raygui.h \
  -o /usr/local/include/raygui.h

# Build
zig build -Doptimize=ReleaseFast
```

The binary is at `zig-out/bin/sqlitequery`.

### Snap

```sh
sudo snap install sqlitequery
```

### Download from GitHub Releases

Pre-built binaries for Linux (x86_64) are available on the [Releases](https://github.com/christianhelle/sqlitequery-zig/releases) page.

## Usage

### GUI Mode

```sh
# Open the GUI
sqlitequery

# Open a specific database
sqlitequery database.db
```

### CLI Mode

```sh
# Show help
sqlitequery --help

# Export all tables as CSV
sqlitequery --export-csv database.db

# Export with progress and custom output directory
sqlitequery --export-csv --progress --target-directory ./export database.db

# Export database schema
sqlitequery --export-schema database.db

# Export data as SQL INSERT statements
sqlitequery --export-data --target-directory ./export database.db

# Execute a SQL script
sqlitequery --run-sql script.sql database.db
```

### Keyboard Shortcuts (GUI)

| Shortcut | Action |
|---|---|
| `Ctrl+O` | Open database file |
| `Ctrl+E` | Focus query editor |
| `F5` / `Ctrl+Enter` | Execute query |
| `Ctrl+D` | Toggle dark/light theme |
| `Ctrl+Q` | Quit |

### CLI Options

```
Usage: sqlitequery [options] [database]

Options:
  -h, --help              Display this help and exit
  -v, --version           Display version information and exit
  -p, --progress          Show progress during export
  -e, --export-csv        Export all tables to CSV files
  -d, --target-directory   Target directory for export (default: current directory)
  -r, --run-sql           Execute SQL file against the database
  -s, --export-schema     Export database schema as SQL
  --export-data           Export data as SQL INSERT statements
```

## Development

### Running tests

```sh
zig build test
```

### Project structure

```
src/
├── main.zig         # Entry point
├── cli.zig          # CLI argument parsing and command dispatch
├── database.zig     # SQLite3 wrapper via @cImport
├── analyzer.zig     # Database schema analysis
├── export.zig       # CSV, SQL, and schema export
├── settings.zig     # Session and window state persistence
├── gui.zig          # Immediate-mode GUI (raylib/raygui)
└── raygui_impl.c    # raygui header-only implementation
```

## License

MIT
