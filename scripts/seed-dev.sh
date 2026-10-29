#!/usr/bin/env bash
# Creates sample data in a throwaway store for trying Tabula (and for screenshots):
#   SQLite file + the tabula-test-pg / -mysql / -redis / -mongo containers from the README.
# Usage: scripts/seed-dev.sh [data-dir]   then   TABULA_DATA_DIR=<data-dir> swift run Tabula
set -euo pipefail

# Runs a command but gives up after N seconds (macOS has no `timeout`).
with_timeout() {
  local seconds=$1; shift
  "$@" & local pid=$!
  ( sleep "$seconds"; kill "$pid" 2>/dev/null ) & local watcher=$!
  wait "$pid" 2>/dev/null; local status=$?
  { kill "$watcher" && wait "$watcher"; } 2>/dev/null || true
  return $status
}

D="${1:-/tmp/tabula-dev-data}"
rm -rf "$D"; mkdir -p "$D"

sqlite3 "$D/shop.sqlite" <<'SQL'
CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE, city TEXT, created_at TEXT DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), total REAL, status TEXT);
CREATE INDEX orders_customer ON orders(customer_id);
CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 100;
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 750)
INSERT INTO customers (name, email, city) SELECT 'Customer ' || i, 'c' || i || '@example.com',
  CASE i % 4 WHEN 0 THEN 'Hà Nội' WHEN 1 THEN 'Đà Nẵng' WHEN 2 THEN NULL ELSE 'TP.HCM' END FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 2000)
INSERT INTO orders (customer_id, total, status) SELECT (i % 750) + 1, round((i * 37) % 500 + 0.99, 2),
  CASE i % 3 WHEN 0 THEN 'paid' WHEN 1 THEN 'pending' ELSE 'shipped' END FROM n;
SQL

if PGPASSWORD=tabula with_timeout 5 psql -q -h 127.0.0.1 -p 55432 -U tabula tabula -c 'select 1' >/dev/null 2>&1; then
PGPASSWORD=tabula psql -q -h 127.0.0.1 -p 55432 -U tabula tabula <<'SQL'
SET client_min_messages = warning;
DROP TABLE IF EXISTS products CASCADE;
CREATE TABLE products (id serial PRIMARY KEY, sku text UNIQUE NOT NULL, name text, price numeric(10,2), tags text[],
  attrs jsonb, launched date, updated_at timestamptz DEFAULT now());
INSERT INTO products (sku, name, price, tags, attrs, launched)
SELECT 'SKU-' || i, 'Product ' || i, (i * 13 % 900) + 0.5, ARRAY['tag' || (i % 5), 'x'],
  jsonb_build_object('color', CASE WHEN i % 2 = 0 THEN 'red' ELSE 'blue' END, 'stock', i % 40), date '2024-01-01' + i
FROM generate_series(1, 500) i;
SQL
fi

if with_timeout 5 docker exec tabula-test-mysql true 2>/dev/null; then
# utf8mb4: the client's default would store the Vietnamese names double-encoded.
docker exec -i tabula-test-mysql mysql --default-character-set=utf8mb4 -utabula -ptabula tabula 2>/dev/null <<'SQL'
DROP TABLE IF EXISTS employees;
CREATE TABLE employees (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(80), dept VARCHAR(40), salary DECIMAL(10,2), hired DATE, active TINYINT(1) DEFAULT 1);
INSERT INTO employees (name, dept, salary, hired) VALUES ('An', 'Eng', 3200.50, '2021-03-01'), ('Bình', 'Sales', 2100, '2022-07-15'),
  ('Chi', 'Eng', 4100, NULL), ('Dũng', NULL, 1800, '2023-11-20');
SQL
else
echo "MySQL container not reachable; skipping MySQL sample data" >&2
fi

if with_timeout 5 docker exec tabula-test-redis true 2>/dev/null; then
docker exec -i tabula-test-redis redis-cli --user tabula --pass tabula --no-auth-warning -n 1 >/dev/null <<'REDIS'
FLUSHDB
SET greeting "Xin chào, Tabula!"
SET config:app "{\"theme\":\"dark\",\"features\":[\"redis\",\"sql\"],\"limits\":{\"rows\":300}}"
SET session:abc123 "user=42" EX 3600
HSET user:42 name "Nguyễn An" email "an@example.com" city "Hà Nội" plan "pro"
HSET user:43 name "Trần Bình" email "binh@example.com" city "Đà Nẵng"
RPUSH queue:emails "welcome:42" "reset:43" "digest:42" "welcome:44"
SADD tags:popular redis postgres mysql sqlite swift
ZADD leaderboard 1520 an 1340 binh 990 chi 1875 dung
XADD events * type signup user 42
XADD events * type login user 42
XADD events * type purchase user 43 amount 19.99
INCR counter:visits
REDIS
docker exec tabula-test-redis redis-cli --user tabula --pass tabula --no-auth-warning -n 1 eval "for i=1,250 do redis.call('SET','cache:item:'..i, 'v'..i) end return 1" 0 >/dev/null
else
echo "Redis container not reachable; skipping Redis sample data" >&2
fi

if with_timeout 10 docker exec tabula-test-mongo mongosh --quiet -u tabula -p tabula --authenticationDatabase admin --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
docker exec -i tabula-test-mongo mongosh --quiet -u tabula -p tabula --authenticationDatabase admin shop >/dev/null <<'JS'
db.customers.drop(); db.orders.drop(); db.products.drop();
const cities = ["Hà Nội", "Đà Nẵng", "TP.HCM", null];
db.customers.insertMany(Array.from({ length: 750 }, (_, i) => ({
  name: "Customer " + (i + 1), email: "c" + (i + 1) + "@example.com",
  ...(cities[i % 4] ? { address: { city: cities[i % 4], country: "VN" } } : {}),
  tags: ["tag" + (i % 5)], vip: i % 9 === 0, joined: new Date(Date.UTC(2024, i % 12, (i % 28) + 1)),
  visits: i % 3 === 0 ? Long(i * 1000) : i,
})));
const ids = db.customers.find({}, { _id: 1 }).toArray().map(c => c._id);
db.orders.insertMany(Array.from({ length: 2000 }, (_, i) => ({
  customer: ids[i % ids.length], total: Decimal128(((i * 37) % 500 + 0.99).toFixed(2)),
  status: ["paid", "pending", "shipped"][i % 3], items: [{ sku: "SKU-" + (i % 50), qty: (i % 4) + 1 }],
  createdAt: new Date(Date.UTC(2025, i % 12, (i % 28) + 1, i % 24)),
})));
db.orders.createIndex({ customer: 1, createdAt: -1 });
db.customers.createIndex({ email: 1 }, { unique: true });
db.createView("big_orders", "orders", [{ $match: { total: { $gt: Decimal128("400") } } }]);
JS
else
echo "MongoDB container not reachable; skipping MongoDB sample data" >&2
fi

cat > "$D/connections.json" <<JSON
[
  {"id": "00000000-0000-0000-0000-000000000001", "name": "Shop (SQLite)", "kind": "sqlite", "host": "", "port": 0, "user": "", "database": "", "filePath": "$D/shop.sqlite", "tls": "disable", "tag": "local"},
  {"id": "00000000-0000-0000-0000-000000000002", "name": "Test Postgres", "kind": "postgres", "host": "127.0.0.1", "port": 55432, "user": "tabula", "database": "tabula", "filePath": "", "tls": "disable", "tag": "development"},
  {"id": "00000000-0000-0000-0000-000000000003", "name": "Test MySQL", "kind": "mysql", "host": "127.0.0.1", "port": 53306, "user": "tabula", "database": "tabula", "filePath": "", "tls": "require", "tag": "production"},
  {"id": "00000000-0000-0000-0000-000000000004", "name": "Test Redis", "kind": "redis", "host": "127.0.0.1", "port": 56379, "user": "tabula", "database": "1", "filePath": "", "tls": "disable", "tag": "staging"},
  {"id": "00000000-0000-0000-0000-000000000005", "name": "Test MongoDB", "kind": "mongodb", "host": "127.0.0.1", "port": 57017, "user": "tabula", "database": "shop", "filePath": "", "tls": "disable", "tag": "development"}
]
JSON
# Test passwords: debug builds read these instead of the Keychain when TABULA_DATA_DIR is set.
cat > "$D/passwords.json" <<'JSON'
{"00000000-0000-0000-0000-000000000002": "tabula", "00000000-0000-0000-0000-000000000003": "tabula", "00000000-0000-0000-0000-000000000004": "tabula", "00000000-0000-0000-0000-000000000005": "tabula"}
JSON
echo "Seeded $D"
