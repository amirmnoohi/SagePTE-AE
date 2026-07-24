# SagePTE Nested Page Walk Simulator

Built on DynamoRIO (BSD license, see
`License.txt`).

This is the simulator component of the SagePTE artifact. It is the third stage
of the evaluation pipeline:

```
 (1) Tracer                (2) PageTables           (3) Simulator (this folder)
 memory trace of the  -->  guest + host page      -->   replay: for every TLB miss,
 workload (drmemtrace)     table snapshots              simulate the full 2D nested
                                                        walk and record where each
                                                        reference was served
```

The simulator is built on DynamoRIO 7.0 with a heavily modified `drcachesim`
client (`clients/drcachesim/simulator/cache_simulator.cpp`). It models TLBs,
guest and host page walk caches (PWCs), the L1I/L1D/L2/LLC cache hierarchy and
DRAM. It replays every memory reference of the trace; on each TLB miss it
performs the complete 24-reference nested page walk (guest tables translated
through the host tables, then the final host walk for the data page) and
records, per walk, which component of the memory hierarchy served each
reference. This per-walk breakdown is exactly what the SagePTE evaluation
needs: SagePTE's benefit is computed by removing the final host-walk
references (the *h-final phase*) from the recorded walks.

The SagePTE extensions over stock `drcachesim` (marked `SagePTE` in the
sources) comprise:
* guest and host page table dump inputs (`-pt_dump_file`, `-vt_pt_dump_file`)
  and full 2D nested walk replay,
* guest **and** host page walk cache modeling,
* per-walk serving-component histograms ("Page Walk Statistics"),
* logging of trace addresses missing from the dumps (coverage diagnostics).

## Requirements

* Linux x86-64 (developed on Ubuntu 20.04), ~2 GB free disk for the build.
* `gcc-7`/`g++-7` recommended (the toolchain the artifact was developed with);
  `install.sh` falls back to the system compiler if gcc-7 is absent.
* CMake >= 3.2.

## Build

```bash
./install.sh          # builds into build/, produces build/bin64/drrun
```

## Inputs

> The host page table must contain **no `NAN` fields**. The host kernel module
> writes `NAN` for a page-table level that does not exist for a given frame, and
> the simulator parses every field with `%llx`, which cannot read it. The
> augmentation stage (`PageTables/Host/host_pt_augmentor.c`, run automatically
> by `PageTables/Host/run.sh`) replaces each with a unique unallocated PFN and
> writes the record-count header.

A run consumes one directory (`<TRACE_DIR>`) containing three things:

1. **The trace**: an offline `drmemtrace.*.dir` directory produced by the
   tracer component of this artifact.

2. **`pt_dump.guest`** — the guest page table snapshot. Text file; first line is the
   number of entries, then one line per mapped 4 KB guest page:

   ```
   VA,PE1,PE2,PE3,PE4,PA        (all hex, no 0x prefix)
   ```

   | Field | Meaning |
   |-------|---------|
   | `VA`  | page-aligned guest **virtual address** (full address) |
   | `PE1..PE4` | guest-physical **PFNs** of the guest page-table pages at levels 1-4 (root to leaf) |
   | `PA`  | guest-physical **PFN** of the data page |

3. **`pt_dump.host`** — the host (Stage-2) page table snapshot. Same shape,
   but keyed by guest-physical address:

   | Field | Meaning |
   |-------|---------|
   | `GPA` | page-aligned **guest-physical address** (full address) |
   | `PE1..PE4` | host-physical **PFNs** of the host page-table pages at levels 1-4 |
   | `PA`  | host-physical **PFN** backing that guest page |

   The host dump must cover the data GPAs **and** the GPAs of the guest
   page-table pages themselves (every `PE1..PE4` value of `pt_dump.guest`), because
   the nested walk translates guest table addresses through the host tables
   too.

Trace references whose VA is not in `pt_dump.guest` (or whose GPA is not in
`pt_dump.host`) are counted as `num_not_found` / `vt_num_not_found` in the
output and skipped. Large counts mean the snapshots don't cover the traced
execution; the page-table augmentor tools of this artifact can patch such
gaps.

## Run

```bash
./run_arm.sh <TRACE_DIR>     # paper configuration: Ampere Altra Max (Neoverse N1)
./run_x86.sh <TRACE_DIR>     # x86 Xeon-class configuration
```

The ARM configuration (used for the paper's results): 48-entry fully
associative L1 TLBs, 1280-entry 5-way STLB, 64 KiB 4-way L1I/L1D, 1 MiB 8-way
L2, 16 MiB 16-way shared SLC, 96 cores. All parameters are plain `drrun`
knobs — copy a run script to customize.

The log goes to `Results/<name>/sim_arm.log` (or `sim_x86.log`) at the repo
root, where `<name>` is the input directory name (e.g. `redis`) — `Data/` holds
only simulator inputs. It is not streamed to the terminal: the simulator writes
a line per page walk, so even the small `debug` capture produces a 4 MB log,
and a full trace runs for hours. The terminal instead shows one progress line
with a percentage and an estimate, measured from how far into the decoded trace
the analyzer has actually read. Pass `--follow` to stream the log anyway, or
watch it from another shell:

```bash
tail -f Results/<name>/sim_arm.log
```

Each run also writes `Results/<name>/analysis_arm.txt` (or `analysis_x86.txt`)
with the parsed final statistics, and prints it when the run ends. The first
300 M references are cache/TLB warmup; the page walk statistics cover only
post-warmup execution.

Both run scripts are thin: they declare a cache and TLB geometry and source
`_simulate.sh`, which does everything else. To add a configuration, copy one of
them and change the numbers.

## Output

The log ends with TLB and cache statistics followed by the key section:

```
Page Walk Statistics:
MEMORY,ZERO,ZERO,ZERO,PWC,...,LLC,MEMORY,RANGE_HIT,	12345
...
```

Each line is one unique page-walk pattern and the number of TLB misses that
exhibited it. The tokens name the component that served each of the 24
references of the nested walk, in this order:

```
 G1H1 G1H2 G1H3 G1H4  G1     host walk for the guest L1 table's GPA, then the guest L1 entry
 G2H1 G2H2 G2H3 G2H4  G2
 G3H1 G3H2 G3H3 G3H4  G3
 G4H1 G4H2 G4H3 G4H4  G4     G4 = the guest leaf PTE read
 UDH1 UDH2 UDH3 UDH4         final host walk for the data page's GPA
                             = the "h-final phase" that SagePTE eliminates
```

Token meanings: `L1`/`L2`/`LLC` = served by that cache level, `MEMORY` = DRAM,
`PWC` = page-walk-cache hit at that level, `ZERO` = reference skipped (covered
by a PWC hit at a higher level). The trailing `RANGE_HIT`/`RANGE_MISS` flag
reports range-table coverage, used for the DMT comparison. With THP (2 MB
pages in guest and host) walks have 15 references: 3 guest levels x (3 host
refs + 1 guest ref) + 3 h-final refs.

## Analysis

Each run automatically produces `Results/<name>/analysis_{arm,x86}.txt` via
`scripts/analyze_log.sh`, which extracts the log's final "Page Walk
Statistics" dump and feeds it to `scripts/parse_walk_stats.py`. The parser
converts the histogram into average walk latencies per design, using the
per-component reference costs (PWC 1, L1 4, L2 14, LLC 54, DRAM 200 cycles).
To re-analyze a log by hand:

```bash
scripts/analyze_log.sh Results/<name>/sim_arm.log
```

It reports the average latency of every walk position (`G1H1..UDH4`), the
h-final share of total walk latency, and the average walk latency and speedup
for every design: nested paging (all references), **SagePTE** (h-final
references removed), and the comparison designs DMT, ECPT, FPT, ASAP
and Agile Paging, with formulas ported from the paper's processor tool
(`Formula.cs`; evaluated per pattern, frequency-weighted). The per-design walk-cycle ratios
(T_sim_Design / T_sim_NPW) are the simulator's contribution to the paper's
end-to-end performance projection (Methodology, Eq. 3).

## Minimal working example

`example/` contains a self-contained smoke test that exercises the full
simulator without needing the tracer or a VM: a pre-captured trace of a tiny
program (`smoke.c`, which touches a fixed 16 MB region three times) together
with synthetic-but-consistent guest and host page table dumps for that region
(`gen_dumps.py`).

```bash
./install.sh                                          # if not built yet
./run_x86.sh example                                  # ~seconds
cat ../Results/example/analysis_x86.txt               # analysis (auto-generated)
```

The analysis should closely match `example/expected_analysis.txt`
(9548 post-warmup walks; NPW ~109 cycles; SagePTE speedup ~1.25x). The large
`num_not_found` count is expected: the synthetic dumps deliberately cover only
the 16 MB test region, so code/stack/library references are skipped. Note how
even in this toy, the leaf references (`G4`, `UDH4`) are the slowest positions
of the walk — the locality asymmetry that SagePTE exploits.

## Known issues

* **Tracing on modern x86 under the debug build**: capturing a *new* trace
  with this debug-built `drrun` on AVX-512 CPUs can hit a DynamoRIO 7.0
  debug assert (`signal.c:517 !YMM_ENABLED() || ALIGNED(...)`). This does
  not affect the artifact flow — replaying with `-indir` runs the analyzer
  standalone, without instrumenting any application. If you do need to
  capture traces on such a machine, build a release copy
  (`cmake <this dir> && make -j` in a separate build directory, i.e. without
  `-DDEBUG=ON`) or use the tracer component.
* Missing `pt_dump.guest`/`pt_dump.host` paths produce a clean startup error.
