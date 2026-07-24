#!/usr/bin/env bash
#
# Workload definition: graph500 — BFS over a large Kronecker graph (seq-csr).
# Paper configuration: scale 27, edge factor 32 (~123 GB).
#
# The CSR adjacency lists give the inner loop batched-sequential access, which
# keeps leaf PTEs warm in cache; this is the workload where the h-final phase
# contributes the least (20.5%) and SagePTE's speedup is smallest.

DESCRIPTION="Graph500 BFS, scale 27 (~123 GB)"

BINARY="bench_graph500_st"
# Arguments after "--" are forwarded by the common driver to the benchmark.
ARGS="-- -s 27 -e 32 -V"

READY_FILE="/tmp/enablement/graph500_watch"

pre_run() {
    killall bench_graph500_st 2>/dev/null || true
}
