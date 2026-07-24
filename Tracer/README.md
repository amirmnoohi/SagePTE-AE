# SagePTE · Tracer

Memory-trace capture for the SagePTE nested-paging evaluation.

This directory is a fork of [DynamoRIO](https://dynamorio.org) whose `drcachesim`
client has been extended with an *enabler* mechanism, so recording can be turned
on at a chosen moment rather than at process start. On top of it sit two scripts:

| Script | Purpose |
| :-- | :-- |
| **`run.sh`** | run a benchmark under the tracer and record its memory trace |
| **`convert_trace.sh`** | decode a raw trace into the form the simulator replays |

Every component of the artifact exposes its entry point as `run.sh`:
`Tracer/run.sh`, `PageTables/Guest/run.sh`, `PageTables/Host/run.sh`.

---

## Where this fits

```
  ┌───────────────┐   ┌──────────────────────┐   ┌──────────────────┐   ┌───────────────┐
  │  Workloads/   │──▶│       Tracer/        │──▶│   PageTables/    │──▶│  Simulator/   │
  │               │   │                      │   │                  │   │               │
  │  benchmarks   │   │  ▸ run.sh            │   │  ▸ Guest/run.sh  │   │ ▸ run_arm.sh  │
  │  + definitions│   │  ▸ convert_trace.sh  │   │  ▸ Host/run.sh   │   │ ▸ run_x86.sh  │
  └───────────────┘   └──────────────────────┘   └──────────────────┘   └───────────────┘
                            memory trace            guest page table        page-walk
                                                    host page table          latency
                                                                            per design
```

The simulator needs **three** inputs. This directory produces the first.

---

## Quick start

Two terminals. The tracer pauses partway through so the page table can be
captured; see [Why it pauses](#why-it-pauses) below.

```bash
# ── Terminal 1 ──────────────────────────────────────────────
cd SAGEPTE-AE
./Tracer/run.sh debug            # 16 GB GUPS, a good smoke test
                                   # ... runs, then pauses and waits

# ── Terminal 2 ──────────────────────────────────────────────
cd SAGEPTE-AE
./PageTables/Guest/run.sh debug   # captures the guest page table

# ── back in Terminal 1 ──────────────────────────────────────
# press ENTER; the workload resumes and the trace completes
```

List what you can run:

```bash
./Tracer/run.sh --list
```

---

## The life of a trace

```
  time ────────────────────────────────────────────────────────────────────────▶

  1  LAUNCH        workload starts under the tracer, recording OFF
                   │
  2  INITIALISE    it builds its working set — Redis loads its dataset,
                   │   GUPS touches its whole table    ⏱ minutes … hours
                   ▼
  3  READY         workload writes READY_FILE
                   │   └──▶ Tracer/run.sh switches recording ON
                   ▼
  4  PAUSE   ⏸     workload is SIGSTOPped — frozen, page table complete
                   │   └──▶ you run:  PageTables/Guest/run.sh <workload>
                   │   └──▶ you press ENTER
                   ▼
  5  RECORD  ▶     workload resumed; trace accumulates until --max-refs
                   ▼
  6  DONE          drmemtrace.dir/
```

### Why recording is delayed

Steps 1–2 are setup, not the behaviour the paper measures. Every benchmark here
signals when its working set is built, and only then does recording begin — so
the trace covers **steady state only**. This has a second, essential
consequence: the guest page table is fully populated at that moment, so the
trace and the page-table snapshot describe the *same* state.

### Why it pauses

`/proc` exposes a process's page table only while that process is **alive**.
Once a run ends, its page table is gone for good — it cannot be recovered
afterwards. Printing a reminder is not enough either: a short workload finishes
long before anyone can type the command (2 billion references can take under
20 seconds).

So at step 4 the workload is **`SIGSTOP`ped**. It is frozen — its address space
untouched and fully readable — until you confirm the capture, then `SIGCONT`ed.
A trace is a *sequence* of memory references, so the pause costs wall-clock time
only; it also pins the snapshot to an exact point in the trace.

Skip it with `--no-pause` (or run non-interactively, where it is skipped
automatically and the dumper must be run concurrently instead).

---

## `run.sh`

```
./Tracer/run.sh <workload> [options]
./Tracer/run.sh --list
```

| Option | Effect | Default |
| :-- | :-- | :-- |
| `-o, --output DIR` | where to write the trace | `Data/<workload>` |
| `-n, --max-refs N` | stop after N memory references | `2000000000` |
| `-t, --ack-timeout S` | seconds to wait for recording to start | `120` |
| `-f, --force` | overwrite an existing output directory | off |
| `-v, --verbose` | mirror DynamoRIO's output to the terminal | off |
| `--no-pause` | do not hold the workload for the page-table capture | off |
| `-l, --list` | list available workloads | — |
| `--no-color` | disable colour | auto |
| `-h, --help` / `-V, --version` | help / version | — |

### What it writes

```
Data/<workload>/
├── drmemtrace.dir/     memory trace  (raw/*.raw + raw/modules.log)
├── pt_dump.guest       guest page table (GVA→GPA)  ← PageTables/Guest/run.sh
├── pt_dump.host        host page table  (GPA→HPA)  ← copied back from the KVM host
└── meta/               everything internal
    ├── trace.state         run state — the contract with the dumper
    ├── tracer.log          DynamoRIO + benchmark output
    ├── raw2trace.log       conversion log
    ├── enabler.txt         tracer handshake file
    ├── pmap.txt            VMA map, for reference
    └── pt_dump.guest.raw   untouched /proc/page_tables dump
```

Only the three top-level entries are simulator inputs; `meta/` holds state,
logs and intermediates. The trace directory is renamed from DynamoRIO's
`drmemtrace.<app>.<pid>.<seq>.dir` to a stable `drmemtrace.dir` — it still
matches the `drmemtrace*` glob the simulator uses to discover it.

### Exit codes

| Code | Meaning |
| :-: | :-- |
| `0` | trace completed |
| `1` | usage error, or a faulty workload definition |
| `2` | environment error (tracer not built, missing prerequisite) |
| `3` | the workload or the tracer failed |
| `130` | interrupted |

---

## `convert_trace.sh`

Decodes `raw/*.raw` into `drmemtrace.trace`, the file the simulator replays.

```bash
./Tracer/convert_trace.sh debug
```

```
  raw/*.raw  ──────────────▶  drmemtrace.trace  ──────────────▶  Simulator
   compact per-thread            one record per                   replays
   encoding + modules.log        reference & instruction          references
        459 MB                        3.7 GB   (~9x)
```

> **Optional as a step — not as a cost.** If you skip it, the simulator performs
> the identical conversion on its first run, writing the same file to the same
> place. Running it here just pays the cost visibly, up front, instead of
> silently prefixing your first and longest simulation.

**Disk:** decoding expands a trace by roughly **9×** — a 15 GB raw trace becomes
~135 GB. That space is required to simulate either way. The script estimates the
output, refuses to start if it will not fit, and shows live progress:

```
  ⠹ decoding  ███████████░░░  3.3GB / ~4.1GB  (80%)  ETA ~3s   16s
  ✔ converted, 3.7G (20s)
```

| Option | Effect |
| :-- | :-- |
| `-o, --output DIR` | directory holding the trace (default `Data/<workload>`) |
| `--dir DIR` | convert a `drmemtrace.*.dir` directly, by path |
| `-f, --force` | reconvert even if a complete trace is present |
| `--skip-space-check` | proceed despite the free-space estimate |
| `--compact` | status lines only (for nesting in another script) |

It is safe to re-run: a **complete** trace is detected (via the end-of-trace
footer, exactly as `file_reader_t::is_complete()` does) and skipped, while an
**interrupted** conversion is detected and redone automatically.

---

## Workloads

Everything benchmark-specific lives in `../Workloads/<name>.sh`, so adding one
never means editing `run.sh`.

| Workload | Benchmark | Footprint |
| :-- | :-- | --: |
| `debug` | GUPS, small — pipeline smoke test | 16 GB |
| `gups` | GUPS random access | 128 GB |
| `redis` | Redis key-value store | 155 GB |
| `btree` | B-tree operations | 125 GB |
| `graph500` | BFS, scale 27 | 123 GB |
| `xsbench` | Monte Carlo particle transport | 84 GB |
| `canneal` | PARSEC circuit routing *(needs a dataset)* | 62 GB |
| `memcached` | Memcached *(needs an external load generator)* | 95 GB |
| `stream` | STREAM bandwidth kernel | — |

### Adding one

Copy `../Workloads/_template.sh` to `../Workloads/<name>.sh`:

```bash
DESCRIPTION="one line, shown by --list"
BINARY="bench_mything_st"            # bare name → Workloads/bin; or absolute path
ARGS="-- -s 27"                      # or ARGV=(…) for arguments containing spaces
READY_FILE="/tmp/enablement/mything_watch"   # empty → fall back to READY_DELAY
REQUIRES=""                          # paths that must exist (datasets, helpers)

pre_run()    { :; }   # before launch: kill stale processes, clear state
post_start() { :; }   # after launch, before recording: external load generator
post_run()   { :; }   # after the workload exits
```

It is immediately runnable as `./Tracer/run.sh <name>`. Names beginning with
`_` are treated as internal and hidden from `--list`.

---

## How the tracer is told to start

`run.sh` and the DynamoRIO client communicate through one small file,
`enabler.txt`, which carries three states:

```
   Tracer/run.sh               enabler.txt                DynamoRIO client
      │                               │                            │
      │──── "0"  not yet ────────────▶│                            │
      │                               │◀── polls every 2^26 instrs ─┤
      │        (waits for READY_FILE) │                            │
      │──── "1"  start now ──────────▶│                            │
      │                               ├──── reads 1 ──────────────▶│  recording ON
      │                               │◀─── writes <pid> ──────────┤
      │◀─── reads <pid>  (ack) ───────┤                            │
      │                                                            │
      └─▶ publishes meta/trace.state ──▶ consumed by PageTables/Guest/run.sh
```

| Value | Written by | Meaning |
| :-- | :-- | :-- |
| `0` | `run.sh` | running, do not record yet |
| `1` | `run.sh` | begin recording now |
| `<pid>` | DR client | acknowledgement — recording, and this is the traced PID |

That protocol stops at `run.sh`. What the rest of the artifact consumes is
`meta/trace.state`, plain `KEY=VALUE`:

```
WORKLOAD=debug     STATUS=tracing     APP_PID=14776
OUTPUT_DIR=…       TRACE_DIR=…        UPDATED_AT=…
```

`STATUS` moves `starting → tracing → done` (or `failed` / `interrupted`).
`PageTables/Guest/run.sh` waits for `tracing`, so it may be started **before** the tracer and
will fire by itself.

---

## Building

```bash
./build.sh          # → build/bin64/drrun
```

Uses gcc/g++ 7 (Ubuntu 20.04). The compiler is fixed at CMake *configure* time,
so a `make`-level `CC=` override has no effect — reconfigure a clean `build/`
if you need to change it.

---

## Troubleshooting

| Symptom | Cause & fix |
| :-- | :-- |
| `DynamoRIO internal crash`, SIGSEGV/SIGILL at startup, on *every* program | **AVX-512.** DR 7.0.0 predates it: the kernel writes a 2440-byte XSTATE into DR's 832-byte buffer at signal init. Disable AVX-512 for the VM (`-cpu host,-avx512f,-avx512dq,-avx512cd,-avx512bw,-avx512vl,-avx512ifma,-avx512vbmi`) or via `clearcpuid=` on the guest kernel command line. |
| `cannot execute binary file: Exec format error` | The build is corrupt (zero-filled binaries). Rebuild: `./build.sh`. |
| `the output directory already exists` | Deliberate, so a previous capture is never silently destroyed. Use `--force`, or `--output DIR`. |
| `the workload exited before it signalled readiness` | The benchmark died during setup — usually it could not allocate its working set. See `tracer.log`. |
| `the tracer did not confirm within Ns` | The client polls only every 2²⁶ instructions; a nearly-idle workload can be slow to ack. Raise `--ack-timeout`. |
| The page table could not be captured | It only exists while the workload runs. Re-run and capture during the pause, or start `PageTables/Guest/run.sh` first and use `--no-pause`. |
| `not enough free space to convert this trace` | Decoding needs ~9× the raw size. Free space, or move the trace to a larger filesystem — the simulator needs the same room. |

---

## See also

| | |
| :-- | :-- |
| `../Workloads/_template.sh` | the workload definition contract |
| `../PageTables/Guest/run.sh` | guest page table (GVA→GPA) |
| `../PageTables/Host/run.sh` | host page table (GPA→HPA), run on the KVM host |
| `../Simulator/README.md` | replay, and the page-walk latency model |
| `README` | the upstream DynamoRIO documentation |
