#!/usr/bin/env bash
#
# Workload definition: btree — B-tree insert/lookup benchmark.
# Paper configuration: ~125 GB working set.  Sparse pointer-chasing, so it
# allocates the largest number of leaf page tables of all our workloads
# (183,835 expansions at 4 KB in Table III).

DESCRIPTION="B-tree operations (~125 GB working set)"

BINARY="bench_btree_st"
ARGS=""

READY_FILE="/tmp/enablement/btree_watch"

pre_run() {
    killall bench_btree_st 2>/dev/null || true
}
