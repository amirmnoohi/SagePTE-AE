#!/usr/bin/env bash
#
# Workload definition: xsbench — Monte Carlo neutron transport cross-section
# lookup kernel.  Paper configuration: 170,000 grid points, 4 M particles
# (~84 GB), single thread.

DESCRIPTION="XSBench Monte Carlo particle transport (~84 GB)"

BINARY="bench_xsbench_mt"
# Arguments after "--" are forwarded by the common driver to the benchmark.
ARGS="-- -t 1 -g 170000 -p 4000000"

READY_FILE="/tmp/enablement/xsbench_watch"

pre_run() {
    killall bench_xsbench_mt 2>/dev/null || true
}
