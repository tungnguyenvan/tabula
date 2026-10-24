# Changelog

All notable changes to Tabula are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Planned
- AI assistant: write and fix queries, AI suggestions as you type; Apple Intelligence, local models via Ollama, OpenAI-compatible APIs (LiteLLM), the Claude API, Claude Code and Codex
- SSH tunnels
- Cancelling a running query

## [0.2.0] - 2026-10-25

### Added
- **Redis** connections (Redis 6 and 7, including managed services): password or ACL user, database index, TLS.
  - Key browser with `SCAN` (never `KEYS`): pattern filter, type filter, natural sorting, incremental loading for large keyspaces, database switcher with key counts.
  - Viewers and editors for every type: strings (with JSON formatting; large and binary values are shown read-only), hashes, lists, sets, sorted sets and streams, with paging for big collections. Edits are saved immediately; multi-step edits (renaming a hash field, changing a set member) run in `MULTI`/`EXEC`.
  - Key details: size, memory usage, encoding and TTL; set or remove expiry, rename (never overwrites), create and delete keys.
  - Console that works like `redis-cli`: quoting and escapes, formatted replies, history, follows `SELECT`. It refuses commands that would hang the connection (`SUBSCRIBE`, `MONITOR`, blocking calls without a timeout) and asks before `FLUSHALL`/`FLUSHDB`/`SHUTDOWN`, and before any write on Production connections.
- **Software updates**: Tabula checks GitHub for a new release at most once a day (can be turned off in Settings) and from **Tabula › Check for Updates…**. With one click it downloads the release, verifies its SHA-256 checksum, bundle identifier, version and code signature, replaces itself and relaunches. If anything fails, the current version is kept.
- **Several connections in one window**: opening another connection adds it to the current window; with two or more, a column left of the sidebar lists them (hover for details, click or ⌃⌘] / ⌃⌘[ to switch). The connection pill in the toolbar shows details on click.
- **Console log** (⇧⌘C): every statement sent to the server, with time, rows and duration; copy as SQL.
- **Relationship diagram** (⌥⌘3) from foreign keys, with dragging, zoom and PNG export.
- **Server metrics** (⌥⌘4) for PostgreSQL, MySQL, SQLite and Redis, with live charts.
- SQL editor: suggestions as you type (tables after `FROM`/`JOIN` and `schema.`, columns after `alias.`, keywords), shown inline (Tab accepts) and in the completion list (⎋ or ⌃Space); **Beautify** (⇧⌘I); a row **Limit** for SELECTs without one; one Run button (selection or current statement) with Run All in its menu.
- Filters: AND or OR between conditions.
- Copy a connection as a URL, with or without the password.
- The Connections window can be moved by dragging its left pane.
- Settings window (⌘,).

### Changed
- Redis: databases are in the sidebar and keys, with type, TTL, size and value, are in the main table.
- Keychain access no longer blocks the interface while macOS shows a permission prompt, and each password is read once per launch.
- Tabs share the width of the bar (120–220 points each) and scroll when there are many.
- "Copy with Column Names" in the grid moved to ⌥⇧⌘C (⇧⌘C is the console log).

### Fixed
- Sorting, filtering, paging or changing the page size no longer silently discards uncommitted edits; Tabula asks first.
- The Commit button is disabled while a commit runs, so changes can't be applied twice.
- A slow page load can no longer overwrite the result of a newer one (tables and Redis key scans).
- The tab bar and other bars no longer paint up under the toolbar.
- The Software Update window no longer reopens by itself at launch.
- Keychain writes run in order and report failures instead of failing silently.
- Postgres: malformed binary values (numeric, interval, arrays) can no longer crash the app.
- Redis: an aborted `MULTI`/`EXEC` is reported; `WAIT` with a timeout is no longer refused; on Production, writes missing from the old list (`SETEX`, `HINCRBY`, …) now ask for confirmation.
- JSON export keeps every column when a query returns two columns with the same name.
- The updater can no longer hang on a tool that writes a lot to its error output.

### Notes
- Version 0.1.0 has no updater. Install 0.2.0 manually once; later versions can be installed from inside the app.

## [0.1.0] - 2026-10-24

First public release.

### Added
- Native macOS app (SwiftUI + AppKit) for **PostgreSQL**, **MySQL / MariaDB** and **SQLite**; universal binary for Apple silicon and Intel, macOS 14 or later.
- Saved connections with Local / Development / Staging / Production tags (colored banner and toolbar pill), passwords in the macOS Keychain, TLS (disabled / required / verified), connection test, 15-second connect timeout.
- Workspace per connection: schema / database switcher, table and view list with filter, equal-width tabs, preview tab while browsing the sidebar, reopen closed tab, command palette (⌘P).
- Data grid: paging (100–5000 rows), total row count, server-side sorting, visual filter builder or raw `WHERE`, filter by cell value, row numbers, quick look for long and JSON values, copy as TSV (with or without headers) or single cell.
- Editing: in-grid and row-inspector editing, NULL / empty values, add / duplicate / delete rows, per-tab undo and redo, SQL preview, commit in one transaction with rollback on error, confirmation before closing a tab with uncommitted changes.
- Structure view: columns (type, nullability, default, comment, primary key) and indexes with definitions.
- SQL editor: syntax highlighting, line numbers, run selection or the statement at the cursor (⌘↩), run all (⇧⌘↩), multi-statement results, toggle comments (⌘/), table / keyword completion, query history, open and save `.sql` files.
- Export to CSV, TSV, JSON and SQL `INSERT`, to a file or the clipboard.
- Keyboard shortcuts for every common action, listed under Help ▸ Keyboard Shortcuts (⇧⌘/).

### Known limitations
- MySQL `SELECT`s returning zero rows show no column headers.
- Running queries cannot be cancelled.
- No SSH tunnelling yet (use `ssh -L` and connect to the local port).
- Release builds are ad-hoc signed and not notarized; macOS asks for confirmation on first launch (see the README).
- Connecting to a database on the local network asks for Local Network permission on macOS 15 and later.

[Unreleased]: https://github.com/tungnguyenvan/tabula/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/tungnguyenvan/tabula/releases/tag/v0.2.0
[0.1.0]: https://github.com/tungnguyenvan/tabula/releases/tag/v0.1.0
