# SQL Server

[Back to the README](../README.md)

Tabula connects to SQL Server 2017 and later, and to Azure SQL Database and Managed Instance, with a SQL login. It talks to the server with a TDS client of its own (TDS 7.4 and TDS 8), so there is nothing to install: no ODBC driver, no FreeTDS.

SQL Server support comes in phases. Phase 1, described here, is connecting, browsing, querying and editing rows. Explain, routines, the relationship diagram, Compare Schemas and importing files follow in phase 2 ([#381](https://github.com/tungnguyenvan/tabula/issues/381)); Activity, Top Queries, Schema Health and Logins & Users in phase 3 ([#382](https://github.com/tungnguyenvan/tabula/issues/382)); Windows and Microsoft Entra sign-in in phase 4 ([#383](https://github.com/tungnguyenvan/tabula/issues/383)). Until then those menu items are off, or their tab says they aren't available for SQL Server. [What works on which database](features-by-database.md).

- [Connecting](#connecting)
- [Encryption](#encryption)
- [Browsing and editing](#browsing-and-editing)
- [Queries and scripts](#queries-and-scripts)
- [AI and read-only connections](#ai-and-read-only-connections)

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

## AI and read-only connections

SQL Server has no read-only session, so on a [read-only connection](connections.md#read-only-connections) Tabula's own checks are all there is, as on MongoDB and Redis. The AI assistant and AI agents only run statements those checks say only read, and each runs in a transaction that is rolled back, so one that got past them changes nothing; their statements are stopped after their time limit from Tabula's side, since SQL Server has no setting for it. For a guarantee, connect with a login that may only read.
