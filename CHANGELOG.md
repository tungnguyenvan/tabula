# Changelog

All notable changes to Tabula are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.22.2] - 2026-11-07

### Fixed
- **Grids scroll with half the work.** Every cell of a grid was a text field, with its own layout constraints and layer, so each cell that scrolled into view was laid out and drawn through a whole text field, and the constraints made SwiftUI lay out the window again. Cells now draw their value themselves, exactly as the text field did (same position, truncation and tightening, NULL in italics, the selection's colors, links, edited, deleted and new rows, light and dark), and add a text field only while a value is edited; VoiceOver reads them as before. The table already reused its cells: after the first frames of scrolling no cell is made. Scrolling 100,000 rows takes 8.6 ms of main thread per scroll event instead of 14.5 ms, with 5 ms of late frames instead of 33 ms; scrolling the grids of the nine-tab window takes 7.5 ms per event instead of 11.0 ms, with 55 ms of late frames instead of 124 ms. Showing a 100,000-row result, sorting and filtering take 40 to 50% less main-thread time, with their longest frame about half as long, and the app uses about 30 MB less memory with nine tabs open ([#364](https://github.com/tungnguyenvan/tabula/issues/364)).
- **Switching tabs does less, and so does opening Row Details.** A closed Row Details panel went on following every tab switch and row selection unseen, building the row's fields again each time; it now keeps what it showed and reads the tab shown again when it opens. Switching tabs no longer evaluates the whole sidebar again (only its highlight follows the tab), the keyboard moves straight to the tab shown instead of leaving the old one first (which made SwiftUI go through the window's focusable views twice per switch), and the window sets only what a switch changes. Opening or closing Row Details no longer evaluates the window's toolbar and tab bar again, and the tab bar works out its tabs again only when their width changes, not at each step of the panel sliding in or of a window resize. With nine tabs, 18 switches take 0.82 s of main thread instead of 1.09 s, with 0.38 s of late frames instead of 0.67 s and the longest frame 58 ms instead of 86 ms; opening and closing Row Details three times takes about the same main-thread time as before (1.3 s, mostly AppKit's split animation), with 0.20 s of late frames instead of 0.23 s, and opening it after switching tabs builds the row's fields then, once ([#362](https://github.com/tungnguyenvan/tabula/issues/362), [#363](https://github.com/tungnguyenvan/tabula/issues/363)).
- **An AI answer streams in without holding up the window.** Each piece of an answer that arrived redrew the whole chat: every message, the panel around them, and the answer itself from the start, its text split into blocks again, the Markdown of every paragraph read again and its table rebuilt. Now only the answer being written is drawn again; blocks it already finished stay as they are, a paragraph that is still growing is drawn by itself instead of with the whole block around it, inline Markdown is read once for each text (and not at all for plain table cells), and a long answer is redrawn a little less often than a short one. Text that arrives just before the model pauses now shows at once instead of when the next piece comes. The cells of a Markdown table can be selected once the answer is complete, a few rows at each frame, as making hundreds of cells selectable while the table grows cost more than drawing it. For the 9 KB answer with a 96-row table of the performance check, the main thread works 1.6 s instead of 3.7 s while it arrives, with 39 late frames (0.7 s) instead of 83 (2.0 s), and SwiftUI evaluates 98 view bodies instead of 330; scrolling the finished answer is unchanged ([#361](https://github.com/tungnguyenvan/tabula/issues/361)).

## [0.22.1] - 2026-11-07

### Added
- **Performance measurements before each release.** `scripts/perf.sh` plays the same scenarios on an optimized build every time (a window with nine tabs: switching, scrolling, typing, resizing and Row Details; a 100,000-row result: loading, scrolling, sorting and filtering; an AI answer with a long Markdown table streamed by a fake model; five idle connections; launch to the first rows on PostgreSQL) and reads from inside the app the CPU time, main-thread time, hitches (frames held up past 16.7 ms), memory footprint, threads and SwiftUI body evaluations of each phase. It reports the median and spread of 3 runs and compares them with a baseline kept in the repository, `docs/perf-baseline.json`; `scripts/release.sh` runs it after the tests and stops when a figure got worse than its margin (`SKIP_PERF=1` skips it). The measuring code is in debug builds only, so the app you install doesn't carry it. [How it measures](docs/performance.md) ([#359](https://github.com/tungnguyenvan/tabula/issues/359)).

### Fixed
- **Resizing a window with many tabs is smooth again.** On macOS 26 every grid and editor of every tab in the background stayed known to the window's toolbar, which checked again where each one lay at every step of a resize, so each step took longer the more tabs were open. Tabs in the background now leave the window when its size changes (resizing it, showing the sidebar or Row Details) and come back as they were, with their text, Undo, selection, scroll position and keyboard focus, and a query running in one still finishes and shows. Switching back and forth between tabs without resizing doesn't draw them again. The tab bar also stops working out every tab again at each step. Resizing a window with nine tabs takes 2.8 s of main thread instead of 13.5 s (120 steps), with 0.7 s of late frames instead of 11.1 s; opening and closing Row Details takes 1.3 s instead of 2.2 s ([#360](https://github.com/tungnguyenvan/tabula/issues/360)).

## [0.22.0] - 2026-11-06

### Added
- **Always Allow for AI's reads on Production.** The question before a read-only AI query on a Production connection now offers **Don't Allow**, **Allow Once** (as before) and **Always Allow**, as macOS asks for permissions. Always Allow runs the query and lets later read-only queries on that connection run without asking. It is saved per connection and separately for **AI in Tabula** (the chat's queries, its code blocks, charts and forms, notebooks and dashboards) and **agents over MCP**, whose alert gets the same three buttons, so allowing one doesn't allow the other. Nothing else changes: each query still passes the read-only check and runs read-only with the time limit and row limits, in the console log, and writes and schema changes are refused. While it is on, the chat's description says so with **Ask Before Each Query**, the toolbar pill's details list it, and `list_connections` tells agents. Turn either off (or on) in the connection's form, **Let AI in Tabula read without asking** and **Let agents read without asking**; the next query asks again without reconnecting. Tagging the connection anything but Production drops both ([#358](https://github.com/tungnguyenvan/tabula/issues/358)).

## [0.21.0] - 2026-11-06

### Added
- **AI in Redis windows.** **AI Chat** (⌥⌘A, and a toolbar button) opens the same chat panel as other windows, with providers, the model picker, saved conversations per connection, the usage line and limit errors. The model is told the server's INFO summary, `DBSIZE`, each database's keyspace line and up to 1,000 key names sampled with `SCAN` (never `KEYS`), grouped into patterns such as `user:*` with their counts, types and TTLs; no values. `list_keys` and `describe_key` look up names and a key's type, TTL, length, encoding and memory. With **Let the chat run read-only queries** on, it reads values one command at a time from an allowlist checked in Tabula before anything is sent: bounded `SCAN`, `GET`, `HSCAN`, `LRANGE`, `ZRANGE`, `XRANGE … COUNT`, `INFO`, `SLOWLOG GET` and the like, at most 500 elements per command, while `KEYS`, `HGETALL`, `SMEMBERS`, `0 -1` ranges, `FLUSH*`, `DEL`, `CONFIG`, `EVAL`, `MULTI` / `EXEC`, `SUBSCRIBE` and every write are refused. Its commands run on a connection of its own with a 15-second limit and long values cut, show in the console with the AI's mark, wait for **Allow** on Production and respect a read-only connection's lock. Answers hold ```` ```redis ```` blocks to **Insert** or **Open in Console**, or **Run** in the chat when they only read. **Visual answers** draw charts, metric cards and grids from those commands, their replies turned into rows (`SCAN` → `key`, `ZRANGE … WITHSCORES` → `member`, `score`, `INFO keyspace` → a row per database, and so on), and **`TABULA.KEYGROUPS prefix|type|ttl`**, Tabula's own read-only command (in the console too), gives keys and memory by key pattern, type or TTL band from a sample; pin them to the connection's **Dashboard** (⌥⌘5, now in the toolbar's picker). In the console, **Ask AI** (⌘K) writes commands into the input and **Fix with AI** under a failed command proposes a correction to accept or reject; neither runs anything, since Redis writes at once. The console's input takes several lines, run in turn. Notebooks and widgets of your own commands aren't available for Redis ([#352](https://github.com/tungnguyenvan/tabula/issues/352)).
- **Redis: Activity, Slow Log, Health and ACL users.** A Redis window's views are now in a **View** pop-up in the toolbar (eight don't fit in segments), with the same shortcuts as other windows. **Activity** (⌥⌘6) lists the clients from `CLIENT LIST` in a sortable table (id, address, name, user, age, idle, database, last command, flags, memory), refreshed every 2, 5 or 10 seconds while shown, with a filter, **Hide Tabula** and every field of the chosen client; **Kill Client…** (`CLIENT KILL ID`) asks first, asks again on Production, is refused on a read-only connection, shows in the console and is never offered for the window's own connections, which Tabula identifies by asking each for its `CLIENT ID`. **Slow Log** shows `SLOWLOG GET 128` (time, duration, command and arguments, client), what the server logs and keeps from `CONFIG GET` or why that isn't shown, long arguments cut and passwords always masked, with **Copy** and **Open in Console** of that masked text and **Reset…**, which asks first and is refused on a read-only connection. **Health** reads `INFO` and a sample of up to 1,000 keys (bounded `SCAN`, never `KEYS`) with `MEMORY USAGE` and collection lengths, and finds a missing or nearly reached `maxmemory`, the `noeviction` policy, memory fragmentation, evicted and expired keys, the biggest keys, big collections and keys without a TTL by key pattern, the sampled ones labelled as a sample; suggested commands are copied or put in the console, never run. **ACL Users** (Redis 6 and later) lists `ACL LIST` with `ACL GETUSER` for the chosen user, and creates, changes and deletes users through pending `ACL SETUSER` and `ACL DELUSER` commands, previewed with ⇧⌘S and committed with ⌘S one by one, stopping at the first failure; commit asks on Production and before a delete, and warns again, critically, before taking rights from the connection's own user. Passwords are masked as `•••` in the preview, in errors and in the console, which now masks them in commands typed there too (`AUTH`, `ACL SETUSER`, `HELLO … AUTH`, `MIGRATE … AUTH`, `CONFIG SET requirepass`). These views use a connection of their own, so a blocking command in the console doesn't hold them up ([#355](https://github.com/tungnguyenvan/tabula/issues/355)).
- **MongoDB: AI document changes, Explain with AI advice, and the data-meaning rules.** With **Let the chat propose data changes** on, asking the chat to change documents ("mark order 42 as shipped") puts the changes in the collection's tab as uncommitted edits, as on SQL databases: the model names documents by `_id` and sets or unsets fields, inserts documents or deletes them by `_id`; the tab is filtered to those `_id`s, and the edits keep their BSON types (a field is read back in the type it has, a field a document lacks takes the type it has in the sampled documents, so dates, `NumberLong`, `NumberDecimal` and `ObjectId` stay what they are, and a value that can't be that type is refused). ⇧⌘S previews the `updateOne` (with `$set` and `$unset`), `insertOne` and `deleteOne` commands, and nothing is written until you commit; Production asks first and a locked read-only connection refuses. **Explain** (⌥⌘E) now reads a `find` or `aggregate`'s plan with `explain("queryPlanner")`, and **Explain Analyze** (⌥⇧⌘E) with `executionStats`, only for statements that read and after asking on Production: a tree of the winning plan's stages (`COLLSCAN`, `IXSCAN`, `FETCH`, an aggregation's stages, each shard of a sharded cluster) with index names, documents returned, keys and documents examined and times, the statement's totals under it, and a `COLLSCAN` of a collection with 10,000 documents or more flagged. **AI about This Plan** sends the plan, the collection's indexes and its sampled field names and types, never documents, and suggests `createIndex` commands to insert or copy, never run. The chat and notebooks get the data-meaning rules for documents (leave out soft-deleted documents, use the live collection rather than `_old`, `_bak`, `_tmp` or dated copies, show status codes by name, match every type of a mixed-type field), and the schema hints name leftover collections, soft-delete, status and mixed-type fields from names and sampled types only ([#353](https://github.com/tungnguyenvan/tabula/issues/353)).
- **MongoDB: Activity, Top Queries, Health, and Users & Roles.** The 0.20 views now work on MongoDB, in its words. **Activity** lists the server's operations from `$currentOp` (everyone's when the login has `inprog`, otherwise its own, which the tab says; idle connections left out, idle sessions holding a transaction shown as such): op ID, user, namespace, client, application, the command, how long it has run and whether it waits for a lock, with the command as a shell statement to copy, explain or open. **Kill Op…** (`killOp`) asks first, asks again on Production, is refused on a read-only connection, and isn't offered for Tabula's own operations or the server's threads. **Top Queries** reads the database profiler (`system.profile`) of the current database and groups its records by the operation's shape (its values as `?`), with runs, total, mean and longest time, documents returned, documents and keys examined, collection scans and the plan of the slowest run, which **Explain…**, **Open in Query Tab** and **AI about This Query** (with `createIndex` advice, never run) use; when the profiler is off it says how to turn it on, with the commands to copy, and Tabula never changes the level; there is no reset to offer. **Schema Health** finds unused indexes from `$indexStats` (with the time each was counted from; `_id_`, unique and TTL indexes left out), duplicate and redundant indexes, collections the profiler saw scanned without an index (with a `createIndex` on the fields they filtered), and the largest collections and indexes from `$collStats`; suggested commands are never run. **Users & Roles** lists the users and roles of the current database (or `admin`) from `usersInfo` and `rolesInfo`, with the custom roles' privileges, and creates, changes and drops users and roles, gives and takes roles and grants privilege actions to roles as pending commands (`createUser`, `updateUser`, `grantRolesToUser`, `revokeRolesFromUser`, `grantPrivilegesToRole`…) previewed with ⇧⌘S and run one by one with ⌘S, stopping at the first failure; the connection's own user can't be dropped or lose its roles there. Passwords are masked as `pwd: "•••"` in the preview, the console log (for any statement, and `db.changeUserPassword` and `db.auth` too) and the server's errors. Every command Tabula sends to MongoDB 4.4 or later now carries a `comment` marker (`tabula-run:…`, `tabula-run:bg:…` for its own reads), by which these views tell Tabula's commands apart [#354](https://github.com/tungnguyenvan/tabula/issues/354).
- **Feature support by database.** A new page, [docs/features-by-database.md](docs/features-by-database.md), linked from the README, lists which features work on PostgreSQL, MySQL / MariaDB, SQLite, MongoDB and Redis: the AI features, the server views and the work with data and schemas, with what doesn't apply and what isn't there yet ([#356](https://github.com/tungnguyenvan/tabula/issues/356)).

### Fixed
- **A window with many tabs answers faster.** Typing in a query tab no longer runs the whole tab again (its bars, menus and result grid) on every key; switching tabs no longer builds every menu of the menu bar again; a tab's view is built once and then follows its own model instead of being handed a new one whenever the workspace changes; and hidden tabs are no longer measured, constrained or resized along with the tab shown (while the window or the inspector changes size, say). With a PostgreSQL window of 7 tabs (three 300-row tables, two query results, Server Metrics and a 6-card dashboard) and a Redis window open, a release build replaying the same 15 seconds of switching tabs, scrolling, typing and opening the AI panel evaluated 79% fewer SwiftUI view bodies, spent about half the main-thread time while typing and 11% less CPU overall (14% with the console shown), with the scrolling and drawing itself left to AppKit as before ([#357](https://github.com/tungnguyenvan/tabula/issues/357)).

## [0.20.0] - 2026-11-06

### Added
- **Schema Health.** **View › Schema Health** (and Open Anything, ⌘P) checks the schema selected in the sidebar and lists its findings in a tab, grouped by severity, with filters by severity, check and text: unused indexes (no scans since the statistics were reset, leaving out primary keys, unique and constraint indexes and a foreign key's only index, with the age of the statistics), duplicate and redundant indexes, foreign keys without an index, tables without a primary key, dead rows on PostgreSQL (an estimate from `pg_stat_user_tables`, with the last vacuum and analyze), invalid indexes, large tables read mostly by full scans, and the largest tables and indexes. Each finding says why it matters, shows its evidence and suggests a statement (`CREATE INDEX CONCURRENTLY`, `DROP INDEX`, `VACUUM (ANALYZE)`, `ADD PRIMARY KEY`…) that Tabula never runs: **Copy** it or **Open in Query Tab**, where the usual checks apply. **Export…** saves the findings as Markdown, and **Ask AI** explains one when AI is allowed for the connection, without sending rows. PostgreSQL and MySQL / MariaDB get every check their statistics allow (MySQL's index use needs `performance_schema`); SQLite gets the checks on its structure; MongoDB says it isn't available ([#350](https://github.com/tungnguyenvan/tabula/issues/350)).
- **Top Queries.** **View › Top Queries** (and Open Anything, ⌘P) lists the statements that cost the server the most, from PostgreSQL's `pg_stat_statements` or MySQL and MariaDB's statement digests in `performance_schema`, in a sortable table: the normalized statement, calls, total, mean and longest time and rows, plus shared blocks hit and read and temporary blocks on PostgreSQL (the columns of every `pg_stat_statements` version, `total_time` or `total_exec_time`), or rows examined, temporary tables on disk and calls without an index on MySQL. The header says since when they were counted (the last reset, from `pg_stat_statements_info` on PostgreSQL 14 and later). **Search** filters the list, Tabula's own background statements (catalog reads, metrics, the assistant's queries, dashboard refreshes; now marked `/* tabula-run:bg:… */`) are hidden until **Show Tabula's Statements** is ticked, while what you run is always listed, and a statement's pane shows it in full with **Copy**, **Open in Query Tab**, **Explain…** and, where AI is allowed for the connection, **AI about This Query**. Explain shows the plan in a new query tab without running the statement; a statement with placeholders (`$1`, `?`, `(...)`) first asks for example values in a sheet, or opens in a query tab to finish there, and MySQL 8's kept sample can be used as is. Explain Analyze is never run from here. AI about This Query sends the statement, its figures, the plan and the tables' columns and indexes (no rows) and suggests `CREATE INDEX` statements to open or copy, never run. **Reset Statistics…** asks first, asks again on Production, is refused on a read-only connection and shows in the console log. Where the statistics are off (the extension not created or not preloaded, `performance_schema` off, or a login that may not read them), the tab explains how to turn them on; Tabula never changes the server's settings or creates the extension itself ([#349](https://github.com/tungnguyenvan/tabula/issues/349)).
- **Activity: sessions, blocking locks, Cancel and Kill.** **View › Activity** (⌥⌘6) and Open Anything (⌘P) open a tab that lists the sessions of a PostgreSQL, MySQL or MariaDB server: process ID, user, database, client address, application, state, what it waits on, when its transaction and its query began, how long it has been in its state, and the query, in a table sorted by any column. **Show** keeps only active sessions, those idle in a transaction or those waiting for a lock; **Hide Idle** and **Hide Tabula** hide idle sessions (except ones others wait for) and this window's own connections, which are marked Tabula. It refreshes every 2, 5 or 10 seconds while shown, or on demand, and not while a menu is open. **Blocking** shows who waits for whom as an outline, with the lock each one wants (`pg_blocking_pids`, `performance_schema.data_lock_waits`, or `INNODB_LOCK_WAITS` on MySQL 5.7 and MariaDB). The chosen session's whole query has **Copy**, **Explain** and **Open in Query Tab**. **Cancel Query…** and **Kill Session…** (`pg_cancel_backend` / `pg_terminate_backend`, `KILL QUERY` / `KILL CONNECTION`) ask first with the session, its user and the start of its query, ask again on Production, are refused on a locked read-only connection until **Allow Changes…**, are never offered for Tabula's own sessions, and show in the console log. When the login lacks a privilege (`pg_read_all_stats`, `pg_signal_backend`, `PROCESS`, `CONNECTION_ADMIN`, `SELECT` on `performance_schema`) the tab and the error say which. The list comes over a connection of its own, so it answers while a query of yours is blocked. SQLite, MongoDB and Redis say Activity isn't available ([#348](https://github.com/tungnguyenvan/tabula/issues/348)).
- **Users, roles and permissions.** **View › Users & Roles** (and Open Anything, ⌘P) opens a tab for PostgreSQL's roles and MySQL's and MariaDB's users and roles: their attributes (login, superuser, create databases, create roles, connection limit, password expiry, locked accounts) and memberships; a grid of who can do what on the current schema's tables, views, sequences, functions and the schema itself, one row per grantee, object and privilege, filterable, with how each was got on PostgreSQL (granted, PUBLIC, owner, superuser or through a role); and PostgreSQL's default privileges. A table's **Structure** shows the same for that table under **Privileges**. Create, change and drop roles and users, grant and revoke privileges and memberships, and set default privileges: each change is pending SQL with every name quoted, previewed with ⇧⌘S and committed with ⌘S, in one transaction on PostgreSQL and one statement at a time on MySQL, whose account statements commit by themselves (it stops at the first failure and says how many were applied). Commit asks on Production, when it drops a role (a new statement check, also in the query editor) and when it takes privileges or sign-in from the connection's own user; a read-only connection refuses until **Allow Changes…**. Passwords are typed in secure fields, never saved or given to the AI, and shown as `'•••'` in the preview and in the console log, which now masks the password of any `CREATE ROLE … PASSWORD`, `IDENTIFIED BY` or `SET PASSWORD` statement and of the server's errors about it. When the connection's user can't read the accounts or change roles, Tabula says what it lacks ([#351](https://github.com/tungnguyenvan/tabula/issues/351)).

## [0.19.2] - 2026-11-05

### Added
- **Sort result grids in the chat, notebooks and dashboards.** Click a column's title in a result grid of an AI chat answer (including what **Run** shows under a query), a notebook cell or a dashboard grid card to sort its rows by that column, ascending, and click it again for descending, with the system's sort indicator, as in Finder. The rows already loaded are sorted on this Mac, without running the query again: numbers compare as numbers and dates as dates when the whole column holds them, other text as Finder sorts names ("item 2" before "item 10"), NULLs last either way, and equal values keep the order the query gave them. The order is kept with the conversation, the notebook cell or the card, also when the query runs again; **Copy Results** copies the rows in that order, a notebook's export writes its tables in it, and a grid card's exported image shows its rows sorted, with the indicator. A table tab still sorts on the server, as before ([#347](https://github.com/tungnguyenvan/tabula/issues/347)).
- **Notebooks: Hide SQL.** **Hide SQL** in a notebook's title menu, **View › Hide SQL** and Open Anything (⌘P) hide the statement of every query cell, so the notes, grids and charts read as a report; each cell keeps a one-line "Query hidden" with **Show** to open its statement, and **Show SQL** brings them all back. The SQL badge in a query cell's title row now shows or hides that cell's statement (it used to show the statement as it ran under the result). The choice is saved with the notebook; hidden statements still run, Run All runs them, and a query cell you add opens with its editor. **Export Notebook…** leaves out the statements of hidden cells, and its save panel has an **Include SQL** checkbox that starts as the notebook shows them (mixed when only some show) and can put them all in or leave them all out; chart images never had the statement in them. On MongoDB the menu says **Hide Commands** ([#346](https://github.com/tungnguyenvan/tabula/issues/346)).

### Fixed
- **Smooth live window resize with a long notebook open.** A notebook now builds only the cells in view, so dragging the window's edge no longer lays out every cell's editor and grid at each step: with a notebook of 14 query cells (grids and charts) and a 12-answer AI chat open, a release build went from about 2 frames a second (420 ms each) to about 20 (47 ms each) during the drag. A text cell being edited that scrolls far out of view keeps its text ([#345](https://github.com/tungnguyenvan/tabula/issues/345)).

## [0.19.1] - 2026-11-04

### Added
- **AI chat: what each answer took.** A small grey line under every complete answer shows its model calls, tool steps and time, and the input, output and cache tokens when the provider reports them, added up over the answer's calls (Claude API, Claude Code, Codex, OpenAI-compatible servers that send usage, and the model on this Mac, whose tokens Tabula counts); its help tag says where the numbers come from. It is saved with the conversation. These are the answer's own numbers, not your account's quota: Tabula never shows a remaining quota, percentage, reset time or price ([#344](https://github.com/tungnguyenvan/tabula/issues/344)).

### Changed
- **Clear rate-limit, quota and billing errors.** When a provider refuses for a rate limit, a used-up quota or plan limit, or billing, the chat names the provider and the kind of limit, keeps the provider's own message, shows when to try again if the provider sent a `retry-after`, and says where to check your quota or billing; Ask AI and the other AI features show the same text. Nothing is retried on its own ([#344](https://github.com/tungnguyenvan/tabula/issues/344)).

## [0.19.0] - 2026-11-03

### Added
- **Dashboard widgets of your own queries.** After a query that only reads, **Add to Dashboard…** (in the bar under the results, **Query › Add to Dashboard…** and the results' context menu) opens a sheet that makes a chart, metric cards or a grid of it: the chart's type, X, one or more Y columns and an optional series, stacked or grouped bars, or a metric card per column with its label and format (number, currency, percent), then the title, the size and the dashboard (or **New Dashboard…**). It starts from the result (the first text or date column along the bottom, the numeric columns as values) and previews it from the result on screen, so nothing runs again; **Add** saves the card with that result. **Add Widget…** in a dashboard's title menu and in an empty dashboard does the same with a SQL editor and **Run**, and **Edit Widget…** in any card's menu, including the ones pinned from the chat, changes its query or settings in place. **Add** stays off, saying why, until X and Y are columns of the result and Y is numeric, and a statement that may change data can't be a widget. **Chart Type ›** in a chart card's menu and in a chat chart's context menu switches between bar, line, area, point and pie without running the query again, and is kept with the dashboard or the conversation (a later Pin keeps it). **Dashboards now work with AI turned off**: the AI isn't involved in running their saved SQL, so cards refresh with AI off or not allowed on Production, still read-only on the assistant's connection, with the console log, and still asking first on Production ([#339](https://github.com/tungnguyenvan/tabula/issues/339)).
- **Show Query on charts, grids and metric cards.** A `</>` button on every chart, grid, metric cards and form in the chat, in notebooks and on the dashboard shows the exact statement Tabula ran (a form's with its values filled in), read-only and selectable, with **Copy** and **Open in Query Tab**. Whether it is shown is remembered per card, with the conversation, the notebook or the dashboard. Results now say "Ran read-only · 3 rows · 2 minutes ago" ([#340](https://github.com/tungnguyenvan/tabula/issues/340)).
- **Export a dashboard as an image.** **Export as Image…** in the dashboard's title menu, **File › Export Dashboard as Image…** and the Open Anything palette (⌘P) save the whole dashboard as one PNG through the save panel, named after the dashboard and the day ("Revenue 2026-11-03.png"), or as a PDF from the panel's **Format** pop-up; **Copy as Image** puts the PNG on the pasteboard. The image has the dashboard's name, the connection's name and when it was last refreshed, then every card at its size and in its layout at the window's width, at 2x and at full height even when the dashboard scrolls, in the window's light or dark appearance, without buttons, pointer readouts or menus; a card's query is included when Show Query is on ([#343](https://github.com/tungnguyenvan/tabula/issues/343)).
- **Show Query's button says SQL.** The `</>` icon is now a small "SQL" badge drawn like the symbols beside it, and `{}` on MongoDB, where the query is a shell command, in the chat, notebooks and dashboards. The query tab's own icon is unchanged.

### Changed
- **AI chat: better answers on messy, legacy schemas.** The schema sent with a question now says which tables are views, names the other schemas, and lists what the names suggest, marked as guesses: tables that look like copies or leftovers (`orders_bak`, `old_customers`, `orders_2023` next to `orders`), soft-delete columns (`deleted`, `is_deleted`, `deleted_at`, `flg_del`…) and likely joins where no foreign key declares one. The chat and notebooks are told to leave soft-deleted rows out unless you ask, use the live tables, find out what status codes and units mean from the descriptions, a config or lookup table or the values (never from how common a value is) and show codes by name, never add up amounts in different currencies, and check a guessed join that matches nothing. A question that can be read in ways that give different numbers, such as revenue over two currencies, is answered for the likeliest reading with the others offered as choices, and the chat suggests a data dictionary entry only for a specific unconfirmed guess the answer depends on, at most once, not when comments or configuration already settled it. Nothing new is read from your rows for this; suggestions while typing are unchanged ([#341](https://github.com/tungnguyenvan/tabula/issues/341)).

## [0.18.0] - 2026-11-02

### Added
- **Several named dashboards per connection, and card sizes.** The dashboard's title is a menu of the connection's dashboards ("Revenue", "Operations"…) with **New Dashboard…**, **Rename…** and **Delete Dashboard…** (which asks first). Each dashboard opens in its own tab, titled with its name, and several can be open at once; **View › Dashboard** (⌥⌘5) opens the one used last, and ⌘P lists each as "Dashboard: Revenue". The pin button pins to the dashboard used last and says which; **Pin to ›** in a component's context menu lists every dashboard plus **New Dashboard…**, and a card's menu has **Move to ›** another dashboard. A component is still pinned at most once to each dashboard. Cards come in **Size › Small / Medium / Large**, as macOS widgets: one column, two, or the whole row, never wider than the dashboard (columns are at least 320 pt wide), with charts taller on bigger cards; new charts start Medium, metrics Small and grids Large. Dragging a card by its title still reorders it, whatever the sizes, and open dashboard tabs come back with the window. **Existing dashboards are kept**: each connection's dashboard becomes one named "Dashboard", with its cards, their order, names and results and its auto refresh, every card Small so it looks as before ([#337](https://github.com/tungnguyenvan/tabula/issues/337)).

## [0.17.1] - 2026-11-02

### Fixed
- **AI chat: questions about numbers get charts and metric cards, not only a query.** Charts, result grids, metric cards and forms no longer need **Let the chat run read-only queries**, which stays off for anyone who used AI before the chat could run queries: Tabula runs their queries itself, read-only, and their rows are never sent to the AI, so they work with it off (Production still asks before each one, and dashboard cards refresh the same way). The model is also told to answer a question about counts, totals, a breakdown, a comparison or a trend with metric cards, a chart or a grid rather than a ```` ```sql ```` block alone, keeping the block when you ask for the query, and to offer a notebook for a question that takes several steps when read-only queries are on ([#333](https://github.com/tungnguyenvan/tabula/issues/333)).
- **AI chat: new answers stay in view.** While you're at the end of the conversation, it keeps the newest content on screen as the answer streams in, as tool steps appear, and when a chart, grid or metric card finishes loading and grows; a big block arriving at once no longer leaves the end below the panel. Once you scroll up to read, it stays where you are until you scroll back to the end, and sending a message always brings you to it, as in Messages ([#336](https://github.com/tungnguyenvan/tabula/issues/336)).
- **A middle-click on a tab closes it**, as in browsers, whether or not it is the selected tab; the others stay as they are. It asks first, as the close button and ⌘W do, when the tab has unsaved SQL or uncommitted edits. Left and right clicks and dragging tabs are unchanged ([#335](https://github.com/tungnguyenvan/tabula/issues/335)).
- **Charts show the exact values under the pointer.** Pointing at a chart in an AI answer, a notebook or the dashboard shows a line at the nearest value along the bottom with a panel listing that value and each series' number in its color, formatted as in the grid; the panel stays inside the chart, beside the line on the side with more room. The bar under the pointer stands out from the others, and a pie shows the slice's name, number and share in its middle. Server metrics charts show the time and value of the sample under the pointer. Exported chart images show no pointer ([#334](https://github.com/tungnguyenvan/tabula/issues/334)).

## [0.17.0] - 2026-11-01

### Added
- **Copy As JSON, SQL INSERT, CSV or a Markdown table.** **Edit › Copy As** and **Copy As** in the grid's context menu copy the selected rows (or the focused cell's row) in table tabs and query results. JSON (⌃⌘C) is an array of objects with numbers, booleans, NULL and JSON columns typed where the column's type is known, and bytes as base64; MongoDB documents are copied as the document editor shows them. SQL INSERT writes one statement per row into the table's real name with the database's quoting, leaving out generated columns as Duplicate Row does; **Settings › General** can make it one `INSERT` with a `VALUES` list. CSV is Export's CSV, and pastes back into a table as CSV. Markdown escapes pipes and cuts values over 60 characters. JSON and CSV are also put on the pasteboard as `public.json` and `public.comma-separated-values-text` ([#327](https://github.com/tungnguyenvan/tabula/issues/327)).
- **A value editor for JSON, long text and bytes.** Space on a cell (it replaces the quick look), **Open Value Editor** in the cell's context menu, a double-click on a value that spans lines, is longer than 200 characters or is JSON (⌥ double-click for any value), or the new button beside such a value in Row Details opens the whole value in a sheet sized to it, which remembers the size you give it. **JSON** is laid out over indented lines and colored, checked as you type with the line and column of a mistake, and has **Format** and **Minify**; numbers keep every digit, `\u` escapes and key order stay as written. **Text** wraps and has the find bar (⌘F) and a character and line count. **Binary** shows bytes as offset, hex and ASCII with a preview of PNG, JPEG, GIF and HEIC images, and **Save to File…** / **Load from File…**. The mode follows the column's type and the value, and can be switched. **Save** (⌘S) keeps a changed value as a pending cell edit, so Preview, Commit and Undo work as for any edit; views, rows without a key, generated columns and read-only results open read-only and say why ([#328](https://github.com/tungnguyenvan/tabula/issues/328)).
- **Follow a foreign key to the row it points to.** In a table tab, and in query results from one table, a value in a foreign key column opens the row it refers to: ⌘-click it (it shows as a link while ⌘ is held, as in Xcode), click the arrow that appears at the end of the cell, choose **Open Referenced Row** in its context menu, or press ⌥⌘→ on the selected cell. The referenced table opens in its tab, filtered to that key with ordinary filter conditions (every column of a composite key) and with the row selected. **Back** (⌃⌘←) and **Forward** (⌃⌘→), in the Database menu, return to the tab, filter, page and row you came from, as in a browser. The other way, **Rows Referencing This Row** in a row's context menu and in Row Details lists the tables whose foreign keys point at it with a count each (read-only, up to 1,000), and opens the one you choose filtered to those rows. NULL keys, keys with an uncommitted change and new rows can't be followed; tables in another schema are named with it. PostgreSQL, MySQL / MariaDB and SQLite ([#326](https://github.com/tungnguyenvan/tabula/issues/326)).
- **Read-only connections.** A **Read-only** checkbox in the connection form (off by default, suggested for Production) makes Tabula refuse anything that writes on the connection: grid cells and query results can't be edited, **+**, **−**, **Duplicate**, **Paste**, **Import…** and **Generate Rows…** are off, commits, document saves, routine saves, **Truncate**, **Drop** and **Restore from Dump…** are refused, the AI chat's proposed changes are refused, and **Run** refuses a statement the checks say may change data (or one that would make the session read-write again) with a message and **Allow Changes…**. Redis consoles send only commands known to only read, and keys can't be changed. On the server the session is read-only too: `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY` on PostgreSQL, `SET SESSION TRANSACTION READ ONLY` on MySQL / MariaDB, `PRAGMA query_only` on SQLite. **Allow Changes…** (the toolbar's lock, or **Database › Allow Changes for 10 Minutes…**) asks, naming the connection, then lifts both for 10 minutes, with **Lock Again** and the time left in the toolbar; uncommitted changes left when it locks again stay pending until the next unlock. A lock in the toolbar pill, the column of open connections and the Connections window shows which connections are read-only ([#329](https://github.com/tungnguyenvan/tabula/issues/329)).
- **Connections reconnect by themselves** after the Mac wakes, the network changes (Wi-Fi, VPN), or a statement fails because the server dropped the connection. Tabula pings the server and, if it doesn't answer, opens a new connection quietly while the connection pill shows **Reconnecting…**: with a new SSH tunnel where there is one, the sidebar's schema or database selected again, and a read-only connection's session and the AI assistant's read-only settings put back. Page loads, counts, the sidebar's lists and SELECTs from the editor run again once; a commit, a change, DDL or a script is never run again and says "The connection was lost while this ran; it may or may not have been applied", and a transaction opened with `BEGIN` is reported as lost. Each notice makes a few tries with growing waits, then the window shows the error with **Try Again**. Works on PostgreSQL, MySQL / MariaDB, MongoDB and Redis, and for the AI agents' (MCP) connections ([#325](https://github.com/tungnguyenvan/tabula/issues/325)).

### Fixed
- **PostgreSQL: a statement on a connection the server had closed no longer waits forever.** After `pg_terminate_backend`, a server restart or a dropped network, the next statement (and every one after it) hung without an error; it now fails at once, and Tabula reconnects ([#332](https://github.com/tungnguyenvan/tabula/issues/332)).
- **MongoDB: a copied long or a whole double keeps its type.** Duplicate Row and SQL INSERT export wrote `NumberLong(5)` and `4.0` back as text; they are now a long and a double again ([#331](https://github.com/tungnguyenvan/tabula/issues/331)).

## [0.16.2] - 2026-11-01

### Changed
- **AI chat: Run runs a query right in the chat.** A query that only reads runs under its block on the chat's read-only path (read-only check, the assistant's separate connection, 15 seconds, the console log, and a question first on Production), with **Running…** and **Stop** while it runs, then "✓ 12 rows · 34 ms" and the result grid with **Open in Query Tab**, or the error in red with **Fix**, which asks the AI for a corrected query. The result is saved with the answer, and the button becomes **Run Again**. A statement that may change data shows **Open in Query Tab** instead and opens there unrun, where the statement checks apply. **Insert** puts the query on lines of its own and never joins or replaces the text in the editor ([#320](https://github.com/tungnguyenvan/tabula/issues/320)).

### Fixed
- **AI chat: queries in answers that don't run are caught.** Once an answer is complete, Tabula checks each read-only query with a plain EXPLAIN (never ANALYZE) on the read-only connection; one that fails is marked with the error and sent back to the model once, and a correction that passes replaces it, with the first version under **Original**. Not on Production, MongoDB or Redis; **Check queries in answers before showing them** in Settings › AI turns it off. The model is also told never to answer with a placeholder query such as `SELECT 'ok' AS status`, and to look a table up before using columns it hasn't seen ([#321](https://github.com/tungnguyenvan/tabula/issues/321)).
- **AI chat: follow-up questions stay in context.** "And last month?" or "only the paid ones" is read with the conversation: the tables sent with it come from the whole conversation, not only the new message, the history keeps your last 8 questions with their answers however many tool steps those took, and the assistant is told the new message continues the conversation ([#330](https://github.com/tungnguyenvan/tabula/issues/330)).
- **Fix with AI no longer changes your SQL without asking.** The corrected statement shows above the editor while the model writes it, under the failed one with removed words struck through in red and added ones in green, and a one-line reason when the model gives one. Nothing in the editor changes until **Accept** (↩), which replaces just the failed statement as one step for ⌘Z and clears the error; **Reject** (⎋) leaves it as it was, and **Accept and Run** (⌘↩) runs it after the usual checks, so Production still asks first. **Ask AI** (⌘K) on a selection is reviewed the same way; inserting at the cursor stays direct, with an **Inserted by AI · Undo** note ([#322](https://github.com/tungnguyenvan/tabula/issues/322)).
- **AI chat: code you write in ``` fences shows as code**, in a block with Copy, as in the assistant's answers; it used to show as plain text with the backticks ([#323](https://github.com/tungnguyenvan/tabula/issues/323)).
- **AI chat: clicking the "Thought for N s" title opens the reasoning**, and clicking a step's title opens the step; only the small arrow used to ([#324](https://github.com/tungnguyenvan/tabula/issues/324)).

## [0.16.1] - 2026-11-01

### Fixed
- The toolbar's **Console**, **AI Chat** and **Row Details** buttons look pressed while their panel is shown, as toolbar toggles do in Mail and Xcode, so you can see what is open ([#319](https://github.com/tungnguyenvan/tabula/issues/319)).

## [0.16.0] - 2026-11-01

### Added
- **A data dictionary, written once with AI and used everywhere.** **Describe with AI…** (in a table's Structure tab, its context menu in the sidebar, or **Describe Tables with AI…** in the sidebar's context menu for the whole schema) asks the model for a short description of each table and column: what it holds, its unit, what codes such as `status = 3` mean. It is sent the names, types, primary and foreign keys, the database's comments and the current descriptions, and only with **Include sample values** ticked up to 5 distinct values per column (each cut to 40 characters, read on the assistant's read-only connection); large schemas go 20 tables per request, with progress and Stop. The proposals are listed table by table with the current text, the proposed text to edit and a checkbox, and **Save** keeps the ticked ones. Descriptions are saved per connection (and deleted with it), editable in Structure's new **Description** column, shown in the grid's column header tooltips, and sent with the schema to the chat, Ask AI, Fix with AI, filter by description and Generate Rows, at most 200 characters each and 6,000 in all. PostgreSQL and MySQL comments are the starting text. **Open as COMMENT Statements** writes them as `COMMENT ON` statements (PostgreSQL) or `ALTER TABLE … COMMENT` for tables (MySQL, whose column comments need the column's whole definition) in a query tab, never run by Tabula. The instructions can be changed in Settings › AI › Instructions › Data dictionary ([#318](https://github.com/tungnguyenvan/tabula/issues/318)).
- **AI analysis notebooks.** A question that takes several steps ("why did revenue drop in October?") can be worked through in a notebook tab: **Analyze in Notebook** beside a question in the AI chat (or in the chat's ⋯ menu), the button the chat shows when the model suggests it, or **View › New Notebook**. The model runs one read-only query per step, at most 8: each becomes a query cell with a line on why it runs and its result as a grid, chart or metric cards, what it found becomes a text cell, and a summary ends it; **Stop** (⌘.) ends it at once, and follow-up questions continue from every cell. Query cells can be edited and run again (⌘↩), alone or with **Run All Below**; text and query cells can be added, moved and deleted. Every query runs as the chat's do: read-only check, the assistant's separate read-only connection, 15 seconds, the console log, at most 50 rows with long values cut sent to the model, the chat's settings, and on Production a question before each one. Notebooks are saved per connection with their results, listed under the notebook's title and in Open Anything, and can be renamed and deleted; **File › Export Notebook…** writes Markdown with result tables and charts as PNG files ([#317](https://github.com/tungnguyenvan/tabula/issues/317)).

## [0.15.0] - 2026-10-31

### Added
- **Pin AI chart answers to a dashboard.** Charts, metric cards and result grids in the AI chat get a pin button (and **Pin to Dashboard** in their context menu) that puts them on the connection's dashboard: **View › Dashboard** (⌥⌘5). Cards sit in a grid with the results they had, shown again without a query until you refresh; each can be refreshed, renamed, moved (drag it by its title), removed, opened in a query tab or copied as SQL. **Refresh All** runs them all, and **Auto Refresh** every 1, 5 or 15 minutes while the dashboard is shown. Queries run as the chat's do: read-only, on the assistant's own connection, 15 seconds, in the console log. On Production connections automatic refresh is off and a refresh asks once first. Dashboards are saved per connection and deleted with it ([#313](https://github.com/tungnguyenvan/tabula/issues/313)).
- **Checks before a statement runs, and Review with AI.** Run and Run All look for an `UPDATE` or `DELETE` without `WHERE`, a `WHERE` that is always true (`1 = 1`, `x = x`), `TRUNCATE`, `DROP TABLE` / `DATABASE` / `SCHEMA`, `DROP COLUMN`, PostgreSQL `ALTER TABLE` that rewrites the table (a volatile default, a type change), MySQL `ALTER TABLE` that may copy it (no `ALGORITHM=INPLACE` / `INSTANT`), and MongoDB `deleteMany({})`, `updateMany({}, …)` and `drop()`, reading past comments and strings. On Production, Tabula asks before any statement that may change data, with the findings and, from a plain `EXPLAIN` on a separate connection, an `UPDATE` or `DELETE` expected to change 10,000 rows or 10% of a table, and a `CREATE INDEX` without `CONCURRENTLY` on a large table. Development and Staging ask only before a danger finding (with **Don't ask again for this connection**); Local connections and SQLite files show the findings beside the results. With AI on, **Review with AI** sends the statement, the findings, the tables' columns and the plan, never rows, and shows an explanation and a safer statement to **Use This** (put in the editor, not run) or copy; its instructions are in Settings › AI › Instructions › Review. Production commits list any findings too ([#314](https://github.com/tungnguyenvan/tabula/issues/314)).
- **Report a Problem can add Tabula's recent crash reports.** When Tabula or its `tabula-mcp` helper crashed in the last 7 days, **Help › Report a Problem…** lists the crash reports macOS saved, each with a checkbox, and shows the full text the ticked ones add before the issue opens in your browser: the versions, the exception, the termination reason, the crashing thread's backtrace and its binaries, with home-folder paths shortened to `~`. A report too long for the issue's link is named instead, with **Show in Finder** to attach it. On the first launch after a crash, Tabula asks once whether to report it. Reports are read only after a new crash or when you report a problem, and Tabula still sends nothing itself ([#316](https://github.com/tungnguyenvan/tabula/issues/316)).
- **Generate test rows with AI.** **Generate Rows…** (in the menu of the **+** button under a table, the table's context menu in the sidebar, and the Edit menu) asks the model for 1 to 500 rows, optionally described ("customers in Europe, half of them VIP"). It is sent the table's schema: columns, types, NULL rules, defaults, keys, CHECK constraints, enum values and foreign keys, never rows. Foreign keys get existing values picked by Tabula, or, with **Use existing ids for foreign keys** ticked, up to 200 values of each referenced key are sent for the model to choose from. Every value is checked against its column (type, range, length, NULL, enum and `IN (…)` checks, uniqueness within the new rows and against the table's existing rows, existing foreign key values); rows that fail are dropped and listed with the reason. The rest are added as new rows, one step for ⌘Z, to preview with ⇧⌘S and commit with ⌘S. Auto-increment, serial, identity and generated columns are left to the database. Works on PostgreSQL, MySQL / MariaDB, SQLite and MongoDB; the instructions can be changed in Settings › AI › Instructions › Test data ([#315](https://github.com/tungnguyenvan/tabula/issues/315)).

### Fixed
- Percent cards in the AI chat's visual answers and the dashboard show at most one decimal: 45.8%, not 45.833333%.

## [0.14.1] - 2026-10-31

### Changed
- **A shorter README that starts with the AI features**, with every feature listed in a line or two and the details in guides under [docs/](docs/): AI assistant, AI agents (MCP), connections, editing, queries, schema, MongoDB, Redis, install and keyboard shortcuts.

### Fixed
- **Light Mode is light again**: the tab strip, editor toolbars, filter bar and bottom bars used a mid gray meant for the area behind pages, which looked dark next to the white grid. They now use the window color a shade darker, as Safari's tab bar does; Dark Mode is unchanged ([#312](https://github.com/tungnguyenvan/tabula/issues/312)).
- The filter bar's **SQL**, **Apply** and **Clear** buttons keep their full titles when the window is narrow or a side panel is open; the value field gives up the room ([#312](https://github.com/tungnguyenvan/tabula/issues/312)).

## [0.14.0] - 2026-10-31

### Added
- **Filter a table by describing it.** With AI on, the sparkles button in a table's filter bar opens a field for a sentence such as "unpaid orders from this week over 100" or "khách ở Hà Nội tạo trong tháng này"; the model turns it into ordinary conditions in the filter bar, applied at once, which you can untick or change, and ⌘Z brings back the filter from before. Only the table's columns, types and keys, today's date and the time zone are sent, never rows. Each condition is checked against the table (column, operator, a value of the column's type) and dates are written as the column compares them; what conditions can't express, such as "the top 10", is answered with the reason instead. Works on PostgreSQL, MySQL / MariaDB, SQLite and MongoDB; the instructions can be changed in Settings › AI › Instructions › Filter ([#308](https://github.com/tungnguyenvan/tabula/issues/308)).
- **Compare two schemas and generate the changes** (PostgreSQL, MySQL, SQLite): **File › Compare Schemas…** compares a source and a target, each a saved connection and a schema, such as Development and Production. A tree shows the tables, views, columns, primary keys, indexes, foreign keys and routines that are only in one or different, with **Only Differences** and a search field; beside it is the SQL script that makes the target match the source, in dependency order, with SQLite's table rebuilds where its ALTER TABLE can't make a change. DROP statements stay commented out unless you turn on **Include Drops**. Copy it, save it, or open it in a query tab of the target; Tabula never runs it. Both schemas are read on read-only connections ([#307](https://github.com/tungnguyenvan/tabula/issues/307)).
- **The AI chat can propose data changes for you to review**: with **Settings › AI › Let the chat propose data changes** on (off by default), asking it to change rows ("mark order 42 as shipped") opens the table's tab filtered to those rows, with the changes in as uncommitted edits. Nothing is written until you preview (⇧⌘S) and commit them (⌘S), as with your own edits; Production still asks before the commit. Tables, columns and primary keys are checked against the real table; tables without a primary key and proposals of more than 500 rows are refused. Works with every provider on PostgreSQL, MySQL / MariaDB and SQLite ([#303](https://github.com/tungnguyenvan/tabula/issues/303)).
- **AI agents can use your connections through Tabula (MCP).** Claude Code, Codex, Cursor and other MCP clients can list the connections you allow, list and describe tables, and run read-only queries, with the chat's safety: a read-only connection and transaction, 15 seconds, at most 50 rows, and on Production connections Tabula asks before each query. Turn it on in Settings › AI, then turn on **Allow AI agents (MCP)** for each connection; Settings shows the command that adds Tabula to your agent. The agent never sees passwords: the `tabula-mcp` helper inside Tabula.app passes each call to the running app, which opens the connection itself. Agents' statements appear in the console log with the agent's name ([#301](https://github.com/tungnguyenvan/tabula/issues/301)).
- **Help › Report a Problem…** opens a new GitHub issue in your browser with Tabula's version, the macOS version and the kind of Mac filled in; Tabula itself sends nothing ([#299](https://github.com/tungnguyenvan/tabula/issues/299)).
- **Import a CSV, TSV or JSON file into a table** (PostgreSQL, MySQL, SQLite) with **File › Import…** or **Import…** in the table's context menu in the sidebar. The file's columns are matched to the table's by name, ignoring case and accents, and can be changed or skipped; a header row is detected and can be turned off; the first rows are previewed. The rows are added as new rows in the grid and commit in one transaction with ⌘S, after a preview with ⇧⌘S if you like. CSV is read as RFC 4180 writes it, in UTF-8 (with or without a byte order mark), UTF-16 or Windows-1252; JSON as an array of objects. Files with more than 100,000 rows are refused with a message ([#302](https://github.com/tungnguyenvan/tabula/issues/302)).
- **Edit and delete rows of tables without a primary key.** Rows are found by a unique index on NOT NULL columns, or else by SQLite's `rowid` or PostgreSQL's `ctid`, and the bottom bar says which ("Rows identified by ctid"). A commit that can't find one of its rows, as loaded, saves nothing: with `ctid` that includes a row someone else changed meanwhile. MySQL tables with no such index stay read-only, with the reason shown ([#305](https://github.com/tungnguyenvan/tabula/issues/305)).
- **Edit › Find in Database…** (⇧⌘F) finds a value in every table of the current schema, or the tables you choose, and lists each column it is in with the number of matching rows. Text columns are searched for it ignoring case; numeric, UUID, date and binary columns must equal it. Opening a result shows the table filtered to those rows, with the conditions in the filter bar. The search reads one table at a time on a read-only connection, Stop (⌘.) ends it, and Production connections ask first. MongoDB collections are searched by their string fields ([#306](https://github.com/tungnguyenvan/tabula/issues/306)).
- **Visual query plan:** **Query › Explain** (⌥⌘E, or the Explain button) shows how the database runs the selected statement, or the one at the cursor, as an outline in the result area: each operation with its table and index, the estimated rows and cost, and with **Explain Analyze** (⌥⇧⌘E) the actual rows and time. The operations that take the largest share of the time (or cost) are tinted, and full scans of tables with 10,000 rows or more are flagged. Explain Analyze runs the statement: PostgreSQL runs one that changes data on a separate connection in a transaction it rolls back, after asking; MySQL analyzes only statements that read; SQLite has no Analyze. **Copy Plan** copies the plan as the server returned it, and with AI on, **Ask AI about This Plan** explains it and suggests `CREATE INDEX` statements to insert or copy, never run ([#304](https://github.com/tungnguyenvan/tabula/issues/304)).
- **Visual answers in the AI chat:** answers can show a chart (bar, line, area, point, pie), a result grid with Open in Query Tab, metric cards, a form for a query with placeholders, choices you click to reply, and a diagram of the tables involved, drawn natively. Charts, grids and cards show data from read-only queries Tabula runs itself, with the chat's usual checks and Production approval, so they can't show numbers the model made up. Settings › AI › Visual answers turns them off ([#309](https://github.com/tungnguyenvan/tabula/issues/309)).

### Changed
- CSV and TSV exports put empty text and the text `NULL` in quotes, so they can be told from NULL (an empty field) when the file is imported again. Pasting reads a quoted `"NULL"` as the text, as import does; `NULL` without quotes is still NULL ([#302](https://github.com/tungnguyenvan/tabula/issues/302)).
- The pending-changes preview (⇧⌘S) shows the first 1,000 statements of a large change, such as an import; **Copy SQL** still copies them all ([#302](https://github.com/tungnguyenvan/tabula/issues/302)).

### Fixed
- **Tabs work on macOS 15**: clicking, the close button, the context menu and dragging to reorder. On macOS 15 the tab strip's scroll view stretched up under the toolbar without its content area following, so the tabs sat outside it and got no mouse events; 0.13.3 didn't fix this there. Dragging a tab now slides the others aside as in Safari ([#298](https://github.com/tungnguyenvan/tabula/issues/298)).
- On macOS 15, a .sql file saved in UTF-8 with a byte order mark, opened or in the saved query library, no longer starts with an invisible character before its first statement ([#310](https://github.com/tungnguyenvan/tabula/issues/310)).
- Tabula no longer crashes on macOS 14 when connecting to Redis, MongoDB or MySQL. SwiftNIO 2.104.0, which earlier versions were built with, stops on macOS 14 as a connection sets up ([#311](https://github.com/tungnguyenvan/tabula/issues/311)).

## [0.13.3] - 2026-10-31

### Fixed
- **Clicking a tab selects it again on macOS 14 and 15**; since 0.13.0, when tabs became draggable, clicks there did nothing. A tab is now selected as the button goes down, as in Safari and Finder ([#298](https://github.com/tungnguyenvan/tabula/issues/298)).

## [0.13.2] - 2026-10-31

### Fixed
- **MySQL: `CALL` of a procedure that returns rows** shows them; it used to fail with "can't return a result set in the given context (1312)". When the procedure returns several result sets, the first is shown ([#185](https://github.com/tungnguyenvan/tabula/issues/185)).

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
