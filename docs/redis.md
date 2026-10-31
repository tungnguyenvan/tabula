# Redis

[Back to the README](../README.md)

<p align="center"><img src="screenshots/redis.png" width="820" alt="Redis keys and a hash value"></p>

- [Connecting](#connecting)
- [Keys](#keys)
- [Values](#values)
- [Key details](#key-details)
- [Console](#console)
- [Metrics](#metrics)
- [Limitations](#limitations)

## Connecting

Redis 6 and 7, including managed services: a password or an ACL user, the database index, and TLS (`rediss://` in a [connection string](connections.md#connection-strings)). User is optional (an ACL user on Redis 6 and later; empty for `requirepass`) and Database is the index, 0 by default.

## Keys

- Keys are listed with `SCAN`, never `KEYS`, so this is safe on large production instances: type, TTL, size and a preview, filtered by a pattern such as `user:*` (⌘F) or by type, sorted naturally and loading more as you scroll.
- The sidebar lists databases with their key counts.
- Create (⌘N) and delete (⌫) keys.

## Values

- **Strings** in an editor, with Format JSON; ⌘S saves and keeps the TTL.
- **Hashes, lists, sets, sorted sets and streams** in a grid, with *Load more* for big ones; ⌘I adds an element and ⌫ deletes the selected ones.
- Double-click to edit a key, TTL, short value or cell in place. A value with a line break or bytes that aren't text is edited in the key's pane instead.
- **Changes are written to Redis immediately.** Multi-step edits, such as renaming a hash field or changing a set member, run in `MULTI` / `EXEC`; renaming onto a field or member that exists is refused.
- Strings over 1 MB and binary values are read-only; use the console for them.

## Key details

Size, memory usage, encoding and TTL. Set or remove an expiry, or rename (never over another key).

## Console

The console (⌘T) works as `redis-cli` does, with quotes, escapes, formatted replies and history (↑ ↓); `SELECT` switches the sidebar too.

- It refuses `SUBSCRIBE`, `MONITOR` and blocking commands with no timeout, which would freeze the connection, and `MULTI` and `WATCH`, which would hold the connection it shares with the key browser. `EVAL` runs several commands at once.
- It asks before `FLUSHALL`, `FLUSHDB`, `SHUTDOWN`, `REPLICAOF`, `FUNCTION FLUSH`, `CLUSTER RESET` / `FLUSHSLOTS`, `DEBUG` and `FAILOVER`, and on Production before any command not known to only read.
- Stop (⌘.) ends a Lua script or function once it has run for 5 seconds (on a shared server it stops whichever script is running, so Production asks first) and unblocks a waiting command such as `BLPOP` or `XREAD BLOCK`. Other commands run to the end.

## Metrics

Server metrics (⌥⌘4) from `INFO`: memory, clients, throughput, hit rate, persistence and keyspace.

## Limitations

- Redis Cluster and Sentinel aren't supported yet; connect to a single node.
- Pub/Sub, `MONITOR`, `MULTI` and `WATCH` aren't available in the console.
- AI agents (MCP) can't use Redis connections.
