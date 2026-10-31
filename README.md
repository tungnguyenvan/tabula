<p align="center"><img src="docs/icon.png" width="96" alt="Tabula icon"></p>

<h1 align="center">Tabula</h1>

<p align="center">A fast, native macOS client for <b>PostgreSQL</b>, <b>MySQL / MariaDB</b>, <b>SQLite</b>, <b>MongoDB</b> and <b>Redis</b>.<br>
Free, no usage limits, keyboard-first.</p>

<p align="center"><a href="https://github.com/tungnguyenvan/tabula/releases/latest"><b>Download</b></a> · <a href="https://github.com/tungnguyenvan/tabula/releases/download/v0.5.1/Tabula-demo.mp4">Demo video</a> · <a href="https://github.com/tungnguyenvan/tabula/releases/download/v0.14.0/Tabula-whats-new-0.14.mp4">What's new in 0.14</a> · <a href="CHANGELOG.md">Changelog</a> · <a href="LICENSE">MIT License</a></p>

<div align="center">

https://github.com/user-attachments/assets/24917ff7-76bb-482f-a36c-bfc87224b393

<sub>The demo (44 s): Tabula driven by real clicks and keys. <a href="https://github.com/tungnguyenvan/tabula/releases/download/v0.5.1/Tabula-demo.mp4">Full quality, 1080p at 60 fps</a>.<br>
New in 0.14: <a href="https://github.com/tungnguyenvan/tabula/releases/download/v0.14.0/Tabula-whats-new-0.14.mp4">a short video of what's new</a>.</sub>

</div>

<p align="center"><img src="docs/screenshots/hero.png" width="900" alt="Tabula with a Redis and a PostgreSQL connection open, browsing a table with the row details panel"></p>

## Why Tabula

- **Native and fast.** A real Mac app (SwiftUI and AppKit): under 100 MB of memory with a table open, no CPU when idle, and a 5,000-row page in under 50 ms ([benchmarks](docs/benchmarks.md)).
- **Five databases, one app.** PostgreSQL, MySQL / MariaDB, SQLite, MongoDB and Redis, several side by side in one window.
- **Safe editing.** Changes wait, highlighted, until you preview the exact SQL (⇧⌘S) and commit them in one transaction (⌘S). Connections tagged Production ask before commits and destructive actions.
- **AI that works on real data, safely.** The assistant reads with read-only queries on its own read-only connection, proposes data changes as edits you review and commit, and asks before each query on Production. Use a model that runs inside Tabula, offline, or the AI you already have.
- **Your data stays on your Mac.** Passwords in the Keychain, no account, no telemetry. AI is off until you turn it on, and you decide what it may see.
- **Free.** No usage limits, no subscription, MIT licensed.

## Contents

- [Features](#features): [Connect](#connect) · [Browse & edit data](#browse--edit-data) · [Write & run queries](#write--run-queries) · [Understand performance](#understand-performance-explain) · [Find & import](#find--import) · [Structure & schema](#structure--schema) · [AI assistant](#ai-assistant) · [AI agents (MCP)](#ai-agents-mcp) · [MongoDB](#mongodb) · [Redis](#redis)
- [Install](#install)
- [Getting started](#getting-started)
- [Connections in detail](#connections-in-detail)
- [Editing in detail](#editing-in-detail)
- [Queries in detail](#queries-in-detail)
- [AI assistant in detail](#ai-assistant-in-detail)
- [Setting up AI agents (MCP)](#setting-up-ai-agents-mcp)
- [MongoDB in detail](#mongodb-in-detail)
- [Size and resource use](#size-and-resource-use)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Your data](#your-data)
- [Known limitations](#known-limitations)
- [License](#license)

## Features

### Connect

- PostgreSQL, MySQL / MariaDB, SQLite files, MongoDB and Redis. **Test** before saving; connecting gives up after 15 seconds instead of hanging.
- Tag each connection **Local**, **Development**, **Staging** or **Production**. The tag colors the sidebar strip and the toolbar pill, and Production asks before commits and destructive actions. Passwords live in the macOS Keychain; TLS can be off, required, or required with certificate verification.
- [SSH tunnels](#ssh-tunnels) for PostgreSQL and MySQL, with key authentication only. Create a connection by pasting a [connection string](#connection-strings) (URL, JDBC, libpq or .NET style), and copy one back as a URL, with or without the password.
- Several connections in one window: open another from the toolbar's database button and switch with ⌃⌘] / ⌃⌘[. On PostgreSQL, the sidebar's Database picker opens any database on the server from the same connection.
- Picks up where you left off: reopening a connection brings back its query tabs (unsaved SQL included), open tables, filters, schema and query history. Windows aren't restored at launch, so Tabula never reconnects to a database, such as Production, unless you choose to.
- [Dump and restore](#dump-and-restore) PostgreSQL and MySQL databases with the client tools on your Mac.

<p align="center"><img src="docs/screenshots/connections.png" width="560" alt="Connections window"></p>

### Browse & edit data

- A schema or database switcher (it also becomes the default for queries, so `transactions` finds `dev.transactions`) and a table list you can filter, with collapsible groups. Arrow keys preview tables in one reusable tab; Return keeps one open. Drag tabs to reorder them. ⌘P jumps to any table, tab or action.
- A paged grid (100 to 5,000 rows) with a total count, server-side sorting and spreadsheet-style keys.
- **Filter** with a builder (AND / OR; untick a condition to leave it out), a `WHERE` clause, or **Filter by This Value** on a cell. Each table remembers its filter. With AI on, [describe the rows](#in-the-editor-and-the-filter-bar) in words instead.
- **Edit** in the grid or the row details panel (⌥⌘0): NULL or empty text, add, duplicate and delete rows, or paste rows from Tabula, Numbers, Excel or Google Sheets (⌘V). Undo and redo per tab.
- **Nothing is written until you commit:** ⇧⌘S previews the SQL, ⌘S runs every change in one transaction and rolls back if any statement fails. [Tables without a primary key](#tables-without-a-primary-key) can be edited too.
- Copy rows as TSV, with or without headers; export CSV, TSV, JSON or SQL `INSERT`. Binary values show as `\x` and hex, as psql shows them, and are saved back as bytes.

<p align="center"><img src="docs/screenshots/data.png" width="820" alt="Filtering a table, with the row details panel open"></p>

### Write & run queries

- Highlighting, suggestions for tables, columns and keywords (Tab accepts the grey one), **Beautify** (⇧⌘I), comment toggling (⌘/) and history.
- **Run** (⌘↩) the selection or the statement under the cursor, or all of them (⇧⌘↩), one result each. [Stop](#running-and-stopping) (⌘.) cancels on the server. A row **Limit** (300 by default) on SELECTs that have none keeps an accidental full-table query small.
- MySQL / MariaDB: `CALL` of a procedure shows the rows it returns, and `DELIMITER` scripts run as in the mysql client.
- [Edit query results](#editing-query-results) from one table that include its primary key.
- **Saved queries:** Save to Library (⌥⌘S) keeps a query under a keyword as a `.sql` file in `~/Library/Application Support/Tabula/Queries`; the Queries panel (⌥⌘L) searches them, and a keyword plus ⌃Space inserts one. Open and save `.sql` files (⌘O, ⌘S, or from Finder; Tabula never makes itself their default app); closing one with unsaved edits asks first.
- **Console log** (⇧⌘C): every statement sent to the server, with time, rows, duration and errors; copy it as a SQL script.

<p align="center"><img src="docs/screenshots/query.png" width="820" alt="SQL editor with results and the console log"></p>

### Understand performance (Explain)

- **Explain** (⌥⌘E) shows how the database would run a statement, without running it: each operation with its table, index, estimated rows and cost.
- **Explain Analyze** (⌥⇧⌘E) runs it and adds actual rows and time; a statement that changes data is [rolled back or refused](#query-plans). Operations that take the largest share of time are tinted, and full scans of tables with 10,000 rows or more are flagged.
- With AI on, **Ask AI about This Plan** explains it and suggests `CREATE INDEX` statements to insert or copy. Nothing is run.
- **Server metrics** (⌥⌘4): live charts of reads, writes, transactions, connections and active queries every 1 to 30 seconds, plus cache hit ratio and the largest tables. Polling isn't written to the console log.

<p align="center"><img src="docs/screenshots/metrics.png" width="820" alt="Server metrics"></p>

### Find & import

- [Find in Database](#find-in-database) (⇧⌘F): a value in every table of the schema, listed by column with the number of matching rows. Double-click a result to open the table filtered to those rows.
- [Import a CSV, TSV or JSON file](#importing-files) into a table (PostgreSQL, MySQL, SQLite). Columns are matched by name and previewed, and the rows arrive as new rows to review and commit in one transaction.

### Structure & schema

- **Structure** (⌥⌘2): columns with type, nullability, default, comment and primary key, and indexes with their definitions.
- **Relationship diagram** (⌥⌘3): the schema's tables with foreign-key lines, laid out by dependency. Drag, zoom, show key columns only, export a PNG.
- **Functions, procedures and triggers** (PostgreSQL, MySQL; triggers on SQLite): view, edit and save with ⌘S. Saving never loses a routine: PostgreSQL functions use `CREATE OR REPLACE`, PostgreSQL and SQLite triggers are recreated in one transaction, and on MySQL, which can't run DDL in a transaction, the original is put back if the new definition fails.
- **Compare schemas (PostgreSQL, MySQL, SQLite):** **File › Compare Schemas…** opens a window that compares a source with a target, each a saved connection and a schema (for example Development `public` against Production `public`, or two schemas of one connection), and writes the SQL script that makes the target match the source.
  - Both sides are read on read-only connections of their own, so comparing never asks on Production. The tree lists each table and view that differs, with its columns (type, NOT NULL, default, generated), primary key, indexes and foreign keys marked as only in the source, only in the target or different, and the functions, procedures and triggers. **Only Differences** and the search field narrow it.
  - The script is in the target's dialect and in dependency order: foreign keys, views and indexes that change or go are dropped first, then tables are created and altered, then indexes, views, foreign keys and routines are created. A column that may have been renamed (one removed and one added of the same type) is added and dropped, with the `RENAME COLUMN` to use instead in a comment. On PostgreSQL the script runs in one transaction. SQLite tables whose columns or keys change are rebuilt the usual way (a new table, the rows copied, the old one dropped, the new one renamed); steps Tabula can't write in full, such as SQLite generated columns, are commented out with what to fill in.
  - Statements that remove what only the target has (DROP TABLE, DROP COLUMN…) are commented out unless you turn on **Include Drops**. **Copy**, **Save As…** or **Open in Query Tab** on the target connection: Tabula never runs the script itself. CHECK constraints, collations, sequences, enum types and permissions aren't compared.

<p align="center"><img src="docs/screenshots/structure.png" width="820" alt="Structure view"></p>

<p align="center"><img src="docs/screenshots/diagram.png" width="820" alt="Relationship diagram"></p>

### AI assistant

Off until you turn it on in **Settings › AI**. [How it works and what is sent](#ai-assistant-in-detail).

- **Chat** (⌥⌘A) writes queries you can **Insert**, **Run** or copy. It knows your tables, keys and schema, looks things up with [read-only queries](#read-only-queries) to answer from the real data, and shows every step. Conversations are saved per connection.
- **Proposed data changes** (opt-in): "mark order 42 as shipped" becomes uncommitted edits in the table's tab, for you to preview and commit.
- **Visual answers:** charts, result grids, metric cards, query forms, clickable choices and table diagrams. Their data comes from queries Tabula runs itself, so a chart can't show numbers the model made up.
- **Ask AI** (⌘K) writes or changes SQL in the editor, **Fix with AI** repairs a failed statement, and the model can suggest SQL in grey as you type.
- **Filter by description:** "unpaid orders from this week over 100" becomes ordinary filter conditions.
- **Any model:** one running inside Tabula, offline, with nothing to install; Apple Intelligence; Claude; any OpenAI-compatible API; Ollama; or Claude Code and Codex.
- **You decide what it sees.** Rows reach the model only from the chat's read-only queries, at most 50 per query, and AI is off for Production connections unless you allow it.

<p align="center"><img src="docs/screenshots/ai.png" width="900" alt="The AI chat answering with a query, and a model-written suggestion in grey in the SQL editor"></p>

### AI agents (MCP)

- Claude Code, Codex, Cursor and other MCP clients can list the connections you allow, describe tables and run read-only queries through Tabula, with the chat's limits and the same approval on Production.
- Agents never see passwords, and every connection is closed to them until you allow it. [Setup](#setting-up-ai-agents-mcp).

### MongoDB

- Collections in the grid, with nested values inline and BSON types in Row Details. Filter with the builder or a query document.
- Edits keep their types: a `NumberLong` stays a long, a date a date. Edit a whole document as JSON, and preview the `updateOne` / `deleteOne` commands first.
- The query editor runs shell statements: `find`, `aggregate`, `updateMany`, `createIndex`, `show dbs`, `use`, `db.runCommand(…)`.
- Atlas (`mongodb+srv`), replica sets, TLS and SCRAM. [More](#mongodb-in-detail).

<p align="center"><img src="docs/screenshots/mongodb.png" width="900" alt="A MongoDB collection in the grid, with typed fields in the row details panel"></p>

### Redis

- **Keys** are listed with `SCAN`, never `KEYS`, so this is safe on large production instances: type, TTL, size and a preview, filtered by a pattern such as `user:*` or by type, loading more as you scroll. The sidebar lists databases with their key counts.
- **Values:** strings in an editor (Format JSON, ⌘S saves and keeps the TTL); hashes, lists, sets, sorted sets and streams in a grid, with *Load more* for big ones. Double-click to edit a key, TTL, short value or cell in place. **Changes are written to Redis immediately.** Strings over 1 MB and binary values are read-only; use the console for them.
- **Key details:** size, memory usage, encoding and TTL. Set or remove an expiry, or rename (never over another key).
- **Console** (⌘T), as in `redis-cli`, with quotes, escapes and history; `SELECT` switches the sidebar too. It refuses `SUBSCRIBE`, `MONITOR` and blocking commands with no timeout, which would freeze the connection, asks before `FLUSHALL`, `FLUSHDB` and `SHUTDOWN`, and on Production before any command not known to only read.
- **Metrics** from `INFO`: memory, clients, throughput, hit rate, persistence and keyspace.

<p align="center"><img src="docs/screenshots/redis.png" width="820" alt="Redis keys and a hash value"></p>

## Install

> **Why macOS warns you.** Tabula is free and not yet signed with an Apple Developer ID or notarized by Apple, so macOS cannot confirm who made it and blocks the first launch with a message such as *"Apple could not verify 'Tabula' is free of malware"* or *"'Tabula' cannot be opened because the developer cannot be verified"*. The steps below tell macOS you trust this app. You do this once per installed version.

**Requirements:** macOS 14 Sonoma or later, on an Apple silicon or Intel Mac. Tabula is developed and mostly tested on macOS 26 Tahoe; please [report](#reporting-a-problem) anything that misbehaves on 14 or 15.

### 1. Download and verify

1. From the [latest release](https://github.com/tungnguyenvan/tabula/releases/latest), download `Tabula-<version>.dmg` and `SHA256SUMS.txt` into the same folder.
2. Check that the download is intact and unmodified:
   ```bash
   cd ~/Downloads
   shasum -a 256 -c SHA256SUMS.txt --ignore-missing
   ```
   You should see `Tabula-<version>.dmg: OK`. If not, delete the file and download it again.

### 2. Copy to Applications

Open the DMG and drag **Tabula** onto the **Applications** folder. Then eject the DMG. Don't run Tabula from inside the DMG.

### 3. First launch

**macOS 15 Sequoia and later (including 26 Tahoe)**
1. Open **Applications** and double-click **Tabula**. macOS refuses to open it. Click **Done** (not *Move to Trash*).
2. Open **System Settings › Privacy & Security** and scroll down to **Security**.
3. Next to *"Tabula" was blocked to protect your Mac*, click **Open Anyway**.
4. Confirm with **Open Anyway** again, then enter your Mac password or use Touch ID.

The *Open Anyway* button stays available for about an hour after the blocked attempt. If it isn't there, double-click Tabula again first.

**macOS 14 Sonoma**
1. In **Applications**, Control-click (or right-click) **Tabula** and choose **Open**.
2. In the dialog, click **Open**.

After the first successful launch, Tabula opens normally with a double-click.

### Alternative: Terminal

If you prefer, remove the download quarantine flag instead of using System Settings:

```bash
xattr -dr com.apple.quarantine /Applications/Tabula.app
```

Only do this for a copy you downloaded from this repository and verified in step 1.

### After launching

- **Saved passwords:** macOS may ask whether Tabula may use its Keychain item. Choose **Always Allow**. All connections share one item, so one **Always Allow** covers every connection. Tabula isn't signed with an Apple Developer ID, so macOS may ask again after an update; the Keychain is what keeps your database passwords safe. If you choose Deny, connections fail to authenticate; edit the connection and enter the password again.
- **Local network (macOS 15 and later):** the first connection to a server on your local network (such as `192.168.x.x` or `10.x.x.x`) asks for permission. Choose **Allow**. If you denied it, connections fail with "No route to host"; turn it on in **System Settings › Privacy & Security › Local Network**. `localhost`, Docker port forwards and internet hosts aren't affected.

### Updating

Tabula checks this repository's [latest release](https://github.com/tungnguyenvan/tabula/releases/latest) at launch, at most once a day (turn this off in Settings), and from **Tabula › Check for Updates…**. It shows the release notes, and you can **Install and Relaunch**, open the release page, or skip that version. Installing downloads `Tabula-<version>.zip` and `SHA256SUMS.txt` from the release, refuses the download unless its SHA-256 matches, the bundle identifier and version are right and the code signature is valid, then replaces the app where it is and relaunches. If copying fails, the previous version is put back.

The checksum and the archive come from the same GitHub release, so this protects against corrupted or tampered downloads in transit, not against a compromised repository. Tabula needs write access to the folder it runs from, so it can't update itself while running from the DMG or from a location macOS moved it to ("App Translocation"). Move it to Applications first.

To update by hand, drag the new version to Applications, replacing the old one; saved connections are kept. Version 0.1.0 has no updater, so install a newer one by hand once.

### Uninstalling

Delete **Tabula** from Applications. To also remove saved connections, delete `~/Library/Application Support/Tabula`. Saved passwords are in **Keychain Access**, under the service `app.tabula.connections` (AI API keys under `app.tabula.ai`).

### Reporting a problem

**Help › Report a Problem…** opens a new issue on this repository in your browser, with Tabula's version and build, the macOS version and the kind of Mac filled in. Tabula sends nothing itself: you read and edit the issue before submitting it.

## Getting started

1. Click **New Connection** (⌘N) and pick a type, or paste a connection string. PostgreSQL uses the user name when Database is empty. On MySQL / MariaDB the database is optional; switch it from the sidebar. For SQLite, choose a file or create one. For Redis, User is optional (an ACL user on Redis 6 and later; empty for `requirepass`) and Database is the index, 0 by default. For MongoDB, see [MongoDB in detail](#mongodb-in-detail).
2. Choose a **tag**, so a Production connection is obvious at a glance.
3. Click **Test**, then **Connect**, or double-click a saved connection.

> **MySQL 8 and TLS:** accounts that use `caching_sha2_password`, the MySQL 8 default, can only authenticate over an encrypted connection, so new MySQL connections default to TLS **Required**. If the server has no TLS, switch the account to `mysql_native_password` or enable TLS on the server.

## Connections in detail

### SSH tunnels

Turn on **Connect over SSH** (PostgreSQL, MySQL) to reach a database through an SSH server (a bastion). Host is then the database as the SSH server sees it, such as `localhost`.

- Tabula runs the system's `/usr/bin/ssh` with key authentication only: keys from ssh-agent, `~/.ssh`, or a key file you choose. Add a key with a passphrase to ssh-agent first (`ssh-add`). No SSH password or passphrase is stored.
- The server's host key must already be in `~/.ssh/known_hosts`; connect once with `ssh` in Terminal to check and save it. `~/.ssh/config` isn't read, so enter the real host name, port and user.
- The tunnel listens on 127.0.0.1 only and closes with the connection or when Tabula quits. **Verify certificate** needs a database host name, not an IP address, so TLS checks the database's real identity rather than the tunnel's.

**TLS:** **Verify certificate** checks the server against the macOS trust store. Databases with a private CA (such as AWS RDS, or self-signed certificates) fail until that CA is added to Keychain Access and trusted. **Required** encrypts without checking the certificate.

### Connection strings

**Connection String…** (⇧⌘N) in the Connections window, paste (⌘V) into the connection list, or type one in the Host field. A summary shows what was read before **Continue** fills in the form, password included. Tabula never reads the clipboard by itself. It accepts `postgresql://`, `mysql://`, `redis://`, `rediss://`, `mongodb://`, `mongodb+srv://` and `file://` URLs (and those TablePlus copies), JDBC URLs, libpq `key=value` strings and .NET-style `Server=…;Uid=…;Pwd=…` strings. URL escapes are decoded (`p%3Fss` becomes `p?ss`). A password that still holds escapes, as some dashboards show them, gets a **Decode** button, and a failed login says when escapes are the likely cause.

### Dump and restore

**File › Dump Database…** (or **Dump Table…** in the sidebar) and **File › Restore from Dump…**, for PostgreSQL and MySQL.

- Tabula uses the newest `pg_dump`, `pg_restore`, `psql`, `mysqldump` and `mysql` (or MariaDB's) it finds in Postgres.app, Homebrew and your PATH; pg_dump must be at least as new as the server. If one is missing, the sheet says how to install it.
- Dumps: structure, data or both; PostgreSQL as a SQL script or a custom archive; optional DROP statements and, on PostgreSQL, owners and privileges. A failed or stopped dump leaves no file behind.
- Restores stop at the first error. On PostgreSQL they run in one transaction by default, so a failure changes nothing. Production connections ask you to type the database name. Scripts can't run commands on your Mac: PostgreSQL scripts with psql commands such as `\!` are refused (pg_dump's `\restrict` is allowed), and the mysql client's `system` command and local file loading are off. **Restore only dumps you trust:** they can contain any SQL.
- Passwords reach the tools through the environment (PostgreSQL) or a private temporary option file (MySQL), never the command line. `~/.my.cnf`, MySQL login paths, `~/.psqlrc` and `PG*` / `MYSQL_*` variables aren't used. SSH connections go through the tunnel.
- The `transaction_timeout` setting pg_dump 17 writes is left out when restoring into PostgreSQL 16 or older, which reject it.

## Editing in detail

Sorting, filtering, paging or closing a tab asks first if it would throw away uncommitted edits. Pasted rows are matched to columns by name when the first line is a header, otherwise in order; `NULL` pastes as NULL, generated columns are left to the server, and a single value goes into the selected cell.

### Tables without a primary key

Rows are found by the shortest unique index whose columns are all NOT NULL, or else by SQLite's `rowid` or PostgreSQL's `ctid`. The bottom bar says which ("Rows identified by ctid"). A `ctid` changes when its row is updated, so editing or deleting a row someone changed since the page loaded fails the commit and nothing is saved; the page reloads after each commit. A MySQL / MariaDB table with no such index stays read-only apart from adding rows, and the bottom bar says so. Duplicating a row leaves its identifying unique columns empty, as it does a primary key.

### Editing query results

Double-click a cell in a result from one table that includes its whole primary key, such as `SELECT id, name, price FROM products` (PostgreSQL, MySQL InnoDB, SQLite). Edits wait for **Commit** (⌘S), **Preview** or **Discard**, as in a table tab.

- Changes commit in one transaction on a separate connection, and a row someone else changed since the query ran is reported, not overwritten. Production connections ask first. Joins, views, grouping, functions and computed columns stay read-only, as do key and generated columns.
- **MySQL:** integer, DECIMAL and text columns, when Tabula can prove the InnoDB table's identity (this needs the PROCESS privilege). Otherwise, and for temporary tables or names MySQL stores encoded (such as names with hyphens), the result says **Read-only** and why. Triggers run normally, but their non-transactional side effects can't be rolled back.
- **SQLite:** INTEGER, REAL, NUMERIC and text columns; BLOB, untyped and generated columns, views and virtual tables stay read-only.
- The table's identity is captured when the result is checked for editing, not atomically with the SELECT, so an identical replacement in between can't be told apart.

### Importing files

**File › Import…** in a table tab, or **Import…** in the sidebar's context menu. Columns are matched by name (ignoring case, accents, spaces, `_` and `-`), and you can pick another or skip one; a header row is detected and can be turned off. The rows become new rows in the grid, committed in one transaction with ⌘S.

- **CSV and TSV** as RFC 4180 writes them, in UTF-8 (with or without a byte order mark), UTF-16 with one, or Windows-1252. An empty field is NULL where allowed (else the column's default, or empty text); `""` is empty text and unquoted `NULL` is NULL. Tabula's exports quote empty text and the text `NULL`, so they import back unchanged.
- **JSON:** an array of objects. Numbers keep every digit, nested values become JSON text, `null` is NULL, and a missing field takes the column's default.
- Up to 100,000 rows and 256 MB per file; larger files are refused. Generated columns are left to the database.

## Queries in detail

### Running and stopping

- Stop (⌘.) cancels the statement on the server and skips the rest of the script. Tabula never commits or rolls back your transaction for you. SQLite rolls back an open transaction when the stopped statement was changing rows; documents a stopped MongoDB command already changed stay changed. MongoDB needs 4.4 or later.
- In the Redis console, Stop ends a Lua script or function once it has run for 5 seconds (on a shared server it stops whichever script is running, so Production asks first) and unblocks a waiting command such as `BLPOP`.
- The Limit (100 to 5,000, or none) leaves statements that already limit themselves, writes and `FOR UPDATE` alone.

### Query plans

Explain uses PostgreSQL `EXPLAIN (VERBOSE, FORMAT JSON)`, MySQL `EXPLAIN FORMAT=JSON` and SQLite `EXPLAIN QUERY PLAN` (no estimates). Explain Analyze uses PostgreSQL `EXPLAIN (ANALYZE, BUFFERS)`, MySQL 8.0.18+ `EXPLAIN ANALYZE` and MariaDB `ANALYZE FORMAT=JSON`.

- A statement that only reads runs as Run would. On PostgreSQL, any other statement runs on a separate connection in a transaction that is rolled back, after Tabula asks, since sequences and other effects outside the transaction stay. MySQL, which commits some statements on its own, analyzes only statements that read.
- The **Share** column is each operation's own part of the time (or, without Analyze, the cost): a quarter or more is orange, half or more red. **Copy Plan** copies the plan as the server returned it.
- **Ask AI about This Plan** sends the statement, the plan, and the tables' names, column types and indexes, never rows.

### Find in Database

Searches every table of the current schema, or the ones you tick (views only when ticked). Text columns contain the value, ignoring case (and accents on MySQL); numeric, UUID, date and binary (`\xcafe`, `0xcafe`) columns must equal it; other columns are skipped. On MongoDB, string fields are searched. Rows are counted up to 1,000. Tables are searched one at a time on a separate read-only connection, with a one-minute limit per statement; Stop (⌘.) ends the search, and Production connections ask first.

## AI assistant in detail

<p align="center"><img src="docs/screenshots/ai-settings.png" width="520" alt="Settings › AI with a model running in Tabula for Ask AI and suggestions"></p>

Turn AI on in **Settings › AI** (⌘,). The chat panel's title lists earlier conversations, and the pencil starts a new one. Answers stream in, with the model's reasoning shown while it thinks; for models that reason, an **Effort** menu sets how long. The model is told table names as SQL needs them (`dev.transactions`), column types, keys and the default schema. Each system prompt can be edited in **Settings › AI › Instructions** (`{database}` stands for the database's name).

### Read-only queries

To answer, the chat can list and describe tables, search saved queries and run a read-only query; each step shows in the conversation. Tabula runs the steps itself, for every provider (Claude Code and Codex keep their own tools off).

- Only reads run: one `SELECT`, `WITH … SELECT`, `EXPLAIN`, `SHOW` or `DESCRIBE`, without comments, backslashes or server functions such as `pg_terminate_backend` and `query_to_xml`; on MongoDB `find`, `aggregate` (without `$out` / `$merge`), `countDocuments` and `distinct`, without `$where` / `$function`. Anything else is refused, and the assistant writes it as SQL for you to run.
- They run on a separate connection, each in a read-only transaction (PostgreSQL, MySQL) or with SQLite's `query_only`, stopped after 15 seconds on every database, so they can't change data or touch your transactions. They appear in the console log.
- At most 50 rows of each result, with long values cut, go to the model.
- On **Production** connections the chat asks before each query (**Allow** / **Don't Allow**).
- **Let the chat run read-only queries** in Settings › AI turns them off; the assistant then sees only the structure. It is on for new setups, and stays off if you used AI before the chat could run queries, until you turn it on.

<p align="center"><img src="docs/screenshots/ai-tools.png" width="820" alt="The chat answering from the real data: it ran an aggregate on MongoDB, shown as a step above the answer"></p>

### Proposed data changes

Off by default (**Let the chat propose data changes**). Tabula never runs a statement the model wrote: it checks every table, column and primary key against the real table, opens the table's tab filtered by primary key to exactly those rows, and adds the changes as uncommitted edits. Preview with ⇧⌘S, take them back with ⌘Z or Discard, commit with ⌘S; Production still asks before the commit. PostgreSQL, MySQL / MariaDB and SQLite tables with a primary key, at most 500 rows at a time, and not while the tab holds edits of your own.

### Visual answers

Charts (bar, line, area, point, pie), result grids with **Open in Query Tab**, metric cards, forms for queries with placeholders (filled in as quoted values and run read-only), choices that send your reply, and diagrams of the tables involved. The model can only describe components from this fixed set. Charts, grids and cards carry a query, not data: Tabula runs it with the chat's rules (read-only check, separate connection, 15 seconds, **Allow** on Production, console log) and reads up to 5,000 rows for drawing, which aren't sent to the model. Results are saved with the conversation, and the refresh button runs the query again. **Visual answers** in Settings › AI turns them off.

### In the editor and the filter bar

- **Ask AI** (⌘K) inserts SQL at the cursor, or replaces the selection with the change you describe; ⌘Z undoes it.
- **Fix with AI**, under an error, replaces the failing statement with a corrected one.
- **Suggestions while typing** replace the built-in grey suggestion (⎋ still lists those). Models on this Mac are asked after a 0.25 s pause and, when they support it (Qwen2.5 Coder does), fill in between the text before and after the cursor. Suggestions can use their own provider: a small local model such as `qwen2.5-coder:0.5b` keeps up with typing, where command-line agents and large hosted models can't.
- **Filter by description:** the sparkles button in a table's filter bar takes a description in any language ("khách ở Hà Nội tạo trong tháng này"). The conditions it produces replace the bar's and are applied; ⌘Z brings back the previous filter. Each condition is checked: the column must exist, the operator be one of the filter's, and the value read as the column's type; dates are written as the column compares them, in your time zone. What conditions can't express ("the top 10 by total") is answered with the reason. PostgreSQL, MySQL / MariaDB, SQLite and MongoDB.

### Providers

| Provider | Runs | Setup |
| --- | --- | --- |
| Model on this Mac | Inside Tabula, offline | Nothing to install. Download one in Settings › AI (Qwen2.5 Coder 0.5B to 7B, Llama 3.2 1B and 3B; from about 490 MB), add a GGUF file, or paste a link. Downloads are checked against their published SHA-256. GPU on Apple silicon, CPU on Intel. |
| Apple Intelligence | On the Mac, offline | macOS 26 with Apple Intelligence on |
| Ollama | On the Mac | Install [Ollama](https://ollama.com/download), then download a model in Settings › AI: `qwen2.5-coder:0.5b` (about 0.4 GB), `deepseek-coder:1.3b` or `qwen2.5-coder:1.5b` for suggestions; `qwen2.5-coder:3b`, `qwen2.5-coder:7b` or `sqlcoder:7b` for whole queries. |
| OpenAI-compatible API | Your server or a provider | Base URL, API key and model: LiteLLM, LM Studio, llama.cpp, vLLM, OpenAI and others |
| Claude API | Anthropic | API key; Opus, Sonnet or Haiku 5.5 (default `claude-opus-5-5`; a faster one can be set for suggestions) |
| Claude Code, Codex | Your installed agent, with its own sign-in | Installed and signed in once in Terminal. Run without tools (Claude Code) or in a read-only sandbox (Codex). Too slow for suggestions. |

### What is sent

- Table and column names of the current schema, and the SQL around the cursor (or the selection).
- For Ask AI about This Plan, the statement, plan and the tables' indexes; for a described filter, the table's columns, today's date and the time zone; for Fix with AI, the error message with quoted values removed (errors can quote row values, such as a duplicate key).
- **Rows only from the chat's read-only queries**, at most 50 per query and only with that setting on. Ask AI, Fix with AI, suggestions and described filters never see rows.
- **AI is off for Production connections** unless you allow it in Settings.
- Conversations stay on this Mac in `~/Library/Application Support/Tabula/Chats` and are deleted with their connection. Prompts reach command-line agents on standard input, not as arguments other users could see. API keys are kept in the login Keychain.

## Setting up AI agents (MCP)

An agent working on your code can check the real schema and data. Tabula opens the connections itself, with the passwords from the Keychain; the agent never sees them.

1. In **Settings › AI › AI agents (MCP)**, turn on **Let AI agents use connections**.
2. Edit each connection agents may use and turn on **Allow AI agents (MCP)**. It is off for every connection until you do, and not available for Redis.
3. Add Tabula to your agent with the command Settings shows (**Copy**):
   - Claude Code: `claude mcp add tabula -- /Applications/Tabula.app/Contents/MacOS/tabula-mcp`
   - Codex: `codex mcp add tabula -- /Applications/Tabula.app/Contents/MacOS/tabula-mcp`
   - Cursor and others: `{"mcpServers":{"tabula":{"command":"/Applications/Tabula.app/Contents/MacOS/tabula-mcp"}}}`

The agent gets four tools: `list_connections` (name, kind and tag of the allowed ones), `list_tables`, `describe_table` and `run_read_only_query`, with the chat's limits: only reads, on a separate read-only connection, in a read-only transaction where the database has one, 15 seconds, at most 50 rows with long values cut. On **Production** connections Tabula asks before each query. Every statement an agent runs appears in the console log, marked with a sparkles symbol and the agent's name.

`tabula-mcp` speaks MCP (the 2026-07-28 revision, and earlier ones that start with `initialize`) on standard input and output. It has no database code and never reads the Keychain: it passes each call to the running Tabula over a socket in `~/Library/Application Support/Tabula` that only your user can open. When Tabula isn't open, or agents are off, the tools answer "Open Tabula to use its connections".

## MongoDB in detail

<p align="center"><img src="docs/screenshots/mongodb-connection.png" width="520" alt="A MongoDB connection to an Atlas cluster: DNS seed list, user, database, auth database and TLS"></p>

- **Hosts:** one, or several (`a:27017,b:27017`) for a replica set; if the first is down, the next is tried. For Atlas, turn on **DNS seed list (mongodb+srv)** and TLS is on by default. Tabula resolves the seed list with the Mac's resolver and refuses servers outside its domain, so a spoofed DNS answer can't redirect the connection. Options in the seed list's TXT record aren't read; set the auth database if it isn't `admin`.
- **User and password** are optional. **Auth database** (`authSource`) defaults to `admin`; **Database**, the one opened first, to `test`, and the sidebar's picker lists every database you may see. SCRAM-SHA-1 or SCRAM-SHA-256.
- **Filter:** `=` on `42` matches the number or the string, on a 24-digit hex id the ObjectId or the string; `contains` and the like are case-insensitive; fields can be paths such as `address.city`. The `{ }` button takes a query document instead.
- **Edits keep the field's type:** `46` in a long field is stored as `NumberLong(46)`, `2025-02-03` in a date field as a date. To change a type, type a shell value such as `NumberDecimal("9.99")`. Commit sends `updateOne` / `deleteOne` / `insertOne` by `_id`, one by one; if one fails, the message says which were saved. **`{ }`** edits the whole document as JSON, replaced by `_id`.
- **Structure** shows the fields of the first 100 documents with their types, and indexes with their options. AI is told sampled field names; documents reach it only from the chat's read-only queries.

<p align="center"><img src="docs/screenshots/mongodb-document.png" width="560" alt="The JSON document editor: a whole order with ObjectId, NumberDecimal and ISODate values"></p>

The query editor takes shell statements, one per line or separated by `;`, which may continue on the next line with `.sort(…)` and the like:

```js
use shop
db.orders.find({ status: "paid", total: { $gte: NumberDecimal("100") } }, { items: 0 }).sort({ createdAt: -1 })
db.orders.aggregate([{ $group: { _id: "$status", n: { $sum: 1 } } }, { $sort: { n: -1 } }])
db.getCollection("audit log").countDocuments({ at: { $gte: ISODate("2026-01-01") } })
```

<p align="center"><img src="docs/screenshots/mongodb-query.png" width="820" alt="An aggregation in the MongoDB query editor, with its results and the console log"></p>

- **Collections:** `find` / `findOne` (with `sort`, `skip`, `limit`, `projection`, `hint`, `collation`, `count()`, `explain()`), `aggregate`, `countDocuments`, `estimatedDocumentCount`, `distinct`, `insertOne` / `insertMany`, `updateOne` / `updateMany` / `replaceOne`, `deleteOne` / `deleteMany`, `findOneAndUpdate` / `Replace` / `Delete`, `createIndex(es)`, `dropIndex(es)`, `getIndexes`, `drop`, `renameCollection`, `stats`.
- **Databases:** `runCommand`, `adminCommand`, `getCollectionNames`, `getCollectionInfos`, `createCollection`, `createView`, `dropDatabase`, `stats`, `serverStatus`, `version`, `currentOp`, `getUsers`, `getRoles`, `getSiblingDB("other")`, and `show dbs`, `show collections`, `show users`, `use <db>`.
- **Values:** JSON, the shell's relaxed syntax (unquoted keys, single quotes, trailing commas, comments, `/regex/i`), `ObjectId`, `ISODate` / `new Date`, `NumberLong`, `NumberInt`, `NumberDecimal`, `UUID`, `BinData`, `Timestamp`, `MinKey` / `MaxKey`, and Extended JSON.
- Tabula reads these statements and sends the matching commands; it doesn't run JavaScript. Results show at most 50,000 documents per statement, and the row limit adds `.limit()` to finds and aggregations without one.

## Size and resource use

Measured on an Apple M2 with macOS 26.1: memory with 0.4.0, sizes with 0.5.0, in decimal megabytes.

| | |
| --- | --- |
| Download | 24.0 MB (ZIP), 27.4 MB (DMG) |
| Installed | 62 MB: the app 37 MB and llama.cpp, for local models, 23 MB. One universal app for Apple silicon and Intel. Downloaded models are stored separately. |
| Memory | 28 MB with only the Connections window · 81 MB with a Postgres table open (300 rows) · 79 MB with a MongoDB collection (300 documents) · 70 MB with Postgres, MySQL and Redis connections open |
| CPU idle / metrics refreshing every 3 s | 0% / about 1% |

Memory is the footprint macOS reports, as Activity Monitor shows it. A 5,000-row page takes only a few MB more than 300 rows, because the grid draws just the rows on screen. A model running in Tabula adds about its file size while loaded (0.5 GB for Qwen2.5 Coder 0.5B) and is released after five minutes unused. [docs/benchmarks.md](docs/benchmarks.md) times connecting, paging, sorting, filtering, counting, a 50,000-row result and commits on every database with 100,000-row tables: a 300-row page loads in 0.2 to 4 ms, a 5,000-row page in 4 to 43 ms.

## Keyboard shortcuts

All of these are also in **Help › Keyboard Shortcuts** (⇧⌘/).

| Area | Shortcuts |
| --- | --- |
| Connections | ⌘N new connection · ⇧⌘N connection string (Connections window) · ⇧⌘K connections · ⌃⌘] / ⌃⌘[ next / previous connection · ⌘, settings |
| Tabs | ⌘T new query · ⌘W close tab (or window) · ⇧⌘T reopen closed tab · ⌘O open .sql files · ⌘1…⌘8 go to tab, ⌘9 last tab · ⌃Tab or ⇧⌘] next tab · ⌃⇧Tab or ⇧⌘[ previous tab · ⌘P open anything |
| Browsing | ⌥⌘F filter tables · ↑↓ preview a table, ↩ or double-click to keep it · ⌥⌘1 / ⌥⌘2 Data / Structure · ⌥⌘3 diagram · ⌥⌘4 metrics · ⌘F filter rows (again to focus it) · ⎋ hide the filter · ⇧⌘F find in database · ⌘R refresh · ⌘[ / ⌘] previous / next page |
| Panels | ⌥⌘0 row details · ⌥⌘A AI chat · ⌥⌘L saved queries · ⇧⌘C console log |
| Data grid | ← → ↑ ↓ move · Tab / ⇧Tab next / previous cell · ⌘← ⌘→ ⌘↑ ⌘↓ first / last column or row · ↩ or F2 edit · type to replace · Space quick look · ⌥⌫ set NULL · ⌫ delete rows · ⌘A select all · ⌘C copy rows · ⌥⇧⌘C copy with headers · ⌥⌘C copy cell · ⌘V paste rows |
| Editing a cell | ↩ save and move down · Tab / ⇧Tab save and edit next / previous · ⌥↩ new line · ⎋ cancel |
| Changes | ⌘I add row · ⌘D duplicate row · ⌘Z / ⇧⌘Z undo / redo · ⌘S commit · ⇧⌘S preview SQL · ⌥⌘Z discard all |
| SQL editor | ⌘↩ run selection or statement · ⇧⌘↩ run all · ⌘. stop query or search · ⌥⌘E explain · ⌥⇧⌘E explain analyze · ⌘S commit result edits, otherwise save · ⇧⌘S save as · ⌥⌘S save to library · Tab accept suggestion · ⎋ or ⌃Space suggestions · ⌘K ask AI · ⇧⌘I beautify · ⌘/ toggle comment · ⌘F find · ⌘Z / ⇧⌘Z undo / redo |
| Redis | ⌘T console · ↑↓ console history · ⌘. stop a script or blocking command · ⌘F key pattern · ⌘R refresh · ⌘N new key · ⌘I add element · ⌘S save string · ⌫ delete key or elements |

## Your data

- **Connection settings:** `~/Library/Application Support/Tabula/connections.json`, never with passwords.
- **Passwords:** the login Keychain, service `app.tabula.connections`. Deleting a connection deletes its password. AI API keys are in the Keychain too.
- **Open tabs** (query SQL, open tables, filters, schema, history): `~/Library/Application Support/Tabula/Workspaces`, deleted with their connection, or all of them when you turn off **Reopen tabs when connecting** in Settings › General.
- **Saved queries**, **AI conversations** and **local models** are in the `Queries`, `Chats` and `Models` folders of `~/Library/Application Support/Tabula`. Conversations are deleted with their connection; delete models there or in Settings › AI.
- **Network:** Tabula connects to the databases you configure, and to `api.github.com` / `github.com` for updates. With AI on, it also talks to the provider you chose ([what is sent](#what-is-sent)); with AI agents on, the agents you set up read what their tools return. No telemetry, no account.

## Known limitations

- MySQL / MariaDB: `CALL` of a procedure that returns several result sets shows the first one.
- Stop ends a MongoDB command only on version 4.4 or later. In the Redis console it ends a script once it has run for 5 seconds and unblocks a waiting command such as `BLPOP`; other Redis commands run to the end.
- Editing existing rows of a MySQL / MariaDB table needs a primary key or a unique index on NOT NULL columns; without either, rows can only be added. Query results stay editable only when they include the whole primary key: a unique index or `ctid` isn't used there.
- SQLite's `VACUUM` can renumber the `rowid` of a table without an `INTEGER PRIMARY KEY`; reload an open table after running one before editing it.
- Redis Cluster and Sentinel aren't supported yet; connect to a single node. Pub/Sub, `MONITOR`, `MULTI` and `WATCH` are not available in the console, which shares its connection with the key browser; `EVAL` runs several commands at once.
- MongoDB: the query editor runs shell statements, not JavaScript. Edits from the grid aren't wrapped in a transaction. X.509, LDAP and Kerberos authentication aren't supported. The grid's columns come from the first 100 documents, so a field that appears only later shows up after it is seen on a page. Files can't be imported into collections yet.

See [CHANGELOG.md](CHANGELOG.md) for release history.

## License

Tabula is released under the [MIT License](LICENSE). Copyright © 2026 Nguyen Van Tung.

Tabula bundles open-source components: PostgresNIO and MySQLNIO (MIT), RediStack, SwiftNIO, swift-nio-ssl, swift-crypto and related Apple packages (Apache 2.0, some of which include BoringSSL). Their full license texts and NOTICE files are in [`Resources/THIRD_PARTY_NOTICES.txt`](Resources/THIRD_PARTY_NOTICES.txt). The same file ships inside the app, at `Tabula.app/Contents/Resources`, and is linked from **Tabula › About Tabula**.
