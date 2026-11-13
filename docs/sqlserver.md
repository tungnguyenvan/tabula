# SQL Server

[Back to the README](../README.md)

Tabula connects to SQL Server 2017 and later, and to Azure SQL Database and Managed Instance, with a SQL login. It talks to the server with a TDS client of its own (TDS 7.4 and TDS 8), so there is nothing to install: no ODBC driver, no FreeTDS.

SQL Server support comes in phases. Phase 1 is connecting, browsing, querying and editing rows. Phase 2 ([#381](https://github.com/tungnguyenvan/tabula/issues/381)) adds Explain, functions, procedures and triggers, Copy As in T-SQL and the AI's tools checked with SQL Server, the relationship diagram, the data dictionary, Find in Database, Compare Schemas, and importing and exporting rows. Phase 3 ([#382](https://github.com/tungnguyenvan/tabula/issues/382)) adds Activity, Top Queries, Schema Health and Logins & Users. Windows and Microsoft Entra sign-in come in phase 4 ([#383](https://github.com/tungnguyenvan/tabula/issues/383)); until then Tabula signs in with a SQL login. [What works on which database](features-by-database.md).

- [Connecting](#connecting)
- [Encryption](#encryption)
- [Browsing and editing](#browsing-and-editing)
- [Queries and scripts](#queries-and-scripts)
- [Query plans](#query-plans)
- [Functions, procedures and triggers](#functions-procedures-and-triggers)
- [Copy As](#copy-as)
- [Schemas: diagram, descriptions and Compare Schemas](#schemas-diagram-descriptions-and-compare-schemas)
- [Finding, importing and exporting rows](#finding-importing-and-exporting-rows)
- [AI and read-only connections](#ai-and-read-only-connections)
- [Activity, Top Queries, Health, Logins & Users](#activity-top-queries-health-logins--users)

## Connecting

Choose **SQL Server** in a new connection's form.

- **Host:** the server's name, or `server\instance` for a named instance (`db\SQLEXPRESS`). Leave **Port** empty for a named instance and Tabula asks the SQL Server Browser (UDP 1434) for its port, as Microsoft's drivers do; otherwise SQL Server listens on 1433. Azure SQL: `yourserver.database.windows.net`.
- **User** and **Password:** a SQL login (`CREATE LOGIN … WITH PASSWORD`). Windows and Microsoft Entra ID sign-in aren't supported yet. The password is kept in the Keychain.
- **Database:** the one to open; empty opens the login's default database. The sidebar's database picker lists the others the login may open and moves the window to one of them, as on PostgreSQL. Schemas (`dbo` first) are listed under it.
- **SSH tunnel:** as for PostgreSQL and MySQL ([SSH tunnels](connections.md#ssh-tunnels)). The certificate is still checked against the server's name, and that name is what the login sends. The SQL Server Browser can't be reached through a tunnel, so a named instance needs its port there.
- **Connection strings:** `sqlserver://user:password@host:1433?database=shop&encrypt=true` (Microsoft's Go driver, with a named instance as the path: `sqlserver://user@host/SQLEXPRESS`), `mssql://user:password@host:1433/shop` (Node and SQLAlchemy), JDBC (`jdbc:sqlserver://host:1433;databaseName=shop;user=app;password=…;encrypt=true`) and ADO.NET (`Server=tcp:host,1433;Initial Catalog=shop;User ID=app;Password=…;Encrypt=True;TrustServerCertificate=False`). **Copy URL** writes the `sqlserver://` form.

## Encryption

**Encrypt** is **On** by default, as in Microsoft's current drivers.

- **On** encrypts the whole connection with TLS, started inside the TDS handshake. The server's certificate is checked against the system's trust store and the host name, unless **Trust server certificate** is on.
- **Strict** starts TLS before anything else (TDS 8), as SQL Server 2022 and Azure SQL accept with `Encrypt=Strict`.
- **Off** encrypts only the login: the password still goes over TLS, but queries and results don't. Against a server that has no TLS at all, nothing is encrypted, the password included.
- **Trust server certificate** accepts any certificate, such as the self-signed one SQL Server makes for itself: anyone between your Mac and the server could then read the connection. For a certificate your own authority issued, choose that authority's certificate (a PEM file) under **Certificate authority** instead.

## Browsing and editing

- Tables and views of each schema, with their columns (types with their lengths and precision, nullability, defaults, `IDENTITY`, computed and `rowversion` columns), primary keys, unique constraints, indexes (included columns and filters in their definition), foreign keys, `MS_Description` comments and CHECK constraints. Completion in the SQL editor uses them.
- The grid pages with `OFFSET … FETCH` and counts with `COUNT_BIG`; sorting and the filter bar work as on the other databases (text matches without regard to case).
- **Editing:** changes are committed in one transaction (`BEGIN TRANSACTION` … `COMMIT`), each update and delete finding its row by the primary key (or a unique index) and failing the commit when it doesn't change exactly that row, also on a table whose triggers change other rows. `IDENTITY`, computed and `rowversion` columns are left to the server in new rows, in Duplicate Rows and in pasted rows, and the page is read again after the commit with the values the server gave them.
- `bit` shows as `1` and `0`, binary values as `\x…` hex, `datetimeoffset` with its offset.

## Queries and scripts

- Scripts run batch by batch, split at `GO` lines; `GO 5` runs a batch five times. A batch runs statement by statement, as on the other databases, unless its statements share something that lives only in a batch: a variable or table variable (`@total`), `SCOPE_IDENTITY()`, `@@ROWCOUNT`. Then the batch runs whole and shows each result set it returns. A procedure that returns several result sets shows them all.
- **Stop** (⌘.) cancels the running batch on the server. An open transaction stays open, with what ran before the stopped statement.
- The row **Limit** adds `TOP (n)` to a query that has no limit of its own.
- The checks before a statement runs know T-SQL: `EXEC`, `MERGE`, `SELECT … INTO`, and an `UPDATE` or `DELETE` without `WHERE`. Passwords in `CREATE LOGIN` and `ALTER LOGIN` are masked in the console log.
- Errors read as SQL Server writes them, with their number and line: `Invalid object name 'orders'. (Msg 208, line 2)`.
- Server Metrics shows sessions, requests, the buffer cache, batches and transactions per second and the largest tables; the login needs `VIEW SERVER STATE`.

## Query plans

**Explain** (⌥⌘E) turns `SHOWPLAN_XML` on for the statement, so the server compiles it without running it and returns its estimated plan; **Explain Analyze** (⌥⇧⌘E) turns `STATISTICS XML` on, so the statement runs and the server returns its actual plan ([#381](https://github.com/tungnguyenvan/tabula/issues/381)). The setting is turned off again right after, also when the statement fails or is stopped, and the window's other tabs wait meanwhile, so none of their statements returns a plan instead of running. [Query plans](queries.md#query-plans).

- Each statement is a row (SELECT, UPDATE…) with its cost, over its operators: the physical operation with the logical one where it says more (`Hash Match (Aggregate)`), the table with its alias and index, estimated rows (per execution) and cost. Analyzed, also the rows each operator returned and the times it ran over all its executions and threads, the milliseconds it took (with its inputs), and the statement's elapsed time. An operator that never ran says so.
- The details hold the seek keys, predicates, hash and join keys, sort and group columns, and the rows an operator read beyond those it returned (`Rows read: 50000`). Warnings are written out: an implicit conversion that affects a seek or the estimates, columns without statistics, a missing join predicate, spills to tempdb and memory grants. The statement's row has the server's missing index suggestions as `CREATE INDEX` statements, with the improvement it estimates.
- `Table Scan` and `Clustered Index Scan` of a table of 10,000 rows or more are flagged; the size comes from the plan.
- A statement that only reads is analyzed on the window's connection, as Run would run it; Tabula reads its rows and shows only the plan. Any other statement (an `UPDATE`, an `EXEC`) runs on a separate connection in a transaction that is rolled back, after Tabula asks, as on PostgreSQL: IDENTITY values and sequences it advanced stay advanced.
- **Copy Plan** copies the showplan XML, which SQL Server Management Studio opens when saved as a `.sqlplan` file. **Ask AI about This Plan** sends the plan (its outline when the XML is long), the statement and the tables' columns and indexes.

## Functions, procedures and triggers

Stored procedures, functions (scalar, inline and multi-statement table-valued) and DML triggers are in the sidebar with the schema's tables, read from `sys.sql_modules` and `sys.parameters`: procedures with their parameters (`@id int, @note nvarchar(40) OUTPUT`), functions with what they return, triggers with their events and table (`AFTER INSERT, UPDATE ON orders`, and whether they are disabled). CLR routines, which have no T-SQL definition, aren't listed. [Routines](schema.md#functions-procedures-and-triggers).

- A routine opens as the server keeps its definition, starting `CREATE OR ALTER`, so ⌘S replaces it in one step; a definition the server rejects leaves the routine as it was.
- **New Procedure…**, **New Function…** and **New Trigger…** (also on a table's menu) start from a `CREATE OR ALTER` template in the selected schema.
- A definition runs batch by batch, split at `GO` lines, as scripts do: a `CREATE PROCEDURE` must start its batch, so a `GRANT` or a second routine after it goes after a `GO`.
- A view's query is read from `sys.sql_modules` too, for Compare Schemas.

## Copy As

**Edit › Copy As** writes T-SQL ([#381](https://github.com/tungnguyenvan/tabula/issues/381)): names in brackets, `N'…'` for text that isn't ASCII, `0x…` for bytes, and `datetime` and `smalldatetime` values with a T (`'2024-05-01T10:00:00.123'`), which the server reads the same whatever the session's language and `DATEFORMAT`. With **SQL INSERT: one statement for all rows**, a `VALUES` list holds at most 1,000 rows, as SQL Server allows. [Copying and exporting](editing.md#copying-and-exporting).

- From a table tab, `IDENTITY`, computed and `rowversion` columns are left to the server, as Duplicate Row does.
- From a query's result, the server's result metadata gives each column's type, so JSON keeps numbers and booleans; computed and `rowversion` columns are left out, and `IDENTITY` values are kept, between `SET IDENTITY_INSERT … ON` and `OFF`.

## Schemas: diagram, descriptions and Compare Schemas

- **View › Relationship Diagram** (⌥⌘3) draws the tables of the schema selected in the sidebar with their foreign keys, as on the other databases ([Relationship diagram](schema.md#relationship-diagram)).
- **Descriptions:** a table's, view's or column's `MS_Description` (what SQL Server Management Studio shows as its description) is read as its comment and is the starting text of Tabula's [data dictionary](ai.md#data-dictionary). **Open as MS_Description Statements** in Structure (or **Open Descriptions as MS_Description Statements** in the sidebar's context menu for the schema) writes the descriptions back: `sp_updateextendedproperty` where the object has one, `sp_addextendedproperty` where it doesn't. The script opens in a query tab; Tabula never runs it.

### Compare Schemas

**File › Compare Schemas…** compares two schemas, of one database or of two (each a saved SQL Server connection), and writes the T-SQL script that makes the target match the source ([Compare schemas](schema.md#compare-schemas)).

- The script runs in one transaction (`BEGIN TRANSACTION` … `COMMIT TRANSACTION`), with `GO` after each statement, since CREATE VIEW and the like must start a batch. If a statement fails, run `ROLLBACK TRANSACTION`: nothing is changed.
- Columns are added with `ALTER TABLE … ADD` (computed columns as `AS (…) [PERSISTED]`, `IDENTITY` with its seed and increment) and changed with `ALTER COLUMN`, which restates the type and NULL or NOT NULL. A default is a constraint of its own that the server names: the script looks it up by the column and drops it before the column's type changes or the column is dropped, and adds the new one with `ADD DEFAULT … FOR`.
- Indexes are compared and created from their whole definition: clustered or not, key order, `INCLUDE` and the filter. An index that uses a column whose type or nullability changes is dropped first and created again after, since SQL Server won't change the column under it; for a column of a primary key or a foreign key, a comment says to drop and add those keys by hand.
- A primary key keeps its constraint name, and NONCLUSTERED when the source's isn't the clustered index. A UNIQUE constraint's index is dropped with `ALTER TABLE … DROP CONSTRAINT`.
- A renamed column's comment has the `sp_rename` to use instead of the ADD and DROP.
- Views are compared by their query as written (`sys.sql_modules`), and functions, procedures and triggers by their definitions, which the script runs as `CREATE OR ALTER`, each in its own batch. CHECK constraints, collations, permissions and descriptions aren't compared.

## Finding, importing and exporting rows

- **Edit › Find in Database** (⇧⌘F) searches text columns (`char`, `varchar`, `nchar`, `nvarchar`, `text`, `ntext`) as Unicode without regard to case, with `LIKE`'s wildcards `%`, `_` and `[` taken literally, and numbers, `uniqueidentifier`, `date`, `datetime`, `datetime2`, `datetimeoffset` and binary columns by equality, each count stopping at 1,001 rows with `TOP`. `bit`, `xml`, `sql_variant`, spatial and other columns are skipped ([Find in Database](queries.md#find-in-database)).
- **File › Import…** adds CSV, TSV or JSON rows to a table tab ([Importing files](editing.md#importing-files)). `IDENTITY`, computed and `rowversion` columns are left to the server, and JSON's `true` and `false` go into a `bit` as 1 and 0. The rows commit in one transaction, each its own INSERT (so triggers see them one at a time), sent up to 250 at a time in one batch.
- **Export** writes the rows shown as CSV, TSV, JSON or SQL INSERT statements; INSERTs of a query's rows go to the table it read, or to `results` in the selected schema (`dbo` before one is chosen) ([Copying and exporting](editing.md#copying-and-exporting)).
- **Dump and restore** aren't supported: SQL Server has no client tool like `pg_dump` that writes a database out as a script. File › Dump Database… and Restore from Dump… say so, and what to use instead: `BACKUP DATABASE` and `RESTORE DATABASE` on the server, or SQL Server Management Studio's Generate Scripts.

## AI and read-only connections

SQL Server has no read-only session, so on a [read-only connection](connections.md#read-only-connections) Tabula's own checks are all there is, as on MongoDB and Redis. The AI assistant, analysis notebooks, dashboards and AI agents (MCP) only run statements those checks say only read (`SELECT` and `WITH … SELECT`), and each runs in a transaction that is rolled back, so one that got past them changes nothing. Their statements are stopped after their time limit from Tabula's side, since SQL Server has no setting for it: Tabula cancels the batch on the server (a TDS Attention), rolls the transaction back and reports that the statement ran longer than the limit; the connection goes on. For a guarantee, connect with a login that may only read.

- The model is told it writes T-SQL, and is given the schema's tables with their columns, keys and `MS_Description` comments, with `dbo` as the default schema. Tables can be named with brackets (`[dbo].[orders]`) in its tools.
- **Proposed data changes** work as on the other databases: the chat's changes become pending edits in the table's tab, written in T-SQL, and nothing is written until you commit them.

## Activity, Top Queries, Health, Logins & Users

The views of the **View** menu work on SQL Server as on PostgreSQL and MySQL ([Activity](queries.md#activity-sessions-and-locks), [Top Queries](queries.md#top-queries), [Schema Health](schema.md#schema-health), [Users & Roles](schema.md#users-roles-and-privileges)), in SQL Server's terms. A read-only connection refuses changes until **Allow Changes…**, Production asks again, and what changes the server shows in the console log; what the views only read doesn't.

Most of what they read is in SQL Server's dynamic management views, which need the **VIEW SERVER STATE** permission (on Azure SQL Database, **VIEW DATABASE STATE**). A login without it is told so, with the `GRANT` to ask an administrator for.

### Activity

**View › Activity** (⌥⌘6) lists the server's sessions from `sys.dm_exec_sessions`, with their running request from `sys.dm_exec_requests`: session ID, login, database, host and client address, program, state (`running`, `suspended`, `sleeping`, or sleeping in a transaction), what it waits on with how long (`LCK_M_X (12s)`), when its transaction and its request began, and the running statement (from `sys.dm_exec_sql_text`; a statement SQL Server parameterized itself is shown as it was sent, values included) or the last batch of an idle session. The detail pane adds the CPU time and logical reads of the running request, or of all the session ran while it is idle. **Blocking** draws who waits for whom from the requests' `blocking_session_id`, each with the lock it waits for (`LCK_M_S on KEY: 5:72057594043695104 (8194443284a0)`).

SQL Server has no way to stop only another session's statement, so there is no **Cancel Query…**: **Kill Session…** runs `KILL`, which ends the session and rolls back its open transaction (a long transaction takes as long to roll back). It asks first, asks again on Production, isn't offered for Tabula's own sessions or the server's background ones, and reaches only the session you chose: it checks the session's sign-in time first, since SQL Server gives a session's ID to the next one as soon as it ends. Killing needs **ALTER ANY CONNECTION** (the `processadmin` server role has it).

### Top Queries

**View › Top Queries** reads the current database's **Query Store** when it is on (the default for new databases from SQL Server 2022, and on Azure SQL), otherwise the **plan cache** (`sys.dm_exec_query_stats` with `sys.dm_exec_sql_text`). The header says which:

- **Query Store** keeps each query of the database across restarts, with its figures summed over every plan and interval. A procedure's or function's statements say which one they are in.
- **The plan cache** covers every database on the server (each statement says which), but only the plans still cached, and starts again when the server restarts or a plan leaves the cache. The statements of one shape (`query_hash`) count together.

The table shows the statement, calls, total, mean and longest time and rows, and SQL Server's CPU time and logical and physical reads (pages). SQL Server writes the parameters of a statement it or the client parameterized as `@1` or `@P1`, with a list of them in front (`(@P1 int)SELECT …`); Tabula takes the list off, and **Explain…** asks for a value of each, as for `$1` on PostgreSQL. **Reset Statistics…** clears the database's Query Store (`ALTER DATABASE CURRENT SET QUERY_STORE CLEAR`), after asking; the plan cache's figures go only with the plans, so the plan cache has no reset in Tabula. Tabula never turns Query Store on: `ALTER DATABASE CURRENT SET QUERY_STORE = ON` does, for a user with `ALTER` on the database.

### Health

**View › Schema Health** checks the tables of the selected schema:

- **Unused indexes:** no seeks, scans or lookups in `sys.dm_db_index_usage_stats` since the server started (or the database was last brought online), leaving out primary keys, unique indexes and the only index of a foreign key.
- **Missing indexes:** the indexes the optimizer noted it wished it had while compiling queries (`sys.dm_db_missing_index_details`), weighed by the queries' cost, the share the index would save and how often they ran, each with a `CREATE INDEX … INCLUDE (…)`. A suggestion an existing index already serves is left out; the optimizer's suggestions are rough, so compare one with the table's indexes before creating it.
- **Duplicate and redundant indexes**, **foreign keys without an index**, **tables without a primary key**, **sequential scans on large tables** (scans of the heap or clustered index against seeks) and **the largest tables and indexes**, as on the other databases.
- **Heaps:** tables without a clustered index, with a `CREATE CLUSTERED INDEX` on the primary key or a unique index when there is one.

Statements are T-SQL: `DROP INDEX [ix] ON [schema].[table]`, `ALTER TABLE … DROP CONSTRAINT` for a constraint's index, `ALTER TABLE … ADD CONSTRAINT [PK_table] PRIMARY KEY (…)`. Fragmentation isn't checked: measuring it reads the indexes (`sys.dm_db_index_physical_stats`).

### Logins & Users

**View › Users & Roles** opens **Logins & Users**, with both of SQL Server's levels in one list:

- **Logins** and **server roles** (`sys.server_principals`): the kind (SQL login, Windows login or group, Entra login), whether it is disabled or its password expired or must change, and its server roles (`sysadmin`, `dbcreator`…).
- **Users** and **roles** of the current database (`sys.database_principals`): the login each user signs in with, the roles it belongs to, and whether it may connect.

The fixed roles, `dbo`, `guest`, `sys` and the server's own logins are hidden until **Show built-in logins, users and roles**. **New Login…** creates a SQL login with its password, whether the password policy applies, whether it must change its password at the next sign-in and whether it is disabled; **New User…** a user for a login (or without one); **New Role…** a database role. **Edit…** changes a login's password, policy and state, a user's login, and the server or database roles each belongs to (`ALTER SERVER ROLE … ADD MEMBER`, `ALTER ROLE … ADD MEMBER`).

**Privileges** lists the permissions granted or denied in the database: on the database itself (`CONNECT`, `CREATE TABLE`…), on the schema, and on its tables, views, procedures, functions and columns. **Grant…** and **Deny…** write `GRANT` and `DENY` (`ON OBJECT::[sales].[orders]`, `ON SCHEMA::[sales]`); a `DENY`, shown in red, wins over every `GRANT` the user has, directly or through its roles. **Revoke** takes back a grant or a deny (`REVOKE … CASCADE`, which also takes it from anyone the grantee gave it to). What users have through the fixed roles (`db_datareader`, `db_owner`) or `sysadmin` isn't listed.

The changes run in one transaction when you commit: if one fails, none is kept. Passwords are `N'…'` literals, shown as `•••` in the preview and the console log. Changing logins needs **ALTER ANY LOGIN** (the `securityadmin` role), users **ALTER ANY USER**, and granting a permission needs it **WITH GRANT OPTION** or **CONTROL**; without **VIEW ANY DEFINITION** a login sees only itself and the fixed server roles among the logins, and the tab says so. Azure SQL Database lists its logins only in `master`.
