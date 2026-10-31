# Connections

[Back to the README](../README.md)

- [Creating a connection](#creating-a-connection)
- [Tags and Production safeguards](#tags-and-production-safeguards)
- [Several connections in one window](#several-connections-in-one-window)
- [Picking up where you left off](#picking-up-where-you-left-off)
- [TLS](#tls)
- [SSH tunnels](#ssh-tunnels)
- [Connection strings](#connection-strings)
- [Dump and restore](#dump-and-restore)

<p align="center"><img src="screenshots/connections.png" width="560" alt="Connections window"></p>

## Creating a connection

Tabula connects to PostgreSQL, MySQL / MariaDB, SQLite files, MongoDB and Redis.

1. Click **New Connection** (⌘N) and pick a type, or paste a [connection string](#connection-strings).
   - **PostgreSQL** uses the user name when Database is empty.
   - **MySQL / MariaDB:** the database is optional; switch it from the sidebar.
   - **SQLite:** choose a file or create one (⌘O in the Connections window opens a SQLite file).
   - **Redis:** User is optional (an ACL user on Redis 6 and later; empty for `requirepass`) and Database is the index, 0 by default.
   - **MongoDB:** see [MongoDB connections](mongodb.md#connecting).
2. Choose a [tag](#tags-and-production-safeguards), so a Production connection is obvious at a glance.
3. Click **Test**, then **Connect**, or double-click a saved connection. Connecting gives up after 15 seconds instead of hanging.

Passwords are stored in the macOS Keychain, never in the settings file. **Copy URL** and **Copy URL with Password** in a connection's context menu copy it back as a URL.

> **MySQL 8 and TLS:** accounts that use `caching_sha2_password`, the MySQL 8 default, can only authenticate over an encrypted connection, so new MySQL connections default to TLS **Required**. If the server has no TLS, switch the account to `mysql_native_password` or enable TLS on the server.

## Tags and Production safeguards

Tag each connection **Local**, **Development**, **Staging** or **Production**. The tag colors the sidebar strip and the toolbar pill. On a Production connection Tabula asks before:

- running a statement from the editor that may change data, with what [Tabula's checks](queries.md#checks-before-a-statement-runs) found and, with AI on, **Review with AI**. Development, Staging and untagged connections ask only before a statement that changes every row or drops a table, unless you choose **Don't ask again for this connection**;
- committing changes (from a table tab, a query result, a document, or the preview sheet and ⌘S);
- destructive actions, such as restoring a dump (you type the database name) and Redis commands not known to only read;
- each read-only query the [AI chat](ai.md#read-only-queries) or an [AI agent](mcp.md) wants to run, and searching with [Find in Database](queries.md#find-in-database).

AI is off for Production connections unless you allow it in Settings.

## Several connections in one window

Opening another connection, from the toolbar's database button, adds it to the current window. With two or more, a column left of the sidebar lists them: hover for details, click or press ⌃⌘] / ⌃⌘[ to switch. The connection pill in the toolbar shows details on click.

On PostgreSQL, the sidebar's **Database** picker, above the schema picker, lists the databases your login may connect to and opens any of them from the same connection. Query tabs keep their SQL, tabs of the old database's tables close (Tabula asks first if they hold unsaved edits), and the toolbar shows `database.schema`. The saved connection keeps its database. The new database is connected first: if it can't be opened, nothing in the window changes and the sidebar says why. The AI chat starts over in the new database.

## Picking up where you left off

Reopening a connection brings back its query tabs (their SQL, unsaved edits included, and the `.sql` files they are tied to), the open tables (Data or Structure) in their order, the selected tab, filters, the schema, the PostgreSQL database the window had moved to, and the query history. Only the selected table loads its rows at once; the others load when selected. Reconnect keeps the tabs too.

The state is saved when a connection, its window or Tabula closes, and every few seconds while it changes. A connection that is still connecting, or failed to, never overwrites what was saved. **Reopen tabs when connecting** in Settings › General turns this off and forgets what was kept; deleting a connection deletes its state.

Windows aren't restored at launch, so Tabula never reconnects to a database, such as Production, unless you choose to.

## TLS

TLS can be off, **Required**, or required with **Verify certificate**.

- **Verify certificate** checks the server against the macOS trust store. Databases with a private CA (such as AWS RDS, or self-signed certificates) fail until that CA is added to Keychain Access and trusted.
- **Required** encrypts without checking the certificate.

## SSH tunnels

Turn on **Connect over SSH** (PostgreSQL, MySQL) to reach a database through an SSH server (a bastion). The form takes the SSH host, port, user and, optionally, a private key file. Host is then the database as the SSH server sees it, such as `localhost`.

- Tabula runs the system's `/usr/bin/ssh` with key authentication only: keys from ssh-agent, `~/.ssh`, or a key file you choose. Add a key with a passphrase to ssh-agent first (`ssh-add`). No SSH password or passphrase is stored.
- The server's host key must already be in `~/.ssh/known_hosts`; connect once with `ssh` in Terminal to check and save it. `~/.ssh/config` isn't read, so enter the real host name, port and user. IPv6 addresses work for the SSH server and the database host.
- The tunnel listens on 127.0.0.1 only and closes with the connection or when Tabula quits. **Verify certificate** needs a database host name, not an IP address, so TLS checks the database's real identity rather than the tunnel's.

## Connection strings

**Connection String…** (⇧⌘N) in the Connections window, paste (⌘V) into the connection list, or type one in the Host field. A summary shows what was read before **Continue** fills in the form, password included. Tabula never reads the clipboard by itself.

- It accepts `postgresql://`, `mysql://`, `redis://`, `rediss://`, `mongodb://`, `mongodb+srv://` and `file://` URLs (and those TablePlus copies, with their name, tag and TLS settings), JDBC URLs, libpq `key=value` strings and .NET-style `Server=…;Uid=…;Pwd=…` strings.
- URL escapes are decoded (`p%3Fss` becomes `p?ss`). A password that still holds escapes, as some dashboards show them, gets a **Decode** button, and a failed login says when escapes are the likely cause.
- Copy a connection back as a URL, with or without the password, from its context menu.

## Dump and restore

**File › Dump Database…** (or **Dump Table…** in the sidebar) and **File › Restore from Dump…**, for PostgreSQL and MySQL, with progress and Stop.

- Tabula uses the newest `pg_dump`, `pg_restore`, `psql`, `mysqldump` and `mysql` (or MariaDB's) it finds in Postgres.app, Homebrew and your PATH; pg_dump must be at least as new as the server. If one is missing, the sheet says how to install it.
- Dumps: structure, data or both; PostgreSQL as a SQL script or a custom archive; optional DROP statements and, on PostgreSQL, owners and privileges. A failed or stopped dump leaves no file behind.
- Restores stop at the first error. On PostgreSQL they run in one transaction by default, so a failure changes nothing. Production connections ask you to type the database name.
- Scripts can't run commands on your Mac: PostgreSQL scripts with psql commands such as `\!` are refused (pg_dump's `\restrict` is allowed), and the mysql client's `system` command and local file loading are off. **Restore only dumps you trust:** they can contain any SQL.
- Passwords reach the tools through the environment (PostgreSQL) or a private temporary option file (MySQL), never the command line. `~/.my.cnf`, MySQL login paths, `~/.psqlrc` and `PG*` / `MYSQL_*` variables aren't used. SSH connections go through the tunnel.
- The `transaction_timeout` setting pg_dump 17 writes is left out when restoring into PostgreSQL 16 or older, which reject it.
