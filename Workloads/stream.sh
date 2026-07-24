#!/usr/bin/env bash
#
# Workload definition: stream — the classic memory-bandwidth kernel.
#
# STREAM has no readiness signal (it starts streaming immediately and its
# initialisation is trivial), so tracing begins after a short fixed delay
# instead.  Useful as a bandwidth-bound reference point rather than as one of
# the paper's seven translation-bound workloads.

DESCRIPTION="STREAM memory-bandwidth kernel (no readiness signal)"

BINARY="bench_stream"
ARGS=""

# No READY_FILE: this workload does not signal readiness.
READY_FILE=""
READY_DELAY=5

pre_run() {
    killall bench_stream 2>/dev/null || true
}
