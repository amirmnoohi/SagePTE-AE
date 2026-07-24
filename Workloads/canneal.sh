#!/usr/bin/env bash
#
# Workload definition: canneal — PARSEC simulated-annealing circuit router.
# Paper configuration: ~62 GB working set.
#
# NOTE: canneal is the only workload that needs an external input netlist, and
# it is not shipped with the artifact (it is ~GB-scale).  Download it and place
# it at Workloads/datasets/canneal, or point CANNEAL_DATASET at your copy:
#
#     CANNEAL_DATASET=/path/to/canneal Tracer/run.sh canneal
#
# Source: see datasets/README.md in the DMT workload distribution.

DESCRIPTION="Canneal circuit routing, PARSEC (~62 GB; needs a dataset)"

CANNEAL_DATASET="${CANNEAL_DATASET:-$WORKLOAD_DIR/datasets/canneal}"

BINARY="bench_canneal_st"
# nthreads, swaps-per-temperature, temperature, netlist, annealing steps
ARGV=(1 150000 2000 "$CANNEAL_DATASET" 10000)

READY_FILE="/tmp/enablement/canneal_watch"

# Fail early and clearly if the netlist is missing, rather than after the
# tracer has already started.
REQUIRES="$CANNEAL_DATASET"

pre_run() {
    killall bench_canneal_st 2>/dev/null || true
}
