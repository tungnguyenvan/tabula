# AI agents (MCP)

[Back to the README](../README.md)

An agent working on your code, such as Claude Code, Codex or Cursor, can check the real schema and data through Tabula. Tabula opens the connections itself, with the passwords from the Keychain; the agent never sees them.

## Setup

1. In **Settings › AI › AI agents (MCP)**, turn on **Let AI agents use connections**.
2. Edit each connection agents may use and turn on **Allow AI agents (MCP)**. It is off for every connection until you do, and not available for Redis.
3. Add Tabula to your agent with the command Settings shows (**Copy**):
   - Claude Code: `claude mcp add tabula -- /Applications/Tabula.app/Contents/MacOS/tabula-mcp`
   - Codex: `codex mcp add tabula -- /Applications/Tabula.app/Contents/MacOS/tabula-mcp`
   - Cursor and others: `{"mcpServers":{"tabula":{"command":"/Applications/Tabula.app/Contents/MacOS/tabula-mcp"}}}`

## What agents can do

The agent gets four tools:

- `list_connections`: the name, kind and tag of the connections you allowed;
- `list_tables`;
- `describe_table`;
- `run_read_only_query`.

They have the [chat's limits](ai.md#read-only-queries): only reads, on a separate read-only connection, in a read-only transaction where the database has one, 15 seconds, at most 50 rows with long values cut. On **Production** connections Tabula asks before each query. Every statement an agent runs appears in the console log, marked with a sparkles symbol and the agent's name.

## How it works

`tabula-mcp` speaks MCP (the 2026-07-28 revision, and earlier ones that start with `initialize`) on standard input and output. It has no database code and never reads the Keychain: it passes each call to the running Tabula over a socket in `~/Library/Application Support/Tabula` that only your user can open. When Tabula isn't open, or agents are off, the tools answer "Open Tabula to use its connections".
