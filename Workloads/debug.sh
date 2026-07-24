#!/usr/bin/env bash
#
# Workload definition: debug — small GUPS run for smoke-testing the pipeline.
# Same benchmark as gups.sh but with a 16 GB table, so a full
# trace + page-table dump completes in minutes instead of hours.

DESCRIPTION="Small 16 GB GUPS run (pipeline smoke test)"

BINARY="bench_gups_st"
ARGS="16"

READY_FILE="/tmp/enablement/gups_watch"

pre_run() {
    killall bench_gups_st 2>/dev/null || true
}
