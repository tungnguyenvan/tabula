# Changelog

All notable changes to Tabula are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.13.1] - 2026-10-30

### Changed
- **One Keychain entry for every connection's password**, so macOS asks once and one **Always Allow** covers all of them; each connection used to have its own entry, and its own prompt. An existing entry moves over the first time it is read, which may ask one last time ([#266](https://github.com/tungnguyenvan/tabula/issues/266)).

## [0.13.0] - 2026-10-30

### Added
- **Reorder tabs**: drag a tab onto another to put it there, as in Safari and Finder, or use **Window › Move Tab Left / Move Tab Right** or the tab's context menu. The order is kept with the window's tabs for the next time the connection opens ([#293](https://github.com/tungnguyenvan/tabula/issues/293)).

## [0.12.3] - 2026-10-30

### Fixed
- **MongoDB: saving a document keeps a pre-1970 date's millisecond**: editing, saving in the document editor or duplicating a document with a date such as `ISODate("1969-11-04T18:14:04.439Z")` stored `.440` ([#289](https://github.com/tungnguyenvan/tabula/issues/289)).

## [0.12.2] - 2026-10-30

### Fixed
- SQLite: a value containing a NUL character can be filtered for, inserted and pasted; it used to break the statement with "unrecognized token" ([#286](https://github.com/tungnguyenvan/tabula/issues/286)).
- MongoDB: for a field named like `a.b`, the filter bar's `<`, `>`, `≤` and `≥` also match an array with an element in range, as a query does ([#284](https://github.com/tungnguyenvan/tabula/issues/284)).

## [0.12.1] - 2026-10-30

### Fixed
- **Pasting one column goes into the selected column**: values copied from a single spreadsheet column went into the table's first column (usually `id`) and the commit failed; a one-column header is read as a header too ([#281](https://github.com/tungnguyenvan/tabula/issues/281)).

## [0.12.0] - 2026-10-30

### Added
- **Paste into a table** (⌘V): rows copied from Tabula, Numbers, Excel or Google Sheets become new rows, committed with ⌘S like any other change. When the first line is the header that Copy with Header writes, columns are matched by name; otherwise in order. `NULL` pastes as NULL, and generated columns are left to the server. A single value pasted with a cell selected goes into that cell.

### Fixed
- MongoDB: for a field named like `a.b`, the filter bar's `=`, `≠` and "in" match an element of an array, as a query does ([#276](https://github.com/tungnguyenvan/tabula/issues/276)).

## [0.11.1] - 2026-10-30

### Fixed
- **Beautify keeps a parameter or variable written right after an operator in one piece**: `id=:id` becomes `id = :id`, `x=@v` becomes `x = @v` and `id=?1` becomes `id = ?1`, instead of `id =: id` ([#269](https://github.com/tungnguyenvan/tabula/issues/269)).
- **UTF-16 `.sql` files are saved in the byte order they were read in**; a big-endian file used to come back little-endian ([#271](https://github.com/tungnguyenvan/tabula/issues/271)).
- **MongoDB: a regex ending in `\/`** no longer colours the rest of the line as a comment or stops completion after it ([#273](https://github.com/tungnguyenvan/tabula/issues/273)).

## [0.11.0] - 2026-10-30

### Added
- **Edit SQLite query results**, as on PostgreSQL and MySQL: double-click a cell in a result from one table that includes its primary key, then Commit (⌘S). A row changed since the query ran is reported, not overwritten, and nothing is saved.
- **Stop a running MySQL / MariaDB, SQLite or MongoDB query, or a Redis script** with **Stop** or ⌘., as on PostgreSQL. A statement that never ends, such as a recursive query without a stop condition, no longer leaves quitting Tabula as the only way out ([#141](https://github.com/tungnguyenvan/tabula/issues/141)). The Redis console stops a running script or function (`SCRIPT KILL`, `FUNCTION KILL`, once Redis has let it run 5 seconds) and unblocks a waiting `BLPOP` or `XREAD BLOCK`. On MySQL, Stop sends `KILL QUERY` for that statement only, and on MongoDB `killOp` for that command's operations, each from a short-lived second connection.

### Fixed
- **Tabula no longer quits when a new row disappears from Row Details**: committing a new row, or undoing it, while Row Details showed it closed the app ([#131](https://github.com/tungnguyenvan/tabula/issues/131)).
- **AI chat with Claude Code or Codex no longer hangs on Thinking** ([#80](https://github.com/tungnguyenvan/tabula/issues/80)).
  - Tabula now runs them without your own coding setup: Claude Code's hooks, MCP servers, skills and slash commands, and Codex's MCP servers. On a Mac with several MCP servers, an answer that sometimes took over a minute now takes the model's usual few seconds. Your account and model settings still apply, and Tabula's requests are no longer saved in Claude Code's session history.
  - The prompt no longer goes through your shell's input, where a profile asking a question (such as an update prompt) could take it.
- **Failures that used to look like empty data are now reported** ([#98](https://github.com/tungnguyenvan/tabula/issues/98)):
  - A table's indexes that can't be read show a note under Indexes, instead of looking like a table without indexes; a row count that fails shows "of ?" with the reason.
  - The relationship diagram names tables whose columns couldn't be read.
  - Redis: a failed refresh of one key no longer drops it from the list, and a failed database list keeps the old one and says why.
  - Functions and triggers that can't be listed show the reason in the sidebar.
  - Saved AI chats that can't be read say where they were moved, instead of the history looking empty.
  - `.sql` files in the query library that can't be read are named in the Queries panel.
  - Ollama models that are installed no longer show as not installed when the list can't be read.
  - Restoring with a `mysql` client whose help can't be read reports that, instead of asking you to update the client.
  - Column names that fail to load for completion are tried again rather than remembered as empty.
- **Table filters** ([#122](https://github.com/tungnguyenvan/tabula/issues/122)):
  - Unticking a condition that starts an OR group keeps the OR: `a OR b AND c` without b is now `a OR c`, not `a AND c`.
  - A remembered filter isn't applied after the connection was switched to another database engine, a dropped table's filter isn't applied to a new table of the same name, and a filter saved by a newer version is kept instead of erased.
  - The WHERE label stays on the first ticked condition.
- **Saved query library** ([#122](https://github.com/tungnguyenvan/tabula/issues/122)):
  - Saving under the keyword of a file that couldn't be read no longer overwrites that file.
  - Search matches every word anywhere instead of the whole phrase; the AI chat's search no longer needs the database connection.
  - Linked `.sql` files are listed when they lead inside the library and reported otherwise, and a save can't follow a linked folder out of it.
  - Coming back to Tabula no longer refreshes every query tab when the library hasn't changed.
- **The AI assistant can no longer act on the PostgreSQL server through a read-only query** ([#137](https://github.com/tungnguyenvan/tabula/issues/137)): functions that run SQL given as text (`query_to_xml`, `ts_stat`, `crosstab`) are refused, as are ones that a read-only transaction doesn't stop: advisory locks, statistics resets, WAL switches and replication slots.
- **The AI assistant's MongoDB queries stop after 15 seconds** like its PostgreSQL and MySQL ones, instead of running on the server with no limit ([#139](https://github.com/tungnguyenvan/tabula/issues/139)).
- **The AI assistant's SQLite queries stop after 15 seconds** too ([#141](https://github.com/tungnguyenvan/tabula/issues/141)).
- Running a script no longer splits it inside a PostgreSQL `E'…'` string that contains `\'`, or after a MySQL name that ends in a backslash; highlighting reads them as the server does too ([#144](https://github.com/tungnguyenvan/tabula/issues/144)).
- **PostgreSQL values read as psql shows them** ([#147](https://github.com/tungnguyenvan/tabula/issues/147)):
  - Floats (`NaN`, `Infinity`, `2` rather than `2.0`), BC dates, intervals such as `-1 days +02:00:00`, and arrays whose index doesn't start at 1 now match, so copying, exporting and editing them keeps the value.
  - Ranges, multiranges, geometric types, bit strings, `macaddr8`, `tid`, `pg_lsn`, `xid8`, `tsvector` and `tsquery` show as values instead of hex.
- **MySQL: a query that returns no rows still shows its columns**, instead of an empty grid without headers ([#152](https://github.com/tungnguyenvan/tabula/issues/152)).
- An update download that fails its checks, or is cancelled, no longer leaves the archive and the app it held in the temporary folder.
- The command palette (⌘P) ranks a table whose name has the typed text at a word start higher: “ord” puts `work_order_lines` ahead of `coordinates`.
- Pasting a connection string for another port on the same host no longer keeps the saved password, so it isn't sent to a different server ([#162](https://github.com/tungnguyenvan/tabula/issues/162)).
- A grid cell shows every kind of line break as ⏎, including a lone carriage return, which used to run the lines together ([#167](https://github.com/tungnguyenvan/tabula/issues/167)).
- **Copy log as SQL** gives a script that runs: multi-line error messages stay in their comment, and a statement ending in a `--` comment gets its `;` on the next line ([#169](https://github.com/tungnguyenvan/tabula/issues/169)).
- **Binary values are kept as bytes** ([#171](https://github.com/tungnguyenvan/tabula/issues/171)): MySQL BLOB, BINARY, VARBINARY and BIT values showed as garbled text (`�`), and SQLite blobs were exported and duplicated as text. Bytes now show as `\x` and hex on every database, as psql shows them, and SQL export, Duplicate Row and edits write them back as bytes. Filter by Value on a binary cell finds its row.
- **MongoDB: Duplicate Row and the INSERT export keep every type**: decimals and dates no longer become strings, and a duplicate no longer gains null fields the original lacked ([#175](https://github.com/tungnguyenvan/tabula/issues/175)).
- **SQLite: the filter bar ignores case in any language**: “contains hà nội” now finds “HÀ NỘI”; SQLite’s own LIKE folds only ASCII letters ([#177](https://github.com/tungnguyenvan/tabula/issues/177)).
- **Copy URL** works for a connection to an IPv6 address; it used to copy an empty string ([#179](https://github.com/tungnguyenvan/tabula/issues/179)).
- **MongoDB filter bar** ([#183](https://github.com/tungnguyenvan/tabula/issues/183)): “= true” also finds the string "true", “= 0.1000” finds a NumberDecimal as the grid shows it, and contains / starts with / ends with also match numbers, dates and ids by their text, as on the SQL databases (MongoDB 4.2 or later).
- **MySQL scripts with `DELIMITER` lines run**: the splitter follows the mysql client's `DELIMITER $$ … DELIMITER ;`, so a procedure body keeps its semicolons ([#186](https://github.com/tungnguyenvan/tabula/issues/186)).
- **Redis: renaming a set or sorted-set member onto one that exists is refused**, as for hash fields; it used to merge the members or overwrite the score ([#190](https://github.com/tungnguyenvan/tabula/issues/190)).
- **Redis: the browser's edits no longer capture other commands**: a key scan or row refresh sent while a rename or list removal was in its transaction was queued inside it and got `QUEUED` back ([#192](https://github.com/tungnguyenvan/tabula/issues/192)).
- The Redis console refuses `MULTI` and `WATCH`, which would hold the connection it shares with the key browser; `EVAL` runs several commands at once ([#192](https://github.com/tungnguyenvan/tabula/issues/192)).
- **Redis: a very long TTL no longer quits Tabula**; it's refused as too long ([#197](https://github.com/tungnguyenvan/tabula/issues/197)).
- **A table edit that can't reach its row fails instead of vanishing**: committing an edit or delete of a row someone else deleted meanwhile, or of a MySQL row whose FLOAT key can't be matched exactly, used to report success and save nothing. Now the commit names the row and rolls back ([#203](https://github.com/tungnguyenvan/tabula/issues/203)).
- **The seasonal Dock icon uses 12 MB instead of 64 MB**: Tabula's footprint with a table open is back to about 95 MB during the Halloween season ([#205](https://github.com/tungnguyenvan/tabula/issues/205)).
- **Saving a connection no longer erases connections Tabula couldn't read**: the ones it can read still appear, and the file as it was is kept next to it (`connections.unreadable-….json`), with a message saying where ([#208](https://github.com/tungnguyenvan/tabula/issues/208)).
- VoiceOver names the icon-only buttons (Copy, Send, Stop, Refresh, Export, New Query Tab, Query History and others) instead of reading their symbol or nothing.
- The Halloween icon's dates are Gregorian whatever calendar the Mac shows.
- **Beautify no longer changes what SQL means** ([#244](https://github.com/tungnguyenvan/tabula/issues/244)): numbers such as `1.5e-3`, literals such as `b'01'` and `_utf8mb4'a'`, operators such as `<<`, `->>` and `@>`, parameters and variables (`:name`, `@v`, `?1`) and SQLite's `[my col]` stay as written, and a `;` after a `--` comment no longer ends up inside it.
- **MySQL servers with `NO_BACKSLASH_ESCAPES`**: edits, inserts and SQL exports no longer store a value's backslashes twice, and the filter bar finds `%`, `_` and `\` ([#220](https://github.com/tungnguyenvan/tabula/issues/220)).
- **MongoDB fields named like `a.b` or `$p`** ([#224](https://github.com/tungnguyenvan/tabula/issues/224), [#226](https://github.com/tungnguyenvan/tabula/issues/226)): editing one sets that field instead of the nested `a.b`, and filtering or sorting by one reads that field.
- **Redis: an empty string is a value, not a missing one** ([#258](https://github.com/tungnguyenvan/tabula/issues/258)): the console shows `""` as redis-cli does, previews keep empty items, and the key pane no longer pairs a hash's fields with the wrong values after an empty one.
- **Redis: editing a value in the keys table** only works where the cell shows the whole value; a value with a line break or bytes that aren't text is edited in the key's pane instead of being saved as its one-line preview ([#236](https://github.com/tungnguyenvan/tabula/issues/236)).
- **Duplicate Row works on tables with generated columns**, which it used to copy and the server refused; SQLite's generated columns appear in Structure, and PostgreSQL's Default column says `GENERATED ALWAYS AS …` ([#250](https://github.com/tungnguyenvan/tabula/issues/250)).
- **MySQL spatial values** (GEOMETRY, POINT, …) show as bytes and save back unchanged, instead of garbled text that the server refused ([#230](https://github.com/tungnguyenvan/tabula/issues/230)).
- **Copied rows paste into Numbers and Excel cell for cell**: a value with a tab or a line break is quoted as spreadsheets expect, instead of spilling into new rows ([#256](https://github.com/tungnguyenvan/tabula/issues/256)).
- **SQL INSERT export of a query result** writes into the table the query read (or `results` in the current schema), not `main.results`, which only SQLite has ([#264](https://github.com/tungnguyenvan/tabula/issues/264)).
- **Copy URL no longer quits Tabula** for an IPv6 host with a zone such as `fe80::1%en0` ([#234](https://github.com/tungnguyenvan/tabula/issues/234)).
- **Deeply nested MongoDB text no longer quits Tabula**; past 200 levels it is refused with an error ([#254](https://github.com/tungnguyenvan/tabula/issues/254)).
- **A pasted URL with `ssl=required`** (or a provider profile, or JSON options) keeps TLS on; it used to turn it off ([#242](https://github.com/tungnguyenvan/tabula/issues/242)).
- **The AI assistant's read-only check** refuses PostgreSQL `U&"…" UESCAPE` names and BRIN/GIN index maintenance, which a read-only transaction doesn't stop ([#214](https://github.com/tungnguyenvan/tabula/issues/214)).
- **The Redis console asks before** `REPLICAOF`, `FUNCTION FLUSH`, `CLUSTER RESET`/`FLUSHSLOTS`, `DEBUG` and `FAILOVER`, and on Production before `SLOWLOG RESET` and `LATENCY RESET` ([#216](https://github.com/tungnguyenvan/tabula/issues/216)).
- **The row limit** leaves MySQL's `LOCK IN SHARE MODE` queries runnable and no longer skips a query with a column named `top` ([#212](https://github.com/tungnguyenvan/tabula/issues/212)).
- Running a script keeps a PostgreSQL `BEGIN ATOMIC … END` function body in one statement ([#218](https://github.com/tungnguyenvan/tabula/issues/218)).
- PostgreSQL index columns are listed by name, and an expression such as `coalesce(a, b)` stays one column ([#222](https://github.com/tungnguyenvan/tabula/issues/222)).
- MongoDB documents holding an empty regex, or one with `\/` or a line break, can be edited again ([#228](https://github.com/tungnguyenvan/tabula/issues/228)).
- JSON export keeps every column when a renamed duplicate (`id_2`) matches a real column name ([#232](https://github.com/tungnguyenvan/tabula/issues/232)).
- `.sql` files in Windows-1252 or Latin-1 open, and every file is saved in the encoding it was read in ([#238](https://github.com/tungnguyenvan/tabula/issues/238)).
- SSH tunnels accept IPv6 addresses for the SSH server and the database host ([#240](https://github.com/tungnguyenvan/tabula/issues/240)).
- MongoDB completion offers nothing inside a comment, and offers the collection methods after `db["name"].` ([#246](https://github.com/tungnguyenvan/tabula/issues/246)).
- Searching tables, connections and the command palette ignores accents: “khach” finds “khách_hàng”, “don” finds “đơn_hàng” ([#248](https://github.com/tungnguyenvan/tabula/issues/248)).
- The AI chat reads a tool request whose query contains ` ``` `, and shows a request it can't read instead of an empty answer ([#252](https://github.com/tungnguyenvan/tabula/issues/252)).
- A space or line break around the host no longer makes every connection time out ([#260](https://github.com/tungnguyenvan/tabula/issues/260)).
- Structure gives Columns the room and Indexes a modest share, instead of three rows of columns above an empty index list ([#262](https://github.com/tungnguyenvan/tabula/issues/262)).

## [0.10.0] - 2026-10-29

### Added
- **A library of saved queries** ([#94](https://github.com/tungnguyenvan/tabula/issues/94)).
  - **Query › Save to Library…** (⌥⌘S) saves the selection, or the whole editor, under a keyword and an optional folder. Each query is a `.sql` file in `~/Library/Application Support/Tabula/Queries`, so you can also add and arrange them in Finder; subfolders are groups.
  - **View › Saved Queries** (⌥⌘L) opens the Queries panel: search by keyword, folder or SQL (accents ignored, “đ” matching “d”), double-click to insert at the caret, or Open to edit the file.
  - Type a keyword in the editor and press ⌃Space: the saved query is in the completion list, and choosing it inserts its SQL.
  - The AI chat can search the library too (`search_saved_queries`), so “find my revenue query” works.

### Changed
- This release's icon in Finder and the Applications folder is the Halloween one. The Dock goes back to the regular icon by itself after 1 November.

## [0.9.0] - 2026-10-29

### Added
- **A Halloween icon** ([#109](https://github.com/tungnguyenvan/tabula/issues/109)). From 25 October to 1 November the icon in the Dock and Tabula's logo in its windows dress up with a witch hat, a bat and orange cells, then go back to normal. The icon in Finder doesn't change.

## [0.8.0] - 2026-10-29

### Added
- **Turn filter conditions on and off** ([#106](https://github.com/tungnguyenvan/tabula/issues/106)). Each condition in a table's filter bar has a checkbox. Unticked conditions stay in the bar but are left out when you apply the filter, and the ticks are remembered with it.

## [0.7.1] - 2026-10-29

### Fixed
- A table's filter is no longer lost when its tab, its connection or Tabula is closed. Opening the table again brings back the filter bar's rules (or SQL condition), and a filter that was applied is applied again ([#103](https://github.com/tungnguyenvan/tabula/issues/103)).

## [0.7.0] - 2026-10-29

### Added
- **Dump and restore PostgreSQL and MySQL databases** ([#93](https://github.com/tungnguyenvan/tabula/issues/93)).
  - **File › Dump Database…**, **Dump Table…** in the sidebar, and **File › Restore from Dump…**, with progress and Stop.
  - Uses `pg_dump` / `pg_restore` / `psql` and `mysqldump` / `mysql` (or MariaDB's) installed on the Mac, the newest found; explains how to install them when missing.
  - PostgreSQL restores run in one transaction by default; Production restores ask for the database name. Scripts can't run shell commands on the Mac, and passwords never appear on a command line.

### Fixed
- An SSH tunnel no longer keeps running after Tabula is force-quit or crashes ([#95](https://github.com/tungnguyenvan/tabula/issues/95)).
- When a MongoDB document change fails after an earlier one was saved, the message now reads "The change before it was saved." instead of "The 1 change before it were saved."

### Changed
- The code is split into focused modules (connection models, SQL tooling, one module per database, dump and restore, AI, updates), with no change to how the app behaves ([#98](https://github.com/tungnguyenvan/tabula/issues/98)).

## [0.6.0] - 2026-10-28

### Added
- **SSH tunnels for PostgreSQL and MySQL** ([#83](https://github.com/tungnguyenvan/tabula/issues/83)).
  - **Connect over SSH** in the connection form takes the SSH host, port, user and, optionally, a private key file.
  - Tabula runs `/usr/bin/ssh` with key authentication only (ssh-agent, `~/.ssh` or the chosen file) and trusts only host keys already in `~/.ssh/known_hosts`. Your ssh config isn't read, and nothing SSH-related is stored in the Keychain.
  - The tunnel listens on 127.0.0.1 and closes with the connection or when Tabula quits. TLS to the database still checks the database's own host name.
- **Edit query results on MySQL InnoDB tables** ([#81](https://github.com/tungnguyenvan/tabula/issues/81)).
  - Works for plain one-table SELECTs that include the whole primary key, with aliases and backtick-quoted names.
  - Integer, DECIMAL and text columns can be changed. Keys, generated, binary, date/time, floating-point and BIT columns stay read-only.
  - Commits run in one transaction on a separate connection. Each edited row must still match its old key and old values, and the table must be the same one the query read; otherwise nothing is saved.
  - Tabula needs the PROCESS privilege to prove the table's InnoDB identity. Without it, or for names MySQL stores in encoded form (such as names with hyphens), the result shows **Read-only** with the reason. Session temporary tables stay read-only.
- **Stop a running PostgreSQL query** with **Stop** or ⌘. ([#77](https://github.com/tungnguyenvan/tabula/issues/77)).
  - The server cancels the statement and the rest of the script is skipped. Results finished before Stop are kept.
  - Tabula never commits or rolls back your transaction; a cancelled transaction stays failed until you run `ROLLBACK`.
  - Other databases show Stop as unavailable while their statement finishes.

### Fixed
- Clicking a tab selects it immediately instead of waiting for the double-click interval (~360 ms in the measured local run). Double-click still keeps a preview tab open ([#85](https://github.com/tungnguyenvan/tabula/issues/85)).
- Open tabs keep their content while another tab is shown, instead of being built again on every switch. Returning to a tab now typically appears in 17–67 ms instead of 67–217 ms in a local measurement, and keeps its scroll position, selected rows, caret and keyboard focus ([#85](https://github.com/tungnguyenvan/tabula/issues/85)).
- Table-tab commits and document saves now ask for confirmation on Production connections, including commits from the preview sheet and ⌘S ([#78](https://github.com/tungnguyenvan/tabula/issues/78)).
- Failed data and diagram exports now show an error instead of silently failing ([#79](https://github.com/tungnguyenvan/tabula/issues/79)).
- An AI command-line tool that leaves a background process running no longer keeps the chat waiting until that process exits; Tabula reads the output and finishes shortly after the command itself exits (related to [#80](https://github.com/tungnguyenvan/tabula/issues/80)).

## [0.5.5] - 2026-10-27

### Added
- **Edit query results on PostgreSQL** ([#64](https://github.com/tungnguyenvan/tabula/issues/64)).
  - Double-click a cell in a result from one table that includes its whole primary key.
  - Edits are highlighted and wait for **Commit** (⌘S), **Preview** or **Discard**, as in a table tab; the row details panel edits them too.
  - Changes commit in one transaction on a separate connection, and a row changed by someone else since the query ran is reported instead of overwritten.
  - Joins, views, grouping, functions and computed columns stay read-only, as do key and generated columns.
  - Production connections ask before committing. Running the query again, closing the tab or window, quitting, reconnecting or switching database asks before dropping uncommitted edits.

### Fixed
- Added or clarified help text for icon-only controls, including Open/Save SQL, closing tabs and row value actions. Save SQL explains the distinction between saving query text and committing result edits ([#73](https://github.com/tungnguyenvan/tabula/issues/73)).
- The AI chat now uses a rounded composer with a native scrolling message editor above the model, effort and send controls. Long multiline messages no longer overlap the controls ([#63](https://github.com/tungnguyenvan/tabula/issues/63)).

## [0.5.4] - 2026-10-27

### Added
- **Each connection picks up where you left off** ([#57](https://github.com/tungnguyenvan/tabula/issues/57)).
  - Opening it again brings back its query tabs: their SQL, including unsaved edits, and the `.sql` files they are tied to.
  - It also brings back the open tables (Data or Structure), the selected tab, the schema, the PostgreSQL database the window had moved to, and the query history.
  - Only the selected table loads its rows at once; the others load when selected.
  - Reconnect keeps the tabs too.
  - The state is saved when a connection, its window or Tabula closes, and every few seconds while it changes. A connection that is still connecting, or failed to, never overwrites what was saved.
  - **Reopen tabs when connecting** in Settings › General turns this off and forgets what was kept. Deleting a connection deletes its state.
  - Tabula still never reconnects by itself at launch.

### Fixed
- Saving a connection replaced its Keychain password item, which could discard the permission already granted to Tabula. Tabula now updates the existing item in place and deletes it only when the password is cleared ([#59](https://github.com/tungnguyenvan/tabula/issues/59)).

## [0.5.3] - 2026-10-27

### Fixed
- Tabula could quit unexpectedly in a window that had held SQL and Redis connections in turn, when its last connection was closed or its toolbar changed (macOS 26: "Cannot unregister separator item"). Each window now keeps one sidebar and inspector layout for all its connections ([#53](https://github.com/tungnguyenvan/tabula/issues/53)).
- The Connections window's **New from Connection String…** button wrapped onto three lines; it is now **Connection String…**, on one line ([#50](https://github.com/tungnguyenvan/tabula/issues/50)).
- In the AI chat, an expanded query step showed the rows it returned with their columns run together; they now line up ([#48](https://github.com/tungnguyenvan/tabula/issues/48)).

## [0.5.2] - 2026-10-27

### Added
- **.sql files from the File menu.** **Open…** (⌘O) opens one or more files, each in its own query tab. **Save** (⌘S) writes back to the tab's file and **Save As…** (⇧⌘S) saves a copy under a new name ([#43](https://github.com/tungnguyenvan/tabula/issues/43)).
  - A tab opened from or saved to a file takes its name and shows a dot while it has unsaved edits. Undoing back to the saved text clears the dot.
  - Closing such a tab asks Save, Don't Save or Cancel. Reopening it (⇧⌘T) reads the file again.
  - Opening a file that's already open selects its tab.
  - `.sql` files open from Finder (Open With, or dropped on the Dock icon) into the frontmost connection, or into the next connection to connect. Tabula doesn't make itself their default app.
  - Read and write errors are reported; they used to be ignored.
  - In table tabs, ⌘S still commits and ⇧⌘S still previews the changes.
- **Create a connection from a connection string** ([#45](https://github.com/tungnguyenvan/tabula/issues/45)).
  - **Connection String…** (⇧⌘N) in the Connections window, or paste (⌘V) into the connection list.
  - A summary shows what was read; **Continue** fills in the New Connection form.
  - Besides URLs, Tabula now reads JDBC URLs (with `user` and `password` options), libpq `key=value` strings and semicolon-separated strings (`Server=…;Uid=…`, Npgsql's `Host=…;Username=…`), in this sheet and in the Host field.

### Changed
- Clicking anywhere on a sidebar group's title row now collapses or expands it, and its chevron is always shown, so the count beside it no longer jumps when the pointer passes over ([#41](https://github.com/tungnguyenvan/tabula/issues/41)).

## [0.5.1] - 2026-10-26

### Added
- Collapse and expand the sidebar's groups (Tables or Collections, Views, Functions, Triggers) with the chevron that appears when hovering a group's title, as in Finder ([#36](https://github.com/tungnguyenvan/tabula/issues/36)). Tabula remembers which groups are collapsed; while the filter has text, every group shows its matches.

### Fixed
- Tables in AI chat answers showed as rows of pipes; they now show as tables, with a header row, the columns aligned as the Markdown says, and a sideways scroll when wide ([#27](https://github.com/tungnguyenvan/tabula/issues/27)).

## [0.5.0] - 2026-10-26

### Added
- **The chat assistant uses tools** ([#24](https://github.com/tungnguyenvan/tabula/issues/24)): to answer, it lists tables, describes a table (columns, indexes, foreign keys) and runs read-only queries, and each step shows in the conversation. It works the same with every provider, Claude Code and Codex included; Tabula runs the steps, so no MCP setup is needed. Only reads run (`SELECT`, `EXPLAIN`, MongoDB `find` / `aggregate` / `countDocuments`…), on a separate connection the server keeps read-only, for at most 15 seconds and 50 rows. On Production connections the chat asks before each query. Queries are a setting in Settings › AI: on for new setups, off if you used AI before, so nothing starts sending rows without your say.
- **Conversations are saved** per connection ([#23](https://github.com/tungnguyenvan/tabula/issues/23)): opening the AI panel shows the last one, the title at the top lists earlier ones to open again or delete, and the pencil button starts a new one. They stay on this Mac and are deleted with their connection.

## [0.4.5] - 2026-10-26

### Fixed
- **Zooming the relationship diagram quit the app** (the zoom buttons or a pinch on the trackpad). Keeping the zoom between 30% and 200% re-set the value in a way that repeated without end.
- **The AI chat could show "Thinking…" for minutes, and Stop didn't stop it.** Before asking the model, the chat loaded the columns of up to 300 tables one by one, which on a remote or large database (or MongoDB, where each collection is sampled) took very long, and it couldn't be cancelled. Now the tables a question or the editor's SQL names are loaded first, the rest only for up to 3 seconds; Stop ends the answer at once, so the next message can go out; and the chat says "Reading the schema…" until the request is sent. Ask AI and Fix with AI wait less for the same reason.

## [0.4.4] - 2026-10-26

### Added
- **Open the other databases of a PostgreSQL server** from the same connection: a Database picker above the schema picker in the sidebar lists the databases your login may connect to, and choosing one moves the window there. Query tabs keep their SQL, tabs of the old database's tables close (Tabula asks first if they hold unsaved edits), and the toolbar shows `database.schema`. The saved connection keeps its database. The new database is connected first: if it can't be opened, nothing in the window changes and the sidebar says why. The AI chat starts over in the new database.
- Double-click the empty space below the rows of a table to add a row, as the + button does.

### Changed
- **The app is 61 MB instead of 104 MB once installed**, and the download 24 MB instead of 31. It now ships without symbol tables, which only debuggers use; nothing else changes.

## [0.4.3] - 2026-10-26

### Added
- Paste a connection URL into the Host field to fill in the whole form, password included (`postgresql://`, `mysql://`, `redis://`, `rediss://`, `mongodb://`, `mongodb+srv://`, `file://`, and TablePlus URLs with their name, tag and TLS settings).

### Fixed
- Passwords copied from a dashboard that shows them URL-escaped (`%3F` for `?`, `%7C` for `|`) failed with "authentication failed" ([#11](https://github.com/tungnguyenvan/tabula/issues/11)). The connection form now offers to decode such a password, and a failed login points at the escapes.
- Copy as URL kept too little to paste back the same connection: a Redis connection with TLS but no certificate check now adds `ssl_cert_reqs=none`, a DNS seed list without TLS adds `tls=false`, and a `:` or `@` in the user name is escaped.

## [0.4.2] - 2026-10-26

### Added
- **AI answers stream in** as the model writes them, in the chat panel, Ask AI and Fix with AI, for every provider that can: the Claude API, OpenAI-compatible servers, Ollama, models running in Tabula, Apple Intelligence, Claude Code and Codex.
- Codex shares a summary of its reasoning, shown like the others' thinking; the notes it writes between steps go with it, and only its final message is the answer.
- **The model's thinking** shows above its answer while it reasons, then folds into "Thought for N s" (click to open it again). Claude models send a summary of their reasoning; DeepSeek-R1, Qwen3 and other models that reason in `<think>` tags or a `reasoning` field show theirs too. Ask AI and Fix with AI show the latest line of the reasoning, then of the SQL being written.

### Changed
- Faster MongoDB pages and results, found with the new benchmarks (`scripts/benchmark.sh`, [docs/benchmarks.md](docs/benchmarks.md)): a 5,000-document page loads in 43 ms instead of 136, a 50,000-document result in 0.42 s instead of 1.3, a commit of 100 edits in 25 ms instead of 41. Documents are written as text only when an edit needs them, and dates no longer go through the system's date formatter.
- Reading shell values (the document editor, edits, filters) is 17 times faster; dates were parsed by trying several formatters.
- PostgreSQL pages with date and timestamp columns are about 15% faster.

### Fixed
- **The app could quit unexpectedly with the AI or Row Details panel open**, typically when sending a chat message or dragging a divider: SwiftUI's split views (query editor and results, console, structure, Redis) and the panel kept asking the window to recompute constraints until AppKit stopped the app. These split views are now AppKit's own, and remember where you put the divider.
- Running a script whose last result had different columns and fewer rows than the first could quit the app.
- A MongoDB connection through a DNS seed list showed a port in the connection list; it now says "DNS seed list".
- PostgreSQL dates before 15 October 1582 showed in the Julian calendar, days off from what the server stores and `psql` shows; they now show in the proleptic Gregorian calendar, as PostgreSQL counts them.

## [0.4.1] - 2026-10-25

### Security
- Running a statement from the editor could split a table or collection name into two statements when the name began with a combining accent (for example U+0301 right after the opening quote). A crafted name created by another database user could then run a command of its own, such as creating a user, when "New Query" was run from its context menu. Statements are now split by Unicode scalar, so names always stay inside their quotes. This affected SQL databases as well as MongoDB.
- MongoDB seed lists (`mongodb+srv`) are now resolved with the Mac's own resolver, and every server they name must be in the seed's domain. Previously a spoofed DNS answer could send the connection to another host with a valid certificate of its own.
- Fix with AI no longer sends values from MongoDB errors (the existing document in a duplicate key, quoted values) to the AI provider.

### Fixed
- A MongoDB replica set or seed list whose first member is down now connects through the next one.
- MongoDB connection errors read "host:port: Connection refused" instead of a nested error structure.

### Changed
- README: sizes and memory use measured on 0.4.0, in decimal megabytes.

## [0.4.0] - 2026-10-25

### Added
- **MongoDB connections**: host and port, replica set member lists, Atlas DNS seed lists (`mongodb+srv`), TLS, SCRAM authentication with an auth database. Copy Connection URL gives a `mongodb://` URL.
- Databases in the sidebar's picker; collections and views as tables. Documents in the data grid, `_id` first, nested values inline, BSON types in Row Details.
- Filtering: the filter builder writes the query document (numbers and ids match as typed or as text, text operators are case-insensitive, nested paths such as `address.city`), or write one by hand with `{ }`. Sorting, paging and a total count.
- Editing keeps field types: a long stays a long, a date a date, a decimal a decimal. Commit sends `updateOne` / `deleteOne` / `insertOne` by `_id`, previewed with ⇧⌘S. A JSON document editor edits a whole document or inserts a new one.
- The query editor runs MongoDB shell statements (`find`, `aggregate`, `countDocuments`, `distinct`, inserts, updates, deletes, `findOneAnd…`, indexes, `runCommand`, `show dbs`, `use`, …) with the shell's value syntax (`ObjectId`, `ISODate`, `NumberLong`, `NumberDecimal`, `UUID`, regular expressions, Extended JSON). Highlighting, Beautify, completion of collections, methods, fields and `$` operators, and the row limit as `.limit()`.
- Structure shows fields sampled from the first 100 documents with the types seen, and indexes with their options.
- Server metrics from `serverStatus` and `dbStats`, including the largest collections.
- AI chat, Ask AI and Fix with AI write MongoDB shell commands for MongoDB connections, from collection and field names (never documents).

### Changed
- The relationship diagram and functions and triggers are hidden where a database has none (MongoDB).

## [0.3.1] - 2026-10-25

### Added
- **Functions, procedures and triggers** in the sidebar (PostgreSQL, MySQL; triggers on SQLite): view, edit and save the definition, create new ones from a template, delete. Saving never loses a routine: transactional where the database allows, and on MySQL the original is restored if the new definition fails.
- AI: an **Effort** setting for models that reason (Claude Opus / Sonnet / Haiku 5.5, Claude Code, Codex, OpenAI reasoning models), in the chat panel and in Settings. Suggestions while typing always use the quickest.
- AI: **editable system prompts** for chat, Ask AI, Fix with AI and suggestions (Settings › AI › Instructions, or the chat's menu).

### Fixed
- Scripts containing `CREATE TRIGGER`, `CREATE PROCEDURE` or `CREATE FUNCTION` with a `BEGIN … END` body (SQLite, MySQL) are no longer split at the semicolons inside the body.

## [0.3.0] - 2026-10-25

### Added
- **AI assistant**, off until turned on in Settings › AI:
  - **AI chat** in the panel on the right (⌥⌘A): a conversation per connection, aware of the schema and the editor's SQL; queries in answers can be inserted, run or copied. A model menu under the message field switches models.
  - With AI suggestions on, the grey suggestion comes from the model only. Models on this Mac complete by filling in the middle (prefix and suffix around the cursor), answer in well under a second, and stop on runaway repetition.
  - **Models that run inside Tabula** (llama.cpp), with nothing else to install: light models to download from Settings (checked by SHA-256), any GGUF file added from disk or from a link, per-purpose use and delete. GPU on Apple silicon, CPU on Intel.
  - **Ask AI** (⌘K): write SQL from a description, or change the selected SQL. The result is inserted (or replaces the selection) and can be undone.
  - **Fix with AI** under a failed statement.
  - **Suggestions while typing** written by the model; Tab accepts. They can use their own provider, such as a small model on this Mac, while Ask AI uses Claude Code or an API.
  - The model is told schema-qualified table names, column types, primary and foreign keys.
  - Providers: **Apple Intelligence** on the Mac; **local models through Ollama**, with light recommended models to pull, progress, and per-purpose use or delete in Settings; any **OpenAI-compatible API** (LiteLLM, LM Studio, OpenAI…); the **Claude API**; the installed **Claude Code** and **Codex** command-line tools.
  - Only table and column names and the SQL near the cursor are sent, never rows. Off for Production connections unless allowed. API keys are kept in the Keychain.
- Settings has General and AI tabs and reopens on the last one used; each AI provider keeps its own address, models and key.
- A fuller About Tabula, readable in Dark Mode.

### Fixed
- Picking a schema (Postgres) or database (MySQL) in the sidebar now makes it the default for queries, so unqualified names no longer fail with "relation does not exist".
- An apostrophe in a SQL comment no longer colors the following lines as a string; highlighting follows the database's comment and quoting rules.
- Column suggestions could come from the wrong schema when the schema changed while names were loading, or when a schema name was mistyped.
- An alias with the same name as a schema now completes the alias's columns.
- Deleting forward no longer brings back a stale grey suggestion.

## [0.2.1] - 2026-10-25

### Added
- SQL suggestions after a schema name: `FROM sales.` offers that schema's tables (loaded in the background if it isn't the one selected in the sidebar), and `alias.` offers the columns of tables in any schema, including `schema.table.`.
- Columns of every table are suggested before the statement names one (`SELECT na…` before the `FROM`).
- Right after `alias.` or `schema.`, the first column or table is offered in grey; Tab accepts it.

### Changed
- One **Run** button (the selection, or the statement at the cursor) with **Run All Statements** in its menu, instead of two buttons.
- Release builds can be signed with a fixed local certificate (`scripts/make-signing-identity.sh`), so macOS stops asking for Keychain access after every update.

### Fixed
- macOS's own word suggestions and grey predictions no longer appear in the SQL editor on top of Tabula's.
- Windows can be made narrow again: a long row in the console or a result no longer forces a minimum width larger than the screen. Console rows are a single line, cut to fit, with the full statement in the tooltip.
- The line-number column of the SQL editor no longer draws a line through the toolbar above it.
- Suggestions appear as soon as table or column names finish loading, without another keystroke.

### Notes
- 0.2.1 is the first release signed with a fixed certificate. Updating from 0.2.0, macOS asks once more whether Tabula may use the saved passwords; choose **Always Allow**. Later updates won't ask again.

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
- SQL editor: suggestions as you type (tables after `FROM`/`JOIN`, columns after `alias.`, keywords), shown inline (Tab accepts) and in the completion list (⎋ or ⌃Space); **Beautify** (⇧⌘I); a row **Limit** for SELECTs without one; Run Current / Run All buttons.
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

[Unreleased]: https://github.com/tungnguyenvan/tabula/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/tungnguyenvan/tabula/releases/tag/v0.3.1
[0.3.0]: https://github.com/tungnguyenvan/tabula/releases/tag/v0.3.0
[0.2.1]: https://github.com/tungnguyenvan/tabula/releases/tag/v0.2.1
[0.2.0]: https://github.com/tungnguyenvan/tabula/releases/tag/v0.2.0
[0.1.0]: https://github.com/tungnguyenvan/tabula/releases/tag/v0.1.0
