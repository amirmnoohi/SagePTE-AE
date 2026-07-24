#!/usr/bin/env bash
#
# Workload definition: gups — Giga-updates-per-second random access.
# Paper configuration: 128 GB table, 2^30 updates.  Purely random access, so
# this is the worst case for TLB reach and the best case for SagePTE.
#
# The table is fully touched during initialisation; readiness is signalled
# afterwards so the trace covers the update phase only.

DESCRIPTION="GUPS random-access benchmark (128 GB table)"

BINARY="bench_gups_st"
ARGS="128"

READY_FILE="/tmp/enablement/gups_watch"

pre_run() {
    killall bench_gups_st 2>/dev/null || true
}
