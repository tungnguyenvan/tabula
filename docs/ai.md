# AI assistant

[Back to the README](../README.md)

- [Turning it on](#turning-it-on)
- [Chat](#chat)
- [Read-only queries](#read-only-queries)
- [Proposed data changes](#proposed-data-changes)
- [Visual answers](#visual-answers)
- [In the editor](#in-the-editor)
- [Filter by description](#filter-by-description)
- [Providers](#providers)
- [What is sent](#what-is-sent)

For agents such as Claude Code, Codex and Cursor using your connections from outside Tabula, see [AI agents (MCP)](mcp.md).

<p align="center"><img src="screenshots/ai.png" width="900" alt="The AI chat answering with a query, and a model-written suggestion in grey in the SQL editor"></p>

## Turning it on

AI is off until you turn it on in **Settings › AI** (⌘,), and off for Production connections unless you allow it there. Each provider keeps its own address, models and key. Each system prompt (chat, Ask AI, Fix with AI, suggestions, filter) can be edited in **Settings › AI › Instructions**, or from the chat's menu; `{database}` stands for the database's name.

<p align="center"><img src="screenshots/ai-settings.png" width="520" alt="Settings › AI with a model running in Tabula for Ask AI and suggestions"></p>

## Chat

**AI Chat** (⌥⌘A) opens the panel on the right. It writes queries you can **Insert**, **Run** or copy, and on MongoDB connections it writes shell commands.

- It knows your tables, keys and schema: the model is told table names as SQL needs them (`dev.transactions`), column types, primary and foreign keys and the default schema, and the editor's SQL.
- It looks things up with [read-only queries](#read-only-queries) to answer from the real data, and shows every step.
- Answers stream in, with the model's reasoning shown while it thinks, then folded into "Thought for N s". For models that reason, an **Effort** menu sets how long.
- A model menu under the message field switches models.
- Conversations are saved per connection. The panel's title lists earlier ones to open again or delete, and the pencil starts a new one.

## Read-only queries

To answer, the chat can list and describe tables (columns, indexes, foreign keys), search [saved queries](queries.md#saved-queries-and-sql-files) and run a read-only query; each step shows in the conversation. Tabula runs the steps itself, for every provider, so no MCP setup is needed (Claude Code and Codex keep their own tools off).

- **Only reads run:** one `SELECT`, `WITH … SELECT`, `EXPLAIN`, `SHOW` or `DESCRIBE`, without comments, backslashes or server functions such as `pg_terminate_backend` and `query_to_xml`; on MongoDB `find`, `aggregate` (without `$out` / `$merge`), `countDocuments` and `distinct`, without `$where` / `$function`. Anything else is refused, and the assistant writes it as SQL for you to run.
- **On their own connection:** they run on a separate connection, each in a read-only transaction (PostgreSQL, MySQL) or with SQLite's `query_only`, stopped after 15 seconds on every database, so they can't change data or touch your transactions. They appear in the console log.
- **Limited:** at most 50 rows of each result, with long values cut, go to the model.
- **Production asks:** on Production connections the chat asks before each query (**Allow** / **Don't Allow**).
- **You can turn them off:** **Let the chat run read-only queries** in Settings › AI. The assistant then sees only the structure. It is on for new setups, and stays off if you used AI before the chat could run queries, until you turn it on.

<p align="center"><img src="screenshots/ai-tools.png" width="820" alt="The chat answering from the real data: it ran an aggregate on MongoDB, shown as a step above the answer"></p>

## Proposed data changes

Off by default (**Let the chat propose data changes** in Settings › AI). Asking the chat to change rows ("mark order 42 as shipped") becomes uncommitted edits in the table's tab:

- Tabula never runs a statement the model wrote. It checks every table, column and primary key against the real table, opens the table's tab filtered by primary key to exactly those rows, and adds the changes as uncommitted edits.
- Preview with ⇧⌘S, take them back with ⌘Z or Discard, commit with ⌘S. Production still asks before the commit.
- PostgreSQL, MySQL / MariaDB and SQLite tables with a primary key, at most 500 rows at a time, and not while the tab holds edits of your own.

## Visual answers

Answers can show charts (bar, line, area, point, pie), result grids with **Open in Query Tab**, metric cards, forms for queries with placeholders (filled in as quoted values and run read-only), choices you click to reply, and diagrams of the tables involved, drawn natively.

- The model can only describe components from this fixed set.
- Charts, grids and cards carry a query, not data. Tabula runs it with the chat's rules (read-only check, separate connection, 15 seconds, **Allow** on Production, console log) and reads up to 5,000 rows for drawing, which aren't sent to the model. So a chart can't show numbers the model made up.
- Results are saved with the conversation, and the refresh button runs the query again.
- **Visual answers** in Settings › AI turns them off.

## In the editor

- **Ask AI** (⌘K) inserts SQL at the cursor from a description, or replaces the selection with the change you describe; ⌘Z undoes it.
- **Fix with AI**, under an error, replaces the failing statement with a corrected one.
- **Ask AI about This Plan**, in an [Explain](queries.md#query-plans) result, explains the plan and suggests `CREATE INDEX` statements to insert or copy. Nothing is run.
- **Suggestions while typing** replace the built-in grey suggestion (⎋ still lists those); Tab accepts. Models on this Mac are asked after a 0.25 s pause and, when they support it (Qwen2.5 Coder does), fill in between the text before and after the cursor. Suggestions can use their own provider: a small local model such as `qwen2.5-coder:0.5b` keeps up with typing, where command-line agents and large hosted models can't. They always use the quickest effort.

## Filter by description

The sparkles button in a table's filter bar takes a description in any language, such as "unpaid orders from this week over 100" or "customers in London who joined this month".

- The conditions it produces replace the bar's and are applied; you can untick or change them, and ⌘Z brings back the previous filter.
- Each condition is checked: the column must exist, the operator be one of the filter's, and the value read as the column's type. Dates are written as the column compares them, in your time zone.
- What conditions can't express ("the top 10 by total") is answered with the reason.
- PostgreSQL, MySQL / MariaDB, SQLite and MongoDB.

## Providers

| Provider | Runs | Setup |
| --- | --- | --- |
| Model on this Mac | Inside Tabula, offline | Nothing to install. Download one in Settings › AI (Qwen2.5 Coder 0.5B to 7B, Llama 3.2 1B and 3B; from about 490 MB), add a GGUF file, or paste a link. Downloads are checked against their published SHA-256. GPU on Apple silicon, CPU on Intel. |
| Apple Intelligence | On the Mac, offline | macOS 26 with Apple Intelligence on |
| Ollama | On the Mac | Install [Ollama](https://ollama.com/download), then download a model in Settings › AI: `qwen2.5-coder:0.5b` (about 0.4 GB), `deepseek-coder:1.3b` or `qwen2.5-coder:1.5b` for suggestions; `qwen2.5-coder:3b`, `qwen2.5-coder:7b` or `sqlcoder:7b` for whole queries. |
| OpenAI-compatible API | Your server or a provider | Base URL, API key and model: LiteLLM, LM Studio, llama.cpp, vLLM, OpenAI and others |
| Claude API | Anthropic | API key; Opus, Sonnet or Haiku 5.5 (default `claude-opus-5-5`; a faster one can be set for suggestions) |
| Claude Code, Codex | Your installed agent, with its own sign-in | Installed and signed in once in Terminal. Run without tools (Claude Code) or in a read-only sandbox (Codex). Too slow for suggestions. |

Claude Code and Codex run without your own coding setup (Claude Code's hooks, MCP servers, skills and slash commands, and Codex's MCP servers); your account and model settings still apply. A model running in Tabula is released after five minutes unused.

## What is sent

- Table and column names of the current schema, and the SQL around the cursor (or the selection). On MongoDB, sampled field names.
- For Ask AI about This Plan, the statement, plan and the tables' indexes; for a described filter, the table's columns, today's date and the time zone; for Fix with AI, the error message with quoted values removed (errors can quote row values, such as a duplicate key).
- **Rows only from the chat's read-only queries**, at most 50 per query and only with that setting on. Ask AI, Fix with AI, suggestions and described filters never see rows. Rows read to draw visual answers aren't sent.
- **AI is off for Production connections** unless you allow it in Settings.
- Conversations stay on this Mac in `~/Library/Application Support/Tabula/Chats` and are deleted with their connection. Prompts reach command-line agents on standard input, not as arguments other users could see. API keys are kept in the login Keychain.
