# AI assistant

[Back to the README](../README.md)

- [Turning it on](#turning-it-on)
- [Chat](#chat)
- [Read-only queries](#read-only-queries)
- [Proposed data changes](#proposed-data-changes)
- [Visual answers](#visual-answers)
- [Dashboard](#dashboard)
- [Analysis notebooks](#analysis-notebooks)
- [In the editor](#in-the-editor)
- [Filter by description](#filter-by-description)
- [Generate test rows](#generate-test-rows)
- [Data dictionary](#data-dictionary)
- [Providers](#providers)
- [What is sent](#what-is-sent)

For agents such as Claude Code, Codex and Cursor using your connections from outside Tabula, see [AI agents (MCP)](mcp.md).

<p align="center"><img src="screenshots/ai.png" width="900" alt="The AI chat answering with a query, and a model-written suggestion in grey in the SQL editor"></p>

## Turning it on

AI is off until you turn it on in **Settings › AI** (⌘,), and off for Production connections unless you allow it there. Each provider keeps its own address, models and key. Each system prompt (chat, Ask AI, Fix with AI, suggestions, filter, review) can be edited in **Settings › AI › Instructions**, or from the chat's menu; `{database}` stands for the database's name.

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

## Dashboard

Pin a chart, metric cards or a result grid from an answer with its pin button (or **Pin to Dashboard** in its context menu), and it joins the connection's dashboard: **View › Dashboard** (⌥⌘5), or **Open Dashboard** under the card you pinned.

- Cards sit in a grid, each the same component as in the chat, with the result it had when pinned; opening the dashboard shows the saved results without running anything.
- Each card's menu (the ⋯ button, or right-click) has **Refresh**, **Open in Query Tab**, **Rename…**, **Move Left** / **Move Right**, **Copy SQL**, **Copy Results** and **Remove from Dashboard**. Drag a card by its title to put it elsewhere.
- **Refresh All** runs every card's query; **Auto Refresh** runs them every 1, 5 or 15 minutes while the dashboard is shown. Each card shows when it last ran, a spinner while it runs and the error if it fails.
- Queries run exactly as the chat's components do: read-only check, the assistant's separate read-only connection, 15 seconds, console log, and the chat's settings (AI on, **Let the chat run read-only queries**). The AI isn't involved: Tabula runs the saved SQL.
- On Production, Auto Refresh is off and can't be turned on, and Refresh or Refresh All asks once before running.
- Dashboards are saved per connection next to its chats, and deleting the connection deletes its dashboard.

## Analysis notebooks

For a question that takes several steps ("why did revenue drop in October?"), a notebook tab works through it one read-only query at a time and keeps every step. Open one with **Analyze in Notebook**: the notebook button beside a question you asked in the chat (or in its context menu), **Analyze in Notebook** in the chat's ⋯ menu for the message you are writing, or the button the chat shows when the model suggests a notebook. **View › New Notebook** opens an empty one.

- **Step by step:** the model runs one query per step with the chat's tools. Each query becomes a query cell with a line on why it runs and its result as a grid, a chart or metric cards (the model can ask for a chart in the same `tabula-ui` form as [visual answers](#visual-answers)); what each result showed becomes a text cell, and a **Summary** cell ends it. At most 8 steps; the bottom bar shows the step, and **Stop** (⌘.) ends it at once.
- **Follow-ups** go in the same field: the model continues from every cell above, results included (cut to the chat's lengths).
- **Your own cells:** edit a query cell's SQL (or MongoDB command) and run it with its play button or ⌘↩; **Run All Below** and **Run All** run the queries again in order. Add text or query cells (Markdown in text cells; double-click to edit), move them with **Move Up** / **Move Down** and delete them from each cell's ⋯ menu, which also has **Copy SQL**, **Copy Results**, **Open in Query Tab** and, for a chart, **Show Rows**.
- **Read-only, as the chat:** every query, the model's or yours, runs through the chat's path: the read-only check, the assistant's separate read-only connection, 15 seconds, the console log. Nothing is ever written. It needs AI on (and allowed for Production) and **Let the chat run read-only queries**. On Production, each of the model's queries asks first, and Run All asks once for all of them. The model sees at most 50 rows of each result, with long values cut; the cells show up to 5,000.
- **Saved per connection** with the results, in `Notebooks` next to the chats, and deleted with the connection. The notebook's title menu lists them to reopen, **Open Anything** (⌘P) finds them, and the ⋯ menu renames or deletes one.
- **File › Export Notebook…** writes Markdown: text cells as they are, each query as a ```` ```sql ```` block with its result as a table of the first 50 rows, and each chart as a PNG file next to the `.md`.

## In the editor

- **Ask AI** (⌘K) inserts SQL at the cursor from a description, or replaces the selection with the change you describe; ⌘Z undoes it.
- **Fix with AI**, under an error, replaces the failing statement with a corrected one.
- **Ask AI about This Plan**, in an [Explain](queries.md#query-plans) result, explains the plan and suggests `CREATE INDEX` statements to insert or copy. Nothing is run.
- **Review with AI**, in the [confirmation before a statement runs](queries.md#checks-before-a-statement-runs), explains what the statement will do and may offer a safer version; **Use This** puts it in the editor without running it.
- **Suggestions while typing** replace the built-in grey suggestion (⎋ still lists those); Tab accepts. Models on this Mac are asked after a 0.25 s pause and, when they support it (Qwen2.5 Coder does), fill in between the text before and after the cursor. Suggestions can use their own provider: a small local model such as `qwen2.5-coder:0.5b` keeps up with typing, where command-line agents and large hosted models can't. They always use the quickest effort.

## Filter by description

The sparkles button in a table's filter bar takes a description in any language, such as "unpaid orders from this week over 100" or "customers in London who joined this month".

- The conditions it produces replace the bar's and are applied; you can untick or change them, and ⌘Z brings back the previous filter.
- Each condition is checked: the column must exist, the operator be one of the filter's, and the value read as the column's type. Dates are written as the column compares them, in your time zone.
- What conditions can't express ("the top 10 by total") is answered with the reason.
- PostgreSQL, MySQL / MariaDB, SQLite and MongoDB.

## Generate test rows

**Generate Rows…** fills a table with realistic test data. Find it in the menu of the **+** button under the grid (hold it, or click its arrow), in the table's context menu in the sidebar, and in the **Edit** menu. Choose how many rows (1 to 500, 20 by default) and, if you like, describe them: "customers in Europe, half of them VIP".

- The model is sent the table's schema: columns, types, NULL rules, defaults, primary and unique keys, CHECK constraints, enum values and foreign keys. Never its rows.
- **Foreign keys** get existing values. By default Tabula picks them at random from the referenced table after the answer, and they aren't sent. Tick **Use existing ids for foreign keys** to send up to 200 values of each referenced key, so the model can choose fitting ones (European country codes, say); they are read on the assistant's read-only connection.
- Every value is checked before it reaches the grid: its type (whole numbers in range, dates that exist, lengths, numeric precision), NULL rules, enum values and simple `IN (…)` checks, uniqueness within the new rows and against the rows already in the table (the new rows' values are looked up on the read-only connection, and what is found isn't sent), and that foreign key values exist. MongoDB documents are checked against each other only; a duplicate key there is reported by the commit. Auto-increment, serial, identity and generated columns are left to the database, and so are defaults the model leaves out. A row that fails a check is dropped, and the sheet lists each one with the reason.
- The rows are added as new rows in the grid, one step for ⌘Z; preview them with ⇧⌘S and commit with ⌘S, as with your own. Production connections need AI allowed there, and the commit still asks first.
- More than 100 rows are asked for in parts of 100, each told the unique values the parts before took.
- PostgreSQL, MySQL / MariaDB, SQLite, and MongoDB collections, whose documents get the fields and types seen in sampled documents (dates stay dates, longs stay longs).
- The instructions can be changed in Settings › AI › Instructions › Test data; Restore Default brings back Tabula's.

## Data dictionary

A short description of each table and column, saying what it holds, its unit and what its codes mean, so the AI uses the real meaning of `status = 3` rather than a guess. Tabula keeps the descriptions per connection, in `~/Library/Application Support/Tabula/Dictionaries`, and deletes them with the connection.

- **Describe with AI…** is in a table's Structure tab and its context menu in the sidebar; **Describe Tables with AI…** in the sidebar's context menu (right-click below the tables, or the schema picker) describes the whole schema.
- The model is sent the tables' and columns' names, types, primary and foreign keys, the database's comments and the current descriptions. Tick **Include sample values** to send up to 5 distinct values of each column too, from its first 100 rows, each cut to 40 characters and read on the assistant's read-only connection. Without it no rows are sent.
- Large schemas go 20 tables per request, with the progress shown and **Stop**, which keeps what came back.
- The proposals are listed table by table: the current text, the proposed one, which you can change, and a checkbox. **Save** keeps the ticked ones. Names the model made up are left out.
- Structure has a **Description** column, and a field for the table's own, to write or change them yourself. PostgreSQL and MySQL comments are the starting text: they show as the placeholder, go to the AI where there is no description, and stay marked as coming from the database when saved unchanged.
- The grid's column headers show the description in their tooltip.
- The chat, Ask AI, Fix with AI, Review with AI, filter by description and Generate Rows send the descriptions with the schema, at most 200 characters each and 6,000 in all. Suggestions while typing don't, to stay fast.
- **Open as COMMENT Statements** (in Structure, or **Open Descriptions as COMMENT Statements** in the sidebar's context menu for the schema) writes them as `COMMENT ON TABLE` / `VIEW` / `COLUMN` statements on PostgreSQL, and as `ALTER TABLE … COMMENT = …` on MySQL. MySQL can change a column's comment only by restating the column's whole definition, which could change the column if Tabula got it wrong, so only table descriptions are written there; the script says what was left out. The script opens in a query tab and Tabula never runs it: run it yourself, with the usual checks before a statement runs.
- PostgreSQL, MySQL / MariaDB, SQLite and MongoDB (collections and their sampled fields). SQLite and MongoDB have no comments to read or write.
- The instructions can be changed in Settings › AI › Instructions › Data dictionary.

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
- For Ask AI about This Plan, the statement, plan and the tables' indexes; for Review with AI, the statements, Tabula's findings, the connection's tag and the plans; for a described filter, the table's columns, today's date and the time zone; for Fix with AI, the error message with quoted values removed (errors can quote row values, such as a duplicate key).
- **Rows only from the chat's read-only queries**, at most 50 per query and only with that setting on. Ask AI, Fix with AI, suggestions and described filters never see rows. Rows read to draw visual answers aren't sent.

- The data dictionary's descriptions of the tables and columns, with the schema (not with suggestions while typing). For Describe with AI, the tables' structure, comments and current descriptions, and sample values only when you tick Include sample values.
- For Ask AI about This Plan, the statement, plan and the tables' indexes; for a described filter, the table's columns, today's date and the time zone; for Generate Rows, the table's schema, and existing foreign key values only when you tick Use existing ids; for Fix with AI, the error message with quoted values removed (errors can quote row values, such as a duplicate key).
- **Rows only from the chat's read-only queries**, at most 50 per query and only with that setting on. Ask AI, Fix with AI, suggestions, described filters and Generate Rows never see rows, and Describe with AI sees sample values only when you allow it. Rows read to draw visual answers aren't sent.

- **Rows only from the chat's and notebooks' read-only queries**, at most 50 per query and only with that setting on. Ask AI, Fix with AI, suggestions, described filters and Generate Rows never see rows. Rows read to draw visual answers aren't sent.
- **AI is off for Production connections** unless you allow it in Settings.
- Conversations stay on this Mac in `~/Library/Application Support/Tabula/Chats` and are deleted with their connection. Prompts reach command-line agents on standard input, not as arguments other users could see. API keys are kept in the login Keychain.
