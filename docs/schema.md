# Structure and schema

[Back to the README](../README.md)

- [Structure](#structure)
- [Relationship diagram](#relationship-diagram)
- [Functions, procedures and triggers](#functions-procedures-and-triggers)
- [Compare schemas](#compare-schemas)

## Structure

**Structure** (⌥⌘2) shows a table's columns with type, nullability, default, comment, description and primary key, and its indexes with their definitions. The descriptions are Tabula's [data dictionary](ai.md#data-dictionary): type one in the **Description** column (or the field above the columns for the table) and press Return; **Describe with AI…** proposes them all for you to review, and **Open as COMMENT Statements** writes them as comments to run on PostgreSQL and MySQL. PostgreSQL's Default column shows `GENERATED ALWAYS AS …` for generated columns. Indexes that can't be read show a note instead of looking like a table without indexes. On MongoDB, Structure shows the [fields sampled from the first 100 documents](mongodb.md#structure).

<p align="center"><img src="screenshots/structure.png" width="820" alt="Structure view"></p>

## Relationship diagram

**Relationship diagram** (⌥⌘3) shows the schema's tables with foreign-key lines, laid out by dependency. Drag tables, zoom (30% to 200%), show key columns only, and export a PNG. Tables whose columns couldn't be read are named. Databases without foreign keys, such as MongoDB, don't show it.

<p align="center"><img src="screenshots/diagram.png" width="820" alt="Relationship diagram"></p>

## Functions, procedures and triggers

PostgreSQL and MySQL functions, procedures and triggers, and SQLite triggers, are in the sidebar: view, edit and save them with ⌘S, create new ones from a template, or delete them. Saving never loses a routine:

- PostgreSQL functions use `CREATE OR REPLACE`.
- PostgreSQL and SQLite triggers are recreated in one transaction.
- On MySQL, which can't run DDL in a transaction, the original is put back if the new definition fails.

## Compare schemas

**File › Compare Schemas…** (PostgreSQL, MySQL, SQLite) opens a window that compares a source with a target, each a saved connection and a schema (for example Development `public` against Production `public`, or two schemas of one connection), and writes the SQL script that makes the target match the source.

- Both sides are read on read-only connections of their own, so comparing never asks on Production.
- The tree lists each table and view that differs, with its columns (type, NOT NULL, default, generated), primary key, indexes and foreign keys marked as only in the source, only in the target or different, and the functions, procedures and triggers. **Only Differences** and the search field narrow it.
- The script is in the target's dialect and in dependency order: foreign keys, views and indexes that change or go are dropped first, then tables are created and altered, then indexes, views, foreign keys and routines are created. On PostgreSQL the script runs in one transaction.
- A column that may have been renamed (one removed and one added of the same type) is added and dropped, with the `RENAME COLUMN` to use instead in a comment.
- SQLite tables whose columns or keys change are rebuilt the usual way (a new table, the rows copied, the old one dropped, the new one renamed). Steps Tabula can't write in full, such as SQLite generated columns, are commented out with what to fill in.
- Statements that remove what only the target has (DROP TABLE, DROP COLUMN…) are commented out unless you turn on **Include Drops**.
- **Copy**, **Save As…** or **Open in Query Tab** on the target connection: Tabula never runs the script itself.
- CHECK constraints, collations, sequences, enum types and permissions aren't compared.
