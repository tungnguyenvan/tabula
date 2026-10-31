<p align="center"><img src="docs/icon.png" width="96" alt="Tabula icon"></p>

<h1 align="center">Tabula</h1>

<p align="center">A fast, native macOS database client with an AI assistant that works on your real data, safely.<br>
<b>PostgreSQL</b>, <b>MySQL / MariaDB</b>, <b>SQLite</b>, <b>MongoDB</b> and <b>Redis</b>. Free, no usage limits, keyboard-first.</p>

<p align="center"><a href="https://github.com/tungnguyenvan/tabula/releases/latest"><b>Download</b></a> · <a href="https://github.com/tungnguyenvan/tabula/releases/download/v0.5.1/Tabula-demo.mp4">Demo video</a> · <a href="https://github.com/tungnguyenvan/tabula/releases/download/v0.15.0/Tabula-whats-new-0.15.mp4">What's new in 0.15</a> · <a href="CHANGELOG.md">Changelog</a> · <a href="LICENSE">MIT License</a></p>

<div align="center">

https://github.com/user-attachments/assets/24917ff7-76bb-482f-a36c-bfc87224b393

<sub>The demo (44 s): Tabula driven by real clicks and keys. <a href="https://github.com/tungnguyenvan/tabula/releases/download/v0.5.1/Tabula-demo.mp4">Full quality, 1080p at 60 fps</a>.<br>
New in 0.15: <a href="https://github.com/tungnguyenvan/tabula/releases/download/v0.15.0/Tabula-whats-new-0.15.mp4">a short video of what's new</a>.</sub>

</div>

<p align="center"><img src="docs/screenshots/hero.png" width="900" alt="Tabula with a Redis and a PostgreSQL connection open, browsing a table with the row details panel"></p>

## Why Tabula

- **AI that works on your real database, safely.** The assistant answers from read-only queries on its own read-only connection, proposes data changes as edits you review and commit, and asks before each query on Production.
- **Answers you can use.** Charts, grids and forms in the chat that you can pin to a live dashboard, filters written from a description, realistic test rows that respect your constraints, and Explain plans with index advice.
- **Your coding agents, connected.** Claude Code, Codex and Cursor can use the connections you allow through MCP, without ever seeing a password.
- **Your choice of model.** One running inside Tabula, offline; Apple Intelligence; Claude; any OpenAI-compatible API; Ollama; or Claude Code and Codex.
- **Native and fast.** A real Mac app: under 100 MB of memory with a table open, no CPU when idle, a 5,000-row page in under 50 ms ([benchmarks](docs/benchmarks.md)).
- **Safe, private and free.** Edits wait until you preview and commit them in one transaction, and a `DELETE` without `WHERE` or a table-rewriting `ALTER` is caught before it runs, with an AI review on request. Passwords stay in the Keychain; no account, no telemetry, MIT licensed.

## Contents

- [Features](#features): [AI assistant](#ai-assistant) · [AI agents (MCP)](#ai-agents-mcp) · [Connect](#connect) · [Browse & edit](#browse--edit) · [Query](#query) · [Performance](#performance) · [Find & import](#find--import) · [Schema](#schema) · [MongoDB](#mongodb) · [Redis](#redis) · [Updates & help](#updates--help)
- [Install](#install)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Your data & privacy](#your-data--privacy)
- [Known limitations](#known-limitations)
- [License](#license)
- Guides: [connections](docs/connections.md) · [editing](docs/editing.md) · [queries](docs/queries.md) · [schema](docs/schema.md) · [AI assistant](docs/ai.md) · [AI agents](docs/mcp.md) · [MongoDB](docs/mongodb.md) · [Redis](docs/redis.md) · [install](docs/install.md) · [shortcuts](docs/shortcuts.md)

## Features

### AI assistant

Off until you turn it on in **Settings › AI**. [How it works](docs/ai.md).

- **Chat** (⌥⌘A) that knows your tables and keys, looks things up with read-only queries, shows every step and saves conversations per connection.
- **Queries you can use:** **Insert**, **Run** or copy what it writes; it can also search your saved queries.
- **Proposed data changes** (opt-in): "mark order 42 as shipped" becomes uncommitted edits in the table's tab, for you to preview and commit.
- **Visual answers:** charts, result grids, metric cards, query forms, clickable choices and table diagrams, drawn from queries Tabula runs itself, so a chart can't show made-up numbers.
- **Dashboard** (⌥⌘5): pin charts, metric cards and grids from the chat to a per-connection dashboard that refreshes them read-only, on demand or every few minutes. [Dashboard](docs/ai.md#dashboard).
- **Filter by description:** "customers in London who joined this month" becomes ordinary filter conditions, each checked against the table.
- **Generate test rows:** "customers in Europe, half of them VIP" becomes up to 500 new rows, each value checked against its column's type, keys and constraints, to preview and commit.
- **Ask AI** (⌘K) writes or changes SQL in the editor, **Fix with AI** repairs a failed statement, and **inline suggestions** appear in grey as you type.
- **Ask AI about This Plan** explains a query plan and suggests `CREATE INDEX` statements, without running anything.
- **Any model**, with its reasoning shown as it thinks: on-device in Tabula (nothing to install), Apple Intelligence, Claude, OpenAI-compatible, Ollama, Claude Code or Codex. [Providers](docs/ai.md#providers).

**What the AI sees**

- Table and column names, and the SQL you're working on. **No rows**, except the results of the chat's read-only queries: at most 50 rows each, and you can turn them off.
- **Production asks first:** before each query from the chat or an agent. AI is off for Production connections unless you allow it.
- **Off until you turn it on**, and you choose the provider. [Exactly what is sent](docs/ai.md#what-is-sent).

<p align="center"><img src="docs/screenshots/ai.png" width="900" alt="The AI chat answering with a query, and a model-written suggestion in grey in the SQL editor"></p>

<p align="center"><img src="docs/screenshots/ai-tools.png" width="820" alt="The chat answering from the real data: it ran an aggregate on MongoDB, shown as a step above the answer"></p>

<p align="center"><img src="docs/screenshots/ai-settings.png" width="520" alt="Settings › AI with a model running in Tabula for Ask AI and suggestions"></p>

### AI agents (MCP)

- Claude Code, Codex, Cursor and other MCP clients can list the connections you allow, describe tables and run read-only queries through Tabula.
- Same limits as the chat: a read-only connection and transaction, 15 seconds, 50 rows, and Tabula asks before each query on Production.
- Agents never see passwords, every connection is closed to them until you allow it, and their statements are in the console log with the agent's name.
- [Set up your agent](docs/mcp.md).

### Connect

- PostgreSQL, MySQL / MariaDB, SQLite files, MongoDB and Redis. **Test** before saving; connecting gives up after 15 seconds.
- Tag connections **Local**, **Development**, **Staging** or **Production**; Production asks before commits and destructive actions.
- Passwords in the macOS Keychain; TLS off, required, or required with certificate verification.
- **SSH tunnels** for PostgreSQL and MySQL, with key authentication.
- **Connection strings:** paste a URL, JDBC, libpq or .NET string to fill in the form; copy a connection back as a URL.
- **Several connections in one window** (⌃⌘] / ⌃⌘[); on PostgreSQL, open any database on the server from one connection.
- **Picks up where you left off:** tabs, unsaved SQL, filters and history come back; Tabula never reconnects at launch by itself.
- **Dump and restore** PostgreSQL and MySQL databases with the client tools on your Mac.
- [Connections in detail](docs/connections.md).

### Browse & edit

- A schema switcher that also sets the default for queries, and a table list you can filter; search ignores accents ("cafe" finds "café").
- Arrow keys preview tables in one reusable tab; drag tabs to reorder; ⌘P opens any table, tab or action.
- A paged grid (100 to 5,000 rows) with a total count, server-side sorting, spreadsheet keys and quick look.
- **Filter** with a builder (AND / OR, untick a condition), a `WHERE` clause or **Filter by This Value**; each table remembers its filter.
- **Edit** in the grid or Row Details (⌥⌘0): NULL or empty, add, duplicate and delete rows, undo and redo per tab.
- **Nothing is written until you commit:** ⇧⌘S previews the SQL, ⌘S runs it all in one transaction and rolls back on failure.
- **Paste rows** (⌘V) from Tabula, Numbers, Excel or Google Sheets.
- **Tables without a primary key** can be edited too, through a unique index, `rowid` or `ctid`.
- **Copy** rows as TSV, with or without headers; **export** CSV, TSV, JSON or SQL `INSERT`. Binary values round-trip as bytes.
- [Editing in detail](docs/editing.md).

<p align="center"><img src="docs/screenshots/data.png" width="820" alt="Filtering a table, with the row details panel open"></p>

### Query

- Highlighting, suggestions for tables, columns and keywords (Tab accepts), **Beautify** (⇧⌘I), comment toggling (⌘/) and history.
- **Run** (⌘↩) the selection or statement, or all (⇧⌘↩); **Stop** (⌘.) cancels on the server; a row **Limit** keeps accidents small.
- **Checks before a statement runs:** `UPDATE` / `DELETE` without `WHERE`, a `WHERE 1 = 1`, `TRUNCATE`, `DROP`, `ALTER TABLE` that rewrites or copies the table, and on Production the rows the plan expects to change. Production asks first; with AI on, **Review with AI** explains it and may offer a safer statement.
- **Edit query results** from one table that include its primary key.
- MySQL / MariaDB: `CALL` shows the rows a procedure returns, and `DELIMITER` scripts run.
- **Saved query library:** Save to Library (⌥⌘S), search it (⌥⌘L), insert by keyword with ⌃Space; open and save `.sql` files.
- **Console log** (⇧⌘C): every statement sent to the server, with time, rows, duration and errors; copy it as a SQL script.
- [Queries in detail](docs/queries.md).

<p align="center"><img src="docs/screenshots/query.png" width="820" alt="SQL editor with results and the console log"></p>

### Performance

- **Explain** (⌥⌘E) shows the plan without running it; **Explain Analyze** (⌥⇧⌘E) adds actual rows and time, rolling back or refusing changes.
- The slowest operations are tinted, and full scans of tables with 10,000 rows or more are flagged.
- **Server metrics** (⌥⌘4): live charts of reads, writes, transactions, connections and active queries, the cache hit ratio and the largest tables.
- [Query plans](docs/queries.md#query-plans) · [Server metrics](docs/queries.md#server-metrics).

### Find & import

- **Find in Database** (⇧⌘F) finds a value in every table of the schema; double-click a result to open the matching rows.
- **Import** a CSV, TSV or JSON file into a table: columns matched by name and previewed, rows committed in one transaction.
- [Find in Database](docs/queries.md#find-in-database) · [Importing files](docs/editing.md#importing-files).

### Schema

- **Structure** (⌥⌘2): columns with type, nullability, default, comment and primary key, and indexes.
- **Relationship diagram** (⌥⌘3) from foreign keys: drag, zoom, show key columns only, export a PNG.
- **Functions, procedures and triggers:** view, create, edit and save without ever losing the original.
- **Compare Schemas:** writes the SQL script that makes one schema match another, such as Production and Development; Tabula never runs it.
- [Structure and schema in detail](docs/schema.md).

### MongoDB

- Collections in the grid, with nested values inline and BSON types in Row Details; filter with the builder or a query document.
- Edits keep their types (a `NumberLong` stays a long); edit a whole document as JSON and preview the commands first.
- The query editor runs shell statements: `find`, `aggregate`, `updateMany`, `createIndex`, `show dbs`, `use`, `db.runCommand(…)`.
- Atlas (`mongodb+srv`), replica sets, TLS and SCRAM. [MongoDB in detail](docs/mongodb.md).

### Redis

- Keys listed with `SCAN`, never `KEYS`, safe on large production instances; filter by pattern or type.
- Strings, hashes, lists, sets, sorted sets and streams, edited in place. **Changes are written to Redis immediately.**
- Key details: size, memory, encoding and TTL; set an expiry, rename, create and delete keys.
- **Console** (⌘T) like `redis-cli`, which refuses commands that would freeze the connection and asks before destructive ones.
- Metrics from `INFO`. [Redis in detail](docs/redis.md).

### Updates & help

- **Updates:** Tabula checks for a new release at most once a day, verifies its checksum and signature, and relaunches. [Updating](docs/install.md#updating).
- **Help › Report a Problem…** opens a GitHub issue with your versions filled in, for you to read before submitting. After a crash it offers to add a summary of the crash report, shown in full first. [Reporting a problem](docs/install.md#reporting-a-problem).
- **Help › Keyboard Shortcuts** (⇧⌘/) lists every shortcut.

## Install

Requires macOS 14 Sonoma or later, on Apple silicon or Intel.

1. Download `Tabula-<version>.dmg` from the [latest release](https://github.com/tungnguyenvan/tabula/releases/latest). Optionally, [check it](docs/install.md#download-and-verify) against `SHA256SUMS.txt`.
2. Open the DMG, drag **Tabula** onto **Applications**, and eject it. Don't run Tabula from inside the DMG.
3. **First launch.** Tabula isn't notarized by Apple yet, so macOS blocks it once per installed version:
   - **macOS 15 and later:** double-click Tabula and click **Done**. In **System Settings › Privacy & Security**, under **Security**, click **Open Anyway**, then **Open Anyway** again, and enter your password or use Touch ID.
   - **macOS 14:** Control-click Tabula in Applications, choose **Open**, then click **Open**.
4. When macOS asks about Tabula's Keychain item, choose **Always Allow**. On macOS 15 and later, allow **Local Network** if your servers are on your network.
5. Click **New Connection** (⌘N), pick a type or paste a connection string, choose a tag, then **Test** and **Connect**.

**Updating:** **Tabula › Check for Updates…**, or wait for the daily check. **Uninstalling:** delete the app, and `~/Library/Application Support/Tabula` to remove saved connections; passwords are in Keychain Access under `app.tabula.connections`.

[Install in detail](docs/install.md): checksum, a Terminal alternative, updating, uninstalling, size and memory.

## Keyboard shortcuts

The ten you'll use most. [All shortcuts](docs/shortcuts.md), also in **Help › Keyboard Shortcuts** (⇧⌘/).

| Keys | Action |
| --- | --- |
| ⌘P | Open anything: a table, tab or action |
| ⌘T | New query tab |
| ⌘↩ / ⇧⌘↩ | Run the statement or selection / run all |
| ⌘. | Stop the running query |
| ⌘F | Filter rows |
| ⇧⌘S | Preview the SQL of your changes |
| ⌘S | Commit changes in one transaction |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌥⌘A | AI chat |
| ⌘K | Ask AI to write or change SQL |

## Your data & privacy

- **Passwords** and AI API keys are in the macOS Keychain; connection settings are a file without passwords. [Where everything is stored](docs/install.md#where-tabula-keeps-your-data).
- **No account, no telemetry.** Tabula connects to your databases, to GitHub for updates and, with AI on, to the provider you chose.
- **AI is off until you turn it on.** Rows reach a model only from the chat's read-only queries, at most 50 per query. [What is sent](docs/ai.md#what-is-sent).
- **Production safeguards:** Production connections ask before commits, destructive actions, restores and each AI or agent query.
- **Report a Problem** opens an issue you read and edit first; Tabula itself sends nothing.
- **Crash reports** of Tabula's are read only after a new crash or when you report a problem, and only the ones you tick are added to the issue, shortened, with your home folder written as `~`.

## Known limitations

- Redis Cluster and Sentinel aren't supported yet; connect to a single node. Pub/Sub, `MONITOR`, `MULTI` and `WATCH` aren't available in the console.
- MongoDB: shell statements, not JavaScript; grid edits aren't in a transaction; no X.509, LDAP or Kerberos; files can't be imported into collections yet.
- MySQL / MariaDB: editing existing rows needs a primary key or a unique index on NOT NULL columns, and `CALL` shows only the first result set.
- Stop ends a MongoDB command only on 4.4 or later; in the Redis console it ends scripts and blocking commands only.
- Details: [editing](docs/editing.md#tables-without-a-primary-key), [MongoDB](docs/mongodb.md#limitations), [Redis](docs/redis.md#limitations).

See [CHANGELOG.md](CHANGELOG.md) for release history.

## License

Tabula is released under the [MIT License](LICENSE). Copyright © 2026 Nguyen Van Tung.

Tabula bundles open-source components: PostgresNIO and MySQLNIO (MIT), RediStack, SwiftNIO, swift-nio-ssl, swift-crypto and related Apple packages (Apache 2.0, some of which include BoringSSL). Their full license texts and NOTICE files are in [`Resources/THIRD_PARTY_NOTICES.txt`](Resources/THIRD_PARTY_NOTICES.txt). The same file ships inside the app, at `Tabula.app/Contents/Resources`, and is linked from **Tabula › About Tabula**.
