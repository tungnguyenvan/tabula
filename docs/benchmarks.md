# Benchmarks

Tabula 0.4.1 on Apple M2, macOS 26.1, 2026-10-25. Servers run in Docker on the same Mac:
postgres:16, mysql:8.4, mongo:8.0, redis:7.4.
Regenerate with `scripts/benchmark.sh`.

Every step goes through Tabula's own drivers and the statements the app generates, so the times include
turning each value into the text a grid cell shows. They are times on this Mac with the server next to it:
over a network, add the round trips.

## Timings

Rows per table: 100000. Each step: one warm-up, then 7 runs (Connect 5, the large query 3); times in milliseconds.

### PostgreSQL

| Step | Median | Slowest | Rows |
| --- | ---: | ---: | ---: |
| Connect | 4.12 | 5.82 |  |
| Catalog: schemas, tables, columns, indexes | 2.44 | 2.66 | 6 |
| Page of 300 | 2.41 | 5.46 | 300 |
| Page of 1000 | 8.40 | 10.5 | 1000 |
| Page of 5000 | 30.7 | 32.8 | 5000 |
| Page of 300 at row 50000 | 3.44 | 4.17 | 300 |
| Page of 300 sorted by an unindexed column | 9.27 | 11.0 | 300 |
| Filtered page (name contains 77) + count | 29.6 | 33.4 | 300 |
| Count all rows | 3.21 | 3.32 | 100000 |
| Query returning 50000 rows | 298 | 310 | 50000 |
| Commit 100 edited cells | 18.2 | 22.2 | 100 |

### MySQL

| Step | Median | Slowest | Rows |
| --- | ---: | ---: | ---: |
| Connect | 4.20 | 5.63 |  |
| Catalog: schemas, tables, columns, indexes | 1.97 | 2.45 | 2 |
| Page of 300 | 1.49 | 1.50 | 300 |
| Page of 1000 | 3.29 | 3.76 | 1000 |
| Page of 5000 | 8.57 | 9.36 | 5000 |
| Page of 300 at row 50000 | 10.9 | 12.0 | 300 |
| Page of 300 sorted by an unindexed column | 33.3 | 33.6 | 300 |
| Filtered page (name contains 77) + count | 17.6 | 18.2 | 300 |
| Count all rows | 2.02 | 2.08 | 100000 |
| Query returning 50000 rows | 70.8 | 72.2 | 50000 |
| Commit 100 edited cells | 26.7 | 27.3 | 100 |

### SQLite

| Step | Median | Slowest | Rows |
| --- | ---: | ---: | ---: |
| Connect | 0.05 | 0.07 |  |
| Catalog: schemas, tables, columns, indexes | 0.04 | 1.34 | 1 |
| Page of 300 | 0.24 | 0.27 | 300 |
| Page of 1000 | 0.83 | 0.84 | 1000 |
| Page of 5000 | 3.94 | 4.11 | 5000 |
| Page of 300 at row 50000 | 0.57 | 0.59 | 300 |
| Page of 300 sorted by an unindexed column | 7.04 | 7.50 | 300 |
| Filtered page (name contains 77) + count | 5.87 | 6.46 | 300 |
| Count all rows | 0.62 | 1.36 | 100000 |
| Query returning 50000 rows | 39.4 | 39.4 | 50000 |
| Commit 100 edited cells | 0.87 | 1.02 | 100 |

### MongoDB

| Step | Median | Slowest | Rows |
| --- | ---: | ---: | ---: |
| Connect | 3.32 | 4.50 |  |
| Catalog: schemas, tables, columns, indexes | 2.56 | 2.64 | 1 |
| Page of 300 | 3.94 | 5.11 | 300 |
| Page of 1000 | 10.5 | 12.2 | 1000 |
| Page of 5000 | 43.2 | 48.0 | 5000 |
| Page of 300 at row 50000 | 15.5 | 17.8 | 300 |
| Page of 300 sorted by an unindexed column | 32.6 | 34.7 | 300 |
| Filtered page (name contains 77) + count | 49.1 | 50.6 | 300 |
| Count all rows | 0.38 | 0.53 | 100000 |
| Query returning 50000 rows | 421 | 421 | 50000 |
| Commit 100 edited cells | 25.1 | 27.9 | 100 |

### Redis

| Step | Median | Slowest | Rows |
| --- | ---: | ---: | ---: |
| Connect | 0.63 | 0.73 |  |
| Scan 500 keys | 0.29 | 0.32 | 500 |
| Scan 500 keys + type, TTL, size, preview | 30.2 | 32.3 | 500 |
| Scan keys matching bench:hash:* | 1.89 | 1.98 | 505 |
| Page of a 5,000-field hash | 0.27 | 0.30 | 200 |

### MongoDB shell text (no server)

| Step | Median | Slowest | Rows |
| --- | ---: | ---: | ---: |
| Parse 50000 documents | 400 | 401 | 50000 |
| Write 50000 documents and their cells | 612 | 625 | 50000 |

## Memory

The app's footprint (what Activity Monitor shows as Memory) 15 seconds after opening the benchmark table, with
nothing else open. The table has the columns of the timing tests (id, name, email, amount, status, JSON or a
nested document, a timestamp).

| Table open in the grid | 300 rows per page | 5000 rows per page |
| --- | ---: | ---: |
| PostgreSQL | 81 MB | 83 MB |
| MySQL | 78 MB | 82 MB |
| SQLite | 77 MB | 78 MB |
| MongoDB | 82 MB | 86 MB |
