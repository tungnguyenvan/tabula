#!/usr/bin/env bash
# Times Tabula against the test containers, measures the app's memory with large pages open, and writes
# docs/benchmarks.md. Needs the containers from the README (tabula-test-pg, -mysql, -redis, -mongo).
# Usage: scripts/benchmark.sh [--rows N] [--runs N]
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d /tmp/tabula-bench.XXXXXX)
OUT=docs/benchmarks.md
# Seconds the app gets to connect and load a page before its memory is read.
SETTLE=15
PAGE_SIZES=(300 5000)

echo "==> Timings"
swift build -c release --product TabulaBench
TABULA_BENCH_SQLITE="$WORK/bench.sqlite" TABULA_BENCH_OUTPUT="$WORK/timings.md" .build/release/TabulaBench "$@"

echo "==> Memory"
# An optimized app with the debug hooks that open a table at launch (never shipped: release builds have no hooks).
swift build -c release --product Tabula -Xswiftc -DDEBUG --build-path "$WORK/build"
APP="$WORK/build/release/Tabula"
mkdir -p "$WORK/data"
cat > "$WORK/data/connections.json" <<JSON
[
  {"id": "00000000-0000-0000-0000-0000000000B1", "name": "Bench PostgreSQL", "kind": "postgres", "host": "127.0.0.1", "port": ${TABULA_TEST_PG_PORT:-55432}, "user": "tabula", "database": "tabula", "filePath": "", "tls": "disable", "tag": "local"},
  {"id": "00000000-0000-0000-0000-0000000000B2", "name": "Bench MySQL", "kind": "mysql", "host": "127.0.0.1", "port": ${TABULA_TEST_MYSQL_PORT:-53306}, "user": "tabula", "database": "tabula", "filePath": "", "tls": "require", "tag": "local"},
  {"id": "00000000-0000-0000-0000-0000000000B3", "name": "Bench SQLite", "kind": "sqlite", "host": "", "port": 0, "user": "", "database": "", "filePath": "$WORK/bench.sqlite", "tls": "disable", "tag": "local"},
  {"id": "00000000-0000-0000-0000-0000000000B4", "name": "Bench MongoDB", "kind": "mongodb", "host": "127.0.0.1", "port": ${TABULA_TEST_MONGO_PORT:-57017}, "user": "tabula", "database": "tabula_bench", "filePath": "", "tls": "disable", "tag": "local"}
]
JSON
cat > "$WORK/data/passwords.json" <<'JSON'
{"00000000-0000-0000-0000-0000000000B1": "tabula", "00000000-0000-0000-0000-0000000000B2": "tabula", "00000000-0000-0000-0000-0000000000B4": "tabula"}
JSON

footprint_of() { # connection id, page size → the process footprint once the page has loaded
  TABULA_DATA_DIR="$WORK/data" TABULA_DEBUG_OPEN="$1" TABULA_DEBUG_TABLE=bench_items TABULA_DEBUG_PAGE_SIZE="$2" "$APP" >/dev/null 2>&1 &
  local pid=$!
  sleep "$SETTLE"
  footprint "$pid" 2>/dev/null | awk '/phys_footprint:/ { print $2 " " $3; exit }'
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

{
  echo "| Table open in the grid | ${PAGE_SIZES[0]} rows per page | ${PAGE_SIZES[1]} rows per page |"
  echo "| --- | ---: | ---: |"
  for entry in "PostgreSQL:B1" "MySQL:B2" "SQLite:B3" "MongoDB:B4"; do
    name=${entry%%:*}; id="00000000-0000-0000-0000-0000000000${entry##*:}"
    small=$(footprint_of "$id" "${PAGE_SIZES[0]}"); large=$(footprint_of "$id" "${PAGE_SIZES[1]}")
    echo "| $name | $small | $large |"
  done
} > "$WORK/memory.md"
cat "$WORK/memory.md"

VERSION=$(cat VERSION)
CHIP=$(sysctl -n machdep.cpu.brand_string)
MACOS=$(sw_vers -productVersion)
image() { docker inspect --format '{{.Config.Image}}' "$1" 2>/dev/null || echo "not running"; }
{
  echo "# Benchmarks"
  echo
  echo "Tabula $VERSION on $CHIP, macOS $MACOS, $(date -u +%Y-%m-%d). Servers run in Docker on the same Mac:"
  echo "$(image tabula-test-pg), $(image tabula-test-mysql), $(image tabula-test-mongo), $(image tabula-test-redis)."
  echo "Regenerate with \`scripts/benchmark.sh\`."
  echo
  echo "Every step goes through Tabula's own drivers and the statements the app generates, so the times include"
  echo "turning each value into the text a grid cell shows. They are times on this Mac with the server next to it:"
  echo "over a network, add the round trips."
  echo
  echo "## Timings"
  echo
  cat "$WORK/timings.md"
  echo
  echo "## Memory"
  echo
  echo "The app's footprint (what Activity Monitor shows as Memory) ${SETTLE} seconds after opening the benchmark table, with"
  echo "nothing else open. The table has the columns of the timing tests (id, name, email, amount, status, JSON or a"
  echo "nested document, a timestamp)."
  echo
  cat "$WORK/memory.md"
} > "$OUT"
rm -rf "$WORK"
echo "Wrote $OUT"
