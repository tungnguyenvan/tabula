# Performance measurements

`scripts/perf.sh` plays the same scenarios on an optimized build every time, reads the figures from inside the app,
and compares them with [`docs/perf-baseline.json`](perf-baseline.json), or with another build measured in the same
session (`--compare`). `scripts/release.sh` runs it after the tests with `--compare release`, and stops when a
scenario got worse than the previous release by more than its margin (`SKIP_PERF=1` skips it).

```bash
scripts/perf.sh --compare v0.22.3        # each scenario on v0.22.3 and on this tree in turn, compared with each other
scripts/perf.sh --compare release        # the same with the last release tag before this version (what release.sh runs)
scripts/perf.sh --compare HEAD --build-only   # only build both, to measure them later with --no-build
scripts/perf.sh                          # the release's scenarios, 3 runs each, compared with the baseline (about 10 minutes)
scripts/perf.sh --all                    # every scenario (about 16 minutes)
scripts/perf.sh --scenario tabs          # one scenario (or several: tabs,ai-chat)
scripts/perf.sh --runs 5                 # more runs
scripts/perf.sh --update-baseline        # write the medians as the new baseline (commit it with the change)
scripts/perf.sh --no-build               # measure the last build again
scripts/perf.sh --sample tabs/resize     # one run with `sample` of the process during that phase
TABULA_PERF_KEEP=/tmp/perf scripts/perf.sh   # keep each run's JSON and log
```

Leave the Mac alone while it runs: the workspace window is put in front of the others at 1280×800 on the main
screen, and a run where another app's window covers it is run again. A locked screen draws nothing, so perf.sh
refuses to start. The scenarios on a server need test database containers, and only their own: `launch`, `schema`,
`diagram` and `live` PostgreSQL, `windows` PostgreSQL and Redis, `redis` Redis, `mongo` and `mongo-script` MongoDB,
and `idle` all four. perf.sh starts a container before the first scenario that needs it and stops it after the last (containers that were
already running are left running), and runs the scenarios without a server first. Their data is seeded before the
first scenario that uses it (about 7 s for the 3,000-table database) and removed after the last, also when a run
fails: the `tabula_perf` and `tabula_perf_schema` PostgreSQL databases, Redis database 15 and the `tabula_perf`
MongoDB database. A scenario added in #365 gets its own saved connections only in its own runs:
every saved connection is listed in the Connections window and the toolbar's menus, which changes what the others
measure.

Without `--all` or `--scenario`, perf.sh plays what `scripts/release.sh` runs: `tabs`, `large-result`, `ai-chat`,
`sql`, `launch`, `schema`, `diagram`, `idle`, `redis`, `mongo` and `mongo-script`. `live` and `windows` are left out
of it: their three runs take about 5 minutes, most of it waiting by design (52 and 25 seconds of each run), so run them with
`--all` before a release that touches live tabs, windows or connections, and after changing them. perf.sh prints how
long each run took; on the M2 of the baseline one run of `schema` takes 12 s, `sql` 24 s, `diagram` 13 s, `redis`
19 s, `mongo` 16 s, `mongo-script` 6 s, `live` 58 s and `windows` 61 s.

## How it measures

- **The build** is `swift build -c release` with `-Xswiftc -DDEBUG` in `.build/perf`: optimized like a release, with
  the debug hooks that play the scenarios (`Sources/Tabula/DebugPerf*.swift`). It is never shipped; `release.sh`
  checks that the shipped binary has no debug hooks. It runs as `TabulaPerf`, so its settings are in a defaults
  domain of its own, removed before every run.
- **Each run** is a new process on a fresh copy of fixed data (`scripts/perf/seed-*`, `make-script.py`), with a window
  of a fixed size. Every scenario sets up first (connect, open the tabs, run their queries, show each tab once) and
  only then measures its phases, with fixed pauses, so two runs do the same work. One unmeasured run warms the disk
  caches.
- **Input** goes through the app's event path: key presses and key equivalents sent to the window, scroll wheel
  events to the grid's scroll view one per frame, window resizes one step per frame. Tab switches call what
  View › Go to Tab (⌘1 to ⌘9) does.
- **The AI chat** answers from `scripts/perf/fake-model.py`, an OpenAI-compatible server on 127.0.0.1 that streams
  the same Markdown answer with a 96-row table at a fixed pace (about 2,000 characters a second). No real model is
  ever called.
- **Figures** (`Sources/Tabula/DebugPerfProbe.swift`), per phase:

| Figure | What it is |
| --- | --- |
| wall ms | how long the phase took |
| CPU ms | CPU time of every thread of the process (`getrusage`) |
| main CPU ms | CPU time of the main thread (`thread_info`) |
| main busy ms | time the main run loop was awake, from waking up to going back to sleep after Core Animation's commit |
| hitches, hitch ms | main-thread stretches longer than a frame at 60 Hz (16.7 ms), and their time past the frame: frames that were late |
| peak MB | the largest memory footprint (`phys_footprint`, what Activity Monitor shows as Memory) seen during the phase |
| +MB | the footprint at the end of the phase less the footprint at its start: memory it kept, or gave back when negative. Shown, not compared |
| threads | the process's threads at the end |
| bodies | SwiftUI body evaluations of the main views, counted by `PerfProbe.body` at the top of their `body` (debug builds only) |
| views made | AppKit views made during the phase by the views that count themselves with `PerfProbe.made` (the grid's cells and row numbers): in a phase that only scrolls, views the table didn't reuse. Shown, not compared with the baseline |
| wakeups/s | (idle) times the process was woken up, a second |

The `launch` scenario also notes, in milliseconds since the process started: the first window on screen, the start
of connecting, connected, and the first rows of the table drawn.

## Scenarios

| Scenario | Data | Phases |
| --- | --- | --- |
| `launch` | PostgreSQL (`tabula_perf` database in the test container) | the process starting until the first 300 rows of `orders` are drawn |
| `tabs` | SQLite, 9 tabs: 3 queries with results, 6 tables of 300-row pages | `switch` (18 tab switches), `scroll` (three grids), `type` (28 keys in the editor, then 28 deletes), `resize` (the window from 1280×800 to 960×640 and back, twice, 30 steps each way), `inspector` (Row Details opened and closed 3 times) |
| `large-result` | SQLite, `orders` with 100,000 rows, `wide` with 60 columns | `load` (`SELECT * FROM orders` without a row limit), `scroll` (its grid), `sort` (the table tab with 5,000-row pages, by three columns), `filter` (two conditions, then none), `inspector` (Row Details, opened beforehand on `wide`, following the selection over 20 rows). Notes the main thread's busy time a selection took (`inspector_row_busy_ms`, median, and `inspector_row_busy_max_ms`) |
| `ai-chat` | SQLite, the fake model | `stream` (the whole answer arriving and drawn), `scroll` (the answer) |
| `idle` | SQLite, PostgreSQL, MySQL, Redis and MongoDB, one window each | `idle` (20 s with nothing to do) |
| `schema` | PostgreSQL `tabula_perf_schema`: 3,000 tables, 300 views and 200 functions (`seed-postgres-schema.sql`) | `open` (the window moved from `tabula_perf` to it, as picking it in the sidebar does, until its 3,300 tables and views are listed), `scroll` (the sidebar), `filter` (7 letters typed in the sidebar's filter, then ⎋), `palette` (Open Anything opened, 12 letters typed, ⎋) |
| `sql` | SQLite, a 5,000-line SQL script (220 KB, `make-script.py`) | `open` (File › Open… after its panel, until the script is in the editor), `type-end` (12 keys at the end, then 12 deletes), `type-middle` (the same at line 2,500), `scroll` (the editor) |
| `diagram` | PostgreSQL `tabula_perf_schema`, schema `erd`: 200 tables, 299 foreign keys | `open` (the relationship diagram, until its 200 tables are drawn), `pan` (scrolling it down, across and back), `zoom` (a pinch: the zoom changing a little each frame, out to 40% and back, twice) |
| `live` | PostgreSQL `tabula_perf` | `metrics` (the Metrics tab refreshing every second, 20 s), `metrics-full` (the same for 10 s with the ten minutes of history the tab keeps, made up by `MetricsModel.fillHistory`), `dashboard` (a dashboard of two charts, a metrics card and a 200-row grid, refreshed every 2 s, 20 s, with the Metrics tab open behind it). Notes how many samples the hidden Metrics tab took meanwhile |
| `redis` | Redis database 15: 100,000 keys of every type, a 10,000-field hash and a 50,000-item list (`seed-redis.py`) | `open` (the key list read from the start), `browse` (20 more pages loaded while scrolling down), `scroll` (the 10,500 keys), `filter` (`session:1*`, hashes only, then everything), `hash` (the hash opened and all its 10,000 fields loaded and scrolled), `list` (the list opened, 5,000 items loaded and scrolled) |
| `mongo` | MongoDB `tabula_perf`: 1,000 documents of about 13 KB nested six levels deep (`seed-mongo.js`) | `load` (the collection's first 300 documents in the grid), `scroll` (down, across and back), `document` (three documents opened in the document editor and closed), `inspector` (Row Details following the selection over ten documents). Notes the main thread's busy time a selection took, as `large-result` does |
| `mongo-script` | MongoDB `tabula` (nothing seeded), a 5,000-line shell script (225 KB, `make-mongo-script.py`) | `type-end` (`db.orders.find` typed at the end, 14 keys, then 14 deletes), `type-middle` (the same at line 2,493) |
| `windows` | three windows, each with a SQLite, a PostgreSQL and a Redis connection of its own | `before` (5 s with only the Connections window), `open` (the windows and their 9 connections), `tabs` (a query with 500 rows and two tables in each SQL connection, a key's value in each Redis one: 18 tabs), `steady` (10 s left alone), `close` (a table tab of the first window and the PostgreSQL connection of the second closed, then the three windows), `after` (10 s left alone). It also prints the memory and threads a connection and a tab cost, and notes the workspaces, windows and connection sessions still alive after closing, whether the closed tab was still kept 5 s after closing it and the closed connection 10 s after, their window still open (`closed_tab_kept`, `closed_connection_kept`), and the footprint once the allocator has handed back its free memory. A closed tab or connection kept that long (#372), or a window, workspace, session, tab or connection still alive once its window has closed (#366), fails the run |

The `idle` scenario and the windows scenario's `before`, `steady` and `after` phases compare their wake-ups a
second and use the idle margins below; they show timers that keep running. In `windows`, `after` against `before`
is what closing the windows didn't give back.

## The check

`docs/perf-baseline.json` holds each figure's median over the runs, its spread (largest minus smallest, over the
median) and the Mac, display and window it was recorded on. A figure fails when its median is above
`max(baseline × (1 + fraction), baseline + floor)`; the fractions and floors are in `scripts/perf/report.py`, with why
they are what they are. On the M2 the baseline comes from, the medians of two invocations of one build differed by at
most 4% in the long phases (tabs, the chat's stream, scrolling 100,000 rows), 11 to 17% in the short ones (sorting,
typing, connecting to the first rows) and up to a third for the launch marks, so the margins are about twice that:
20% for CPU and main-thread time, 35% for hitch time, 10% for memory, 15% for body evaluations, 30% for launch.
Only the same Mac and display are compared: on another one, record a baseline first with `--update-baseline`.
Figures much better than the baseline are listed too, as a hint to record a new one.

## Against the previous release

A baseline recorded days earlier was measured under another load: other apps building, swap, the Mac's temperature.
That drift is larger than the margins, and failed the 0.22.3 release check twice on figures that hadn't changed
([#373](https://github.com/tungnguyenvan/tabula/issues/373)). `--compare` measures the reference in the same session
instead:

- **The reference build** is the given tag or commit (`release`: the last `v*` tag before HEAD, leaving out the one of
  the version in `VERSION`), built like the current tree's from a temporary git worktree with `Vendor/` copied in,
  into `.build/perf-ref/<commit>`. It is kept for the next run; building another reference deletes it, so there is
  one at a time (about 1.1 GB).
- **Each scenario** runs on both builds in turn, three times each (`--runs`), with the same data, the same
  containers and the same window: whatever the Mac does meanwhile affects both builds alike. The order swaps from one
  pair of runs to the next (reference then current, current then reference, …), so neither build always runs while
  the load rises, or first after the data was seeded. One unmeasured run of each build warms the caches first.
- **A figure fails** when the current build's median is above the reference's median by more than the margin of
  [the check](#the-check), and every run of the current build is above every run of the reference. When the two
  builds' runs overlap, the session was too noisy to tell such a difference. On a Mac busy with other builds and
  swapping, the runs of one build varied by up to half their median (`tabs` / `switch`: 371 to 715 ms of main
  thread), more than the margins, and two sessions of the same code against itself (v0.22.3) had medians up to 25%
  apart (`tabs` / `type`, `mongo` / `load`): comparing the medians alone failed both sessions, and so did asking
  them to be further apart than the reference's runs. The report shows, for each phase, the reference's figures,
  the current build's and the change, with `!` on the figures that failed.
- **Scenarios the reference plays differently** are measured on the current tree only and compared with the baseline
  as before. `scripts/perf/hooks.py` compares each scenario's code in `Sources/Tabula/DebugPerf*.swift` (its function
  and every function of those files it calls, comments and access modifiers aside) in both versions: a scenario
  added or changed since the reference isn't compared with it. The code that takes the figures (`phase`, `record`,
  `DebugPerfProbe.swift`) is left out, as only the figures both builds have are compared; perf.sh says when it
  changed.

The release's scenarios took 16 minutes on the M2 (against about 10 without `--compare`), plus 8 minutes the first
time to build the reference. `--build-only` builds both (and the reference only if it isn't kept yet) without
measuring, and `--no-build` then measures the current build as it is. The baseline is still the record of a release's
figures and what single-build runs compare with; `--update-baseline` and `--sample` measure one build, without
`--compare`.

## Profiling

`scripts/perf.sh --sample tabs/resize` runs one scenario and samples the whole process with `sample` (1 ms, 5 s by
default, `--sample-seconds N`) from the start of that phase, into `.build/perf/samples/`. `sample` takes a second or
two to attach, so the sampled phase waits 2.5 s for it before it starts (TABULA_DEBUG_PERF_SAMPLED); make
`--sample-seconds` about as long as the phase. TABULA_DEBUG_PERF_PHASES skips the phases you don't need (keep the ones
that set the sampled one up, such as `schema`'s `open`), and TABULA_PERF_KEEP keeps the log and figures as in a normal
run:

```bash
TABULA_DEBUG_PERF_PHASES=open,filter scripts/perf.sh --sample schema/filter --sample-seconds 5
```

The scroll phases last only two or three seconds: with `TABULA_DEBUG_PERF_SCROLL_REPEAT=4` they scroll down and back
up four times, and `TABULA_DEBUG_PERF_SCROLL_REPEAT=4 scripts/perf.sh --sample large-result/scroll --sample-seconds 6`
samples nothing but scrolling. The build has its symbols, so the call tree names Tabula's functions. If you record an
Instruments trace instead, limit it to 20 seconds, check
that there are 8 GB free first, and delete the `.trace` and the temporary files it leaves under
`/private/var/folders/…/T` afterwards: traces can fill the disk.

To see whether a cost grows with the number of tabs, measure some phases only, with fewer tabs open:
`TABULA_DEBUG_PERF_PHASES=resize,inspector` skips the other phases (they show tabs up to the ninth) and
`TABULA_DEBUG_PERF_TABS=2` opens only the first 2 of the `tabs` scenario's nine tabs (the query tab and `customers`,
which the resize shows). The variables pass through perf.sh to the app:

```bash
TABULA_DEBUG_PERF_TABS=2 TABULA_DEBUG_PERF_PHASES=resize,inspector scripts/perf.sh --scenario tabs
```

To see what stays alive after the `windows` scenario closes its windows, `TABULA_DEBUG_PERF_HOLD=90` keeps the
process 90 seconds after its last phase (the log says `PERF holding`): `heap <pid>` counts the objects of each class,
and `leaks <pid> --traceTree=<address>` shows what holds one of them.
