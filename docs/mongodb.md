# MongoDB

[Back to the README](../README.md)

- [Connecting](#connecting)
- [Browsing and filtering](#browsing-and-filtering)
- [Editing documents](#editing-documents)
- [Structure](#structure)
- [Query editor](#query-editor)
- [Limitations](#limitations)

<p align="center"><img src="screenshots/mongodb.png" width="900" alt="A MongoDB collection in the grid, with typed fields in the row details panel"></p>

## Connecting

<p align="center"><img src="screenshots/mongodb-connection.png" width="520" alt="A MongoDB connection to an Atlas cluster: DNS seed list, user, database, auth database and TLS"></p>

- **Hosts:** one, or several (`a:27017,b:27017`) for a replica set; if the first is down, the next is tried.
- **Atlas:** turn on **DNS seed list (mongodb+srv)**, and TLS is on by default. Tabula resolves the seed list with the Mac's resolver and refuses servers outside its domain, so a spoofed DNS answer can't redirect the connection. Options in the seed list's TXT record aren't read; set the auth database if it isn't `admin`.
- **User and password** are optional. **Auth database** (`authSource`) defaults to `admin`; **Database**, the one opened first, to `test`, and the sidebar's picker lists every database you may see.
- Authentication: SCRAM-SHA-1 or SCRAM-SHA-256. TLS is available for every connection. **Copy URL** gives a `mongodb://` URL.

## Browsing and filtering

- Collections and views are listed as tables. Documents are in the grid, `_id` first, with nested values inline and BSON types in Row Details. Sorting, paging and a total count work as on the other databases.
- **Filter:** `=` on `42` matches the number or the string, on a 24-digit hex id the ObjectId or the string; `contains` and the like are case-insensitive and also match numbers, dates and ids by their text (MongoDB 4.2 or later); fields can be paths such as `address.city`. The `{ }` button takes a query document instead.

## Editing documents

- **Edits keep the field's type:** `46` in a long field is stored as `NumberLong(46)`, `2025-02-03` in a date field as a date. To change a type, type a shell value such as `NumberDecimal("9.99")`.
- Commit sends `updateOne` / `deleteOne` / `insertOne` by `_id`, one by one, previewed first with ⇧⌘S; if one fails, the message says which were saved.
- **`{ }`** edits the whole document as JSON, replaced by `_id`, or inserts a new one.

<p align="center"><img src="screenshots/mongodb-document.png" width="560" alt="The JSON document editor: a whole order with ObjectId, NumberDecimal and ISODate values"></p>

## Structure

**Structure** shows the fields of the first 100 documents with their types, and indexes with their options. AI is told sampled field names; documents reach it only from the chat's [read-only queries](ai.md#read-only-queries). [Server metrics](queries.md#server-metrics) come from `serverStatus` and `dbStats`.

## Query editor

The query editor takes shell statements, one per line or separated by `;`, which may continue on the next line with `.sort(…)` and the like. It highlights them, beautifies them and completes collections, methods, fields and `$` operators:

```js
use shop
db.orders.find({ status: "paid", total: { $gte: NumberDecimal("100") } }, { items: 0 }).sort({ createdAt: -1 })
db.orders.aggregate([{ $group: { _id: "$status", n: { $sum: 1 } } }, { $sort: { n: -1 } }])
db.getCollection("audit log").countDocuments({ at: { $gte: ISODate("2026-01-01") } })
```

<p align="center"><img src="screenshots/mongodb-query.png" width="820" alt="An aggregation in the MongoDB query editor, with its results and the console log"></p>

- **Collections:** `find` / `findOne` (with `sort`, `skip`, `limit`, `projection`, `hint`, `collation`, `count()`, `explain()`), `aggregate`, `countDocuments`, `estimatedDocumentCount`, `distinct`, `insertOne` / `insertMany`, `updateOne` / `updateMany` / `replaceOne`, `deleteOne` / `deleteMany`, `findOneAndUpdate` / `Replace` / `Delete`, `createIndex(es)`, `dropIndex(es)`, `getIndexes`, `drop`, `renameCollection`, `stats`.
- **Databases:** `runCommand`, `adminCommand`, `getCollectionNames`, `getCollectionInfos`, `createCollection`, `createView`, `dropDatabase`, `stats`, `serverStatus`, `version`, `currentOp`, `getUsers`, `getRoles`, `getSiblingDB("other")`, and `show dbs`, `show collections`, `show users`, `use <db>`.
- **Values:** JSON, the shell's relaxed syntax (unquoted keys, single quotes, trailing commas, comments, `/regex/i`), `ObjectId`, `ISODate` / `new Date`, `NumberLong`, `NumberInt`, `NumberDecimal`, `UUID`, `BinData`, `Timestamp`, `MinKey` / `MaxKey`, and Extended JSON.
- Tabula reads these statements and sends the matching commands; it doesn't run JavaScript. Results show at most 50,000 documents per statement, and the row limit adds `.limit()` to finds and aggregations without one.
- Stop (⌘.) ends a running command on MongoDB 4.4 or later; documents it already changed stay changed.

## Limitations

- The query editor runs shell statements, not JavaScript.
- Edits from the grid aren't wrapped in a transaction.
- X.509, LDAP and Kerberos authentication aren't supported.
- The grid's columns come from the first 100 documents, so a field that appears only later shows up after it is seen on a page.
- Files can't be imported into collections yet.
