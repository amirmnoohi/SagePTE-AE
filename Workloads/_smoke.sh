#!/usr/bin/env bash
DESCRIPTION="temp smoke test"
BINARY="bench_gups_st"
ARGS="1"
READY_FILE="/tmp/enablement/gups_watch"
pre_run() { killall bench_gups_st 2>/dev/null || true; }
