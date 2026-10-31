# Queries

[Back to the README](../README.md)

- [The editor](#the-editor)
- [Running and stopping](#running-and-stopping)
- [Checks before a statement runs](#checks-before-a-statement-runs)
- [Saved queries and .sql files](#saved-queries-and-sql-files)
- [Console log](#console-log)
- [Query plans](#query-plans)
- [Server metrics](#server-metrics)
- [Find in Database](#find-in-database)

<p align="center"><img src="screenshots/query.png" width="820" alt="SQL editor with results and the console log"></p>

## The editor

- Highlighting that follows the database's comment and quoting rules, and line numbers.
- Suggestions for tables, columns and keywords as you type: tables after `FROM` / `JOIN` (including `schema.` for another schema), columns after `alias.`, and every table's columns before the statement names one. The first one shows in grey and Tab accepts it; ⎋ or ⌃Space opens the list. With AI on, the grey suggestion can come from a model instead: see [Suggestions while typing](ai.md#in-the-editor).
- **Beautify** (⇧⌘I) the selection or the whole query, **toggle comments** (⌘/), find (⌘F) and per-tab undo.
- Query history, kept with the connection.

## Running and stopping

- **Run** (⌘↩) the selection or the statement under the cursor, or **Run All** (⇧⌘↩), with one result each.
- **Stop** (⌘.) cancels the statement on the server and skips the rest of the script; results finished before Stop are kept. Tabula never commits or rolls back your transaction for you: on PostgreSQL a cancelled transaction stays failed until you run `ROLLBACK`. MySQL gets `KILL QUERY` for that statement only and MongoDB `killOp` for that command's operations, each from a short-lived second connection. SQLite rolls back an open transaction when the stopped statement was changing rows; documents a stopped MongoDB command already changed stay changed. MongoDB needs 4.4 or later.
- In the Redis console, Stop ends a Lua script or function once it has run for 5 seconds (on a shared server it stops whichever script is running, so Production asks first) and unblocks a waiting command such as `BLPOP`. Other Redis commands run to the end.
- A row **Limit** (100 to 5,000, or none; 300 by default) is added to SELECTs that have none, so an accidental full-table query stays small. It leaves statements that already limit themselves, writes and `FOR UPDATE` alone.
- **MySQL / MariaDB:** `CALL` of a procedure shows the rows it returns (the first result set when it returns several), and `DELIMITER` scripts run as in the mysql client.
- Results from one table that include its primary key can be edited: see [Editing query results](editing.md#editing-query-results).

## Checks before a statement runs

Before **Run** or **Run All** sends anything, Tabula reads the statements (outside comments and strings) and looks for well-known mistakes. These checks need no AI and always run:

| Finding | Severity |
| --- | --- |
| `UPDATE` or `DELETE` without `WHERE` (with only a `LIMIT`: a warning; MySQL joins count as a condition) | Danger |
| A `WHERE` that is always true: `1 = 1`, `TRUE`, `x = x`, or an `OR` with such a branch | Danger |
| `TRUNCATE`; `DROP TABLE`, `DROP DATABASE`, `DROP SCHEMA`; `ALTER TABLE … DROP COLUMN` or `DROP PARTITION` | Danger |
| MongoDB `deleteMany({})`, `updateMany({}, …)`, `remove({})`, `drop()` and `dropDatabase()` | Danger |
| PostgreSQL `ALTER TABLE` that rewrites the table: a new column with a volatile default (`random()`, `gen_random_uuid()`, `clock_timestamp()`), a serial, identity or stored generated column, or a column type change | Warning |
| MySQL `ALTER TABLE … MODIFY`, `CHANGE`, `CONVERT TO CHARACTER SET` or `DROP PRIMARY KEY` without `ALGORITHM=INPLACE` / `INSTANT` or `LOCK=NONE`, which may copy the table | Warning |
| On Production: an `UPDATE` or `DELETE` the plan expects to change 10,000 rows or more, or 10% of a table of 1,000 rows or more | Warning |
| On Production: PostgreSQL `CREATE INDEX` without `CONCURRENTLY` on a table of 10,000 rows or more | Warning |

What happens next depends on the connection's [tag](connections.md#tags-and-production-safeguards):

- **Production** asks before any statement that may change data, with the findings, whether there are any or not. The row estimates come from a plain `EXPLAIN` (never `ANALYZE`) and the server's table statistics, read on a separate connection while the confirmation is open; nothing is counted and no row is read.
- **Development, Staging and untagged** connections ask only when there is a danger finding. **Don't ask again for this connection** stops that; **Ask Again** in the connection's editor turns it back on.
- **Local** connections and **SQLite files** never ask; the findings show above the results.

A danger confirmation has no default button, so Return doesn't run the statement. With AI on, **Review with AI** sends the statements, the findings, the columns of the tables they name and the plans (no rows) and shows the model's explanation, with a safer version when it has one, such as a narrower `WHERE`, a `LIMIT` or batches. **Use This** puts it in the editor in place of the reviewed statements and closes the confirmation without running anything; Copy copies it. The instructions can be changed in **Settings › AI › Instructions › Review**. AI is never needed to run a statement.

Commits of edits (from a table, a query result or the preview sheet) are Tabula's own statements, each matching one row by its key; the Production commit confirmation lists any findings, and they aren't sent to the AI, since they hold row values.

## Saved queries and .sql files

- **Save to Library** (⌥⌘S) keeps the selection, or the whole editor, under a keyword and an optional folder, as a `.sql` file in `~/Library/Application Support/Tabula/Queries`. You can add and arrange files there in Finder too; subfolders are groups.
- The **Queries panel** (⌥⌘L) searches them by keyword, folder or SQL, ignoring accents; double-click to insert at the caret, or Open to edit the file.
- Type a keyword in the editor and press ⌃Space: the saved query is in the completion list, and choosing it inserts its SQL. The AI chat can search the library too, so "find my revenue query" works.
- **Open** (⌘O) one or more `.sql` files, each in its own query tab, or open them from Finder (Open With, or dropped on the Dock icon); Tabula never makes itself their default app. **Save** (⌘S) and **Save As…** (⇧⌘S) write them, in the encoding they were read in. A tab tied to a file shows a dot while it has unsaved edits, and closing it asks first.
- In a table tab, or a query tab with edited result cells, ⌘S commits and ⇧⌘S previews the changes instead.

## Console log

**Console log** (⇧⌘C) shows every statement sent to the server, with time, rows, duration and errors. **Copy log as SQL** gives a script that runs. Statements from the AI chat and from [AI agents](mcp.md) appear here too; metrics polling doesn't.

## Query plans

**Explain** (⌥⌘E, or the Explain button) shows how the database would run the selected statement, or the one at the cursor, without running it: an outline of each operation with its table, index, estimated rows and cost. **Explain Analyze** (⌥⇧⌘E) runs it and adds actual rows and time.

Explain uses PostgreSQL `EXPLAIN (VERBOSE, FORMAT JSON)`, MySQL `EXPLAIN FORMAT=JSON` and SQLite `EXPLAIN QUERY PLAN` (no estimates). Explain Analyze uses PostgreSQL `EXPLAIN (ANALYZE, BUFFERS)`, MySQL 8.0.18+ `EXPLAIN ANALYZE` and MariaDB `ANALYZE FORMAT=JSON`; SQLite has no Analyze.

- A statement that only reads runs as Run would. On PostgreSQL, any other statement runs on a separate connection in a transaction that is rolled back, after Tabula asks, since sequences and other effects outside the transaction stay. MySQL, which commits some statements on its own, analyzes only statements that read.
- The **Share** column is each operation's own part of the time (or, without Analyze, the cost): a quarter or more is orange, half or more red. Full scans of tables with 10,000 rows or more are flagged.
- **Copy Plan** copies the plan as the server returned it.
- With AI on, **Ask AI about This Plan** explains it and suggests `CREATE INDEX` statements to insert or copy. Nothing is run. It sends the statement, the plan, and the tables' names, column types and indexes, never rows.

## Server metrics

**Server metrics** (⌥⌘4) shows live charts of reads, writes, transactions, connections and active queries, refreshed every 1 to 30 seconds, plus the cache hit ratio and the largest tables. MongoDB's come from `serverStatus` and `dbStats`, including the largest collections; Redis's from `INFO` (see [Redis metrics](redis.md#metrics)). Polling isn't written to the console log.

<p align="center"><img src="screenshots/metrics.png" width="820" alt="Server metrics"></p>

## Find in Database

**Edit › Find in Database…** (⇧⌘F) finds a value in every table of the current schema, or the ones you tick (views only when ticked), and lists each column it is in with the number of matching rows. Double-click a result to open the table filtered to those rows, with the conditions in the filter bar.

- Text columns contain the value, ignoring case (and accents on MySQL); numeric, UUID, date and binary (`\xcafe`, `0xcafe`) columns must equal it; other columns are skipped. On MongoDB, string fields are searched.
- Rows are counted up to 1,000.
- Tables are searched one at a time on a separate read-only connection, with a one-minute limit per statement. Stop (⌘.) ends the search, and Production connections ask first.
