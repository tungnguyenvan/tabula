# Changelog

All notable changes to Tabula are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Planned
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
- Settings window (⌘,).

### Changed
- Keychain access no longer blocks the interface while macOS shows a permission prompt.

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
