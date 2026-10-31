# Browsing and editing data

[Back to the README](../README.md)

- [Browsing](#browsing)
- [Filtering](#filtering)
- [Editing and committing](#editing-and-committing)
- [Pasting rows](#pasting-rows)
- [Copying and exporting](#copying-and-exporting)
- [Tables without a primary key](#tables-without-a-primary-key)
- [Editing query results](#editing-query-results)
- [Importing files](#importing-files)

<p align="center"><img src="screenshots/data.png" width="820" alt="Filtering a table, with the row details panel open"></p>

## Browsing

- **Schema or database switcher** in the sidebar. The one you pick also becomes the default for queries, so `transactions` finds `dev.transactions`.
- **Table list** you can filter (⌥⌘F), with collapsible groups (Tables or Collections, Views, Functions, Triggers); Tabula remembers which are collapsed, and while the filter has text every group shows its matches. Searching tables, connections and the command palette ignores case and accents: "cafe" finds "café".
- **Tabs:** arrow keys preview tables in one reusable tab; Return or a double-click keeps one open. Drag tabs to reorder them, or use **Move Tab Left / Move Tab Right** in the View menu or the tab's context menu; the order is kept for the next time the connection opens. ⌘P jumps to any table, tab or action.
- **Grid:** pages of 100 to 5,000 rows with a total count, server-side sorting, row numbers and spreadsheet-style keys. Space opens a quick look at a long or JSON value. Double-click the empty space below the rows to add a row.

## Filtering

- **Builder:** conditions joined with AND or OR. Each condition has a checkbox: unticked ones stay in the bar but are left out when you apply the filter, and the ticks are remembered with it.
- **SQL:** a `WHERE` clause written by hand.
- **Filter by This Value** on a cell.
- Each table remembers its filter, applied again when you open the table again, even after closing the tab, the connection or Tabula.
- With AI on, [describe the rows](ai.md#filter-by-description) in words instead.

## Editing and committing

Edit in the grid or in the row details panel (⌥⌘0): set NULL or empty text, add, duplicate and delete rows. Undo and redo work per tab.

- **Nothing is written until you commit.** Changes are highlighted. ⇧⌘S previews the exact SQL (the first 1,000 statements of a large change; **Copy SQL** copies them all), and ⌘S runs every change in one transaction and rolls back if any statement fails. Production connections ask before the commit.
- A commit that can't reach one of its rows, such as a row someone else deleted meanwhile, names the row and rolls back.
- Sorting, filtering, paging or closing a tab asks first if it would throw away uncommitted edits.
- Duplicating a row leaves its primary key, and generated columns, to the server.

## Pasting rows

⌘V pastes rows copied from Tabula, Numbers, Excel or Google Sheets as new rows, committed with ⌘S like any other change.

- When the first line is a header, such as the one Copy with Header writes, columns are matched by name; otherwise in order.
- `NULL` pastes as NULL (a quoted `"NULL"` is the text), and generated columns are left to the server.
- A single value pasted with a cell selected goes into that cell; values from a single column go into the selected column.

## Copying and exporting

- Copy rows as TSV (⌘C), with column names (⌥⇧⌘C), or a single cell (⌥⌘C). A value with a tab or a line break is quoted, so rows paste into Numbers and Excel cell for cell.
- Export CSV, TSV, JSON or SQL `INSERT`, to a file or the clipboard. CSV and TSV exports quote empty text and the text `NULL`, so they can be told from NULL (an empty field) when imported again.
- Binary values show as `\x` and hex, as psql shows them, on every database, and are saved back as bytes by edits, Duplicate Row and SQL export.

## Tables without a primary key

Rows are found by the shortest unique index whose columns are all NOT NULL, or else by SQLite's `rowid` or PostgreSQL's `ctid`. The bottom bar says which ("Rows identified by ctid").

- A `ctid` changes when its row is updated, so editing or deleting a row someone changed since the page loaded fails the commit and nothing is saved; the page reloads after each commit.
- A MySQL / MariaDB table with no such index stays read-only apart from adding rows, and the bottom bar says so.
- Duplicating a row leaves its identifying unique columns empty, as it does a primary key.
- SQLite's `VACUUM` can renumber the `rowid` of a table without an `INTEGER PRIMARY KEY`; reload an open table after running one before editing it.

## Editing query results

Double-click a cell in a result from one table that includes its whole primary key, such as `SELECT id, name, price FROM products` (PostgreSQL, MySQL InnoDB, SQLite). Edits wait for **Commit** (⌘S), **Preview** or **Discard**, as in a table tab; the row details panel edits them too.

- Changes commit in one transaction on a separate connection, and a row someone else changed since the query ran is reported, not overwritten. Production connections ask first. Running the query again, closing the tab or window, quitting, reconnecting or switching database asks before dropping uncommitted edits.
- Joins, views, grouping, functions and computed columns stay read-only, as do key and generated columns. Results must include the whole primary key: a unique index or `ctid` isn't used here.
- **MySQL:** integer, DECIMAL and text columns, when Tabula can prove the InnoDB table's identity (this needs the PROCESS privilege). Otherwise, and for temporary tables or names MySQL stores encoded (such as names with hyphens), the result says **Read-only** and why. Triggers run normally, but their non-transactional side effects can't be rolled back.
- **SQLite:** INTEGER, REAL, NUMERIC and text columns; BLOB, untyped and generated columns, views and virtual tables stay read-only.
- The table's identity is captured when the result is checked for editing, not atomically with the SELECT, so an identical replacement in between can't be told apart.

## Importing files

**File › Import…** in a table tab, or **Import…** in the sidebar's context menu (PostgreSQL, MySQL, SQLite). Columns are matched by name (ignoring case, accents, spaces, `_` and `-`), and you can pick another or skip one; a header row is detected and can be turned off, and the first rows are previewed. The rows become new rows in the grid, committed in one transaction with ⌘S, after a preview with ⇧⌘S if you like.

- **CSV and TSV** as RFC 4180 writes them, in UTF-8 (with or without a byte order mark), UTF-16 with one, or Windows-1252. An empty field is NULL where allowed (else the column's default, or empty text); `""` is empty text and unquoted `NULL` is NULL. Tabula's exports quote empty text and the text `NULL`, so they import back unchanged.
- **JSON:** an array of objects. Numbers keep every digit, nested values become JSON text, `null` is NULL, and a missing field takes the column's default.
- Up to 100,000 rows and 256 MB per file; larger files are refused. Generated columns are left to the database.
- Files can't be imported into MongoDB collections yet.
