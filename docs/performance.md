# Performance measurements

`scripts/perf.sh` plays the same scenarios on an optimized build every time, reads the figures from inside the app,
and compares them with [`docs/perf-baseline.json`](perf-baseline.json). `scripts/release.sh` runs it after the tests
and stops when a scenario got worse than the baseline by more than its margin (`SKIP_PERF=1` skips it).

```bash
scripts/perf.sh                          # every scenario, 3 runs each, compared with the baseline (about 6 minutes)
scripts/perf.sh --scenario tabs          # one scenario (or several: tabs,ai-chat)
scripts/perf.sh --runs 5                 # more runs
scripts/perf.sh --update-baseline        # write the medians as the new baseline (commit it with the change)
scripts/perf.sh --no-build               # measure the last build again
scripts/perf.sh --sample tabs/resize     # one run with `sample` of the process during that phase
TABULA_PERF_KEEP=/tmp/perf scripts/perf.sh   # keep each run's JSON and log
```

Leave the Mac alone while it runs: the workspace window is put in front of the others at 1280×800 on the main
screen, and a run where another app's window covers it is run again. A locked screen draws nothing, so perf.sh
refuses to start. `launch` and `idle` need the test database containers, which it starts and stops again as
`scripts/test-dbs.sh` does (containers that were already running are left running).

## How it measures

- **The build** is `swift build -c release` with `-Xswiftc -DDEBUG` in `.build/perf`: optimized like a release, with
  the debug hooks that play the scenarios (`Sources/Tabula/DebugPerf*.swift`). It is never shipped; `release.sh`
  checks that the shipped binary has no debug hooks. It runs as `TabulaPerf`, so its settings are in a defaults
  domain of its own, removed before every run.
- **Each run** is a new process on a fresh copy of fixed data (`scripts/perf/seed-*.sql`), with a window of a fixed
  size. Every scenario sets up first (connect, open the tabs, run their queries, show each tab once) and only then
  measures its phases, with fixed pauses, so two runs do the same work. One unmeasured run warms the disk caches.
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
| threads | the process's threads at the end |
| bodies | SwiftUI body evaluations of the main views, counted by `PerfProbe.body` at the top of their `body` (debug builds only) |
| wakeups/s | (idle) times the process was woken up, a second |

The `launch` scenario also notes, in milliseconds since the process started: the first window on screen, the start
of connecting, connected, and the first rows of the table drawn.

## Scenarios

| Scenario | Data | Phases |
| --- | --- | --- |
| `launch` | PostgreSQL (`tabula_perf` database in the test container) | the process starting until the first 300 rows of `orders` are drawn |
| `tabs` | SQLite, 9 tabs: 3 queries with results, 6 tables of 300-row pages | `switch` (18 tab switches), `scroll` (three grids), `type` (28 keys in the editor, then 28 deletes), `resize` (the window from 1280×800 to 960×640 and back, twice, 30 steps each way), `inspector` (Row Details opened and closed 3 times) |
| `large-result` | SQLite, `orders` with 100,000 rows | `load` (`SELECT * FROM orders` without a row limit), `scroll` (its grid), `sort` (the table tab with 5,000-row pages, by three columns), `filter` (two conditions, then none) |
| `ai-chat` | SQLite, the fake model | `stream` (the whole answer arriving and drawn), `scroll` (the answer) |
| `idle` | SQLite, PostgreSQL, MySQL, Redis and MongoDB, one window each | `idle` (20 s with nothing to do) |

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

## Profiling

`scripts/perf.sh --sample tabs/resize` runs one scenario and samples the whole process with `sample` (1 ms, 5 s by
default, `--sample-seconds N`) from the start of that phase, into `.build/perf/samples/`. `sample` takes a second or
two to attach, so give it a few seconds more than the phase lasts. The build has its symbols, so the call tree names
Tabula's functions. If you record an Instruments trace instead, limit it to 20 seconds, check
that there are 8 GB free first, and delete the `.trace` and the temporary files it leaves under
`/private/var/folders/…/T` afterwards: traces can fill the disk.

To see whether a cost grows with the number of tabs, measure some phases only, with fewer tabs open:
`TABULA_DEBUG_PERF_PHASES=resize,inspector` skips the other phases (they show tabs up to the ninth) and
`TABULA_DEBUG_PERF_TABS=2` opens only the first 2 of the `tabs` scenario's nine tabs (the query tab and `customers`,
which the resize shows). The variables pass through perf.sh to the app:

```bash
TABULA_DEBUG_PERF_TABS=2 TABULA_DEBUG_PERF_PHASES=resize,inspector scripts/perf.sh --scenario tabs
```
