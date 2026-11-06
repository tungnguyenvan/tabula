# Feature support by database

[Back to the README](../README.md)

Which features work on which database. ✅ works, ➖ doesn't apply (the database has no such thing), ❌ not yet. A number points to a note below the tables.

- [AI](#ai)
- [Server views](#server-views)
- [Working with data and schemas](#working-with-data-and-schemas)
- [Notes](#notes)

## AI

| Feature | PostgreSQL | MySQL / MariaDB | SQLite | MongoDB | Redis |
| --- | :---: | :---: | :---: | :---: | :---: |
| [AI chat](ai.md#chat) | ✅ | ✅ | ✅ | ✅ | ✅ [1](#n1) |
| [Ask AI and Fix with AI](ai.md#in-the-editor) | ✅ | ✅ | ✅ | ✅ | ✅ [2](#n2) |
| [Suggestions while typing](ai.md#in-the-editor) | ✅ | ✅ | ✅ | ✅ | ❌ [2](#n2) |
| [Visual answers](ai.md#visual-answers) and the [dashboard](ai.md#dashboard) | ✅ | ✅ | ✅ | ✅ | ✅ |
| [Widgets of your own queries](ai.md#widgets-of-your-own-queries) | ✅ | ✅ | ✅ | ✅ | ❌ [3](#n3) |
| [Analysis notebooks](ai.md#analysis-notebooks) | ✅ | ✅ | ✅ | ✅ | ❌ |
| [Proposed data changes](ai.md#proposed-data-changes) | ✅ | ✅ | ✅ | ✅ | ❌ [4](#n4) |
| [Explain](queries.md#query-plans) and Ask AI about This Plan | ✅ | ✅ | ✅ [5](#n5) | ✅ [6](#n6) | ➖ |
| [Data dictionary](ai.md#data-dictionary) | ✅ | ✅ | ✅ [7](#n7) | ✅ [7](#n7) | ❌ |
| [Filter by description](ai.md#filter-by-description) | ✅ | ✅ | ✅ | ✅ | ❌ |
| [Generate test rows](ai.md#generate-test-rows) | ✅ | ✅ | ✅ | ✅ | ❌ |
| [Schema hints](ai.md#chat) (copies, soft-delete, likely joins) | ✅ | ✅ | ✅ | ✅ [8](#n8) | ➖ [9](#n9) |

## Server views

| Feature | PostgreSQL | MySQL / MariaDB | SQLite | MongoDB | Redis |
| --- | :---: | :---: | :---: | :---: | :---: |
| [Activity](queries.md#activity-sessions-and-locks) | ✅ | ✅ | ➖ | ✅ [10](#n10) | ✅ [11](#n11) |
| [Top Queries](queries.md#top-queries) / [Slow Log](redis.md#slow-log) | ✅ [12](#n12) | ✅ [13](#n13) | ➖ | ✅ [14](#n14) | ✅ [15](#n15) |
| [Health](schema.md#schema-health) | ✅ | ✅ | ✅ | ✅ | ✅ [16](#n16) |
| [Users & Roles](schema.md#users-roles-and-privileges) / [ACL users](redis.md#acl-users) | ✅ | ✅ | ➖ | ✅ | ✅ [17](#n17) |

## Working with data and schemas

| Feature | PostgreSQL | MySQL / MariaDB | SQLite | MongoDB | Redis |
| --- | :---: | :---: | :---: | :---: | :---: |
| [Read-only connections](connections.md#read-only-connections) | ✅ | ✅ | ✅ | ✅ | ✅ |
| [Checks before a statement runs](queries.md#checks-before-a-statement-runs) | ✅ | ✅ | ✅ | ✅ | ✅ [18](#n18) |
| [Importing files](editing.md#importing-files) | ✅ | ✅ | ✅ | ❌ | ➖ |
| [Dump and restore](connections.md#dump-and-restore) | ✅ | ✅ | ❌ | ❌ | ❌ |
| [Relationship diagram](schema.md#relationship-diagram) | ✅ | ✅ | ✅ | ➖ | ➖ |
| [Compare schemas](schema.md#compare-schemas) | ✅ | ✅ | ✅ | ❌ | ➖ |
| [Find in Database](queries.md#find-in-database) | ✅ | ✅ | ✅ | ✅ | ❌ [19](#n19) |
| [Copy As](editing.md#copying-and-exporting) (JSON, SQL INSERT, CSV, Markdown) | ✅ | ✅ | ✅ | ✅ [20](#n20) | ❌ |
| [Value editor](editing.md#the-value-editor) | ✅ | ✅ | ✅ | ✅ | ✅ [21](#n21) |
| [Following foreign keys](editing.md#following-foreign-keys) | ✅ | ✅ | ✅ | ➖ | ➖ |

## Notes

1. <a id="n1"></a>The chat sees key names, types and TTLs from a `SCAN` sample, never `KEYS`, and reads values only with bounded read-only commands Tabula checks first. [Redis AI](ai.md#redis).
2. <a id="n2"></a>In the console: Ask AI (⌘K) writes commands into the input and Fix with AI corrects a refused command; neither runs anything. The console's input has no suggestions while typing.
3. <a id="n3"></a>Redis dashboards take cards pinned from the chat; Add Widget… and Add to Dashboard… write SQL or MongoDB queries.
4. <a id="n4"></a>Redis writes at once and has no commit to hold pending changes in; the chat writes commands for the console instead.
5. <a id="n5"></a>`EXPLAIN QUERY PLAN` only: SQLite has no Explain Analyze.
6. <a id="n6"></a>`find` and `aggregate`, with `explain("queryPlanner")`, and `executionStats` for Explain Analyze of a read.
7. <a id="n7"></a>The descriptions are kept by Tabula. SQLite and MongoDB have no comments, so there are no COMMENT statements to open.
8. <a id="n8"></a>Leftover collections, soft-delete, status and mixed-type fields, from names and sampled types.
9. <a id="n9"></a>Redis has no schema; the chat gets the keys grouped into patterns with their counts, types and TTLs instead.
10. <a id="n10"></a>Operations from `$currentOp`, with Kill Op.
11. <a id="n11"></a>Clients from `CLIENT LIST`, with Kill Client.
12. <a id="n12"></a>Needs the `pg_stat_statements` extension.
13. <a id="n13"></a>Needs `performance_schema` on.
14. <a id="n14"></a>From the database profiler (`system.profile`), which must be on; there is no reset.
15. <a id="n15"></a>`SLOWLOG GET`, with Reset.
16. <a id="n16"></a>Memory, eviction and fragmentation from `INFO`, and the biggest keys from a sample.
17. <a id="n17"></a>Redis 6 and later.
18. <a id="n18"></a>The console's own rules: commands that would block the connection are refused and destructive ones are confirmed. No plan-based checks or Review with AI.
19. <a id="n19"></a>Keys are filtered by name pattern in the key list; values aren't searched.
20. <a id="n20"></a>SQL INSERT is written as `insertOne` commands.
21. <a id="n21"></a>In a key's value grid; a saved value is written to Redis at once.
