#!/usr/bin/env bash
#
# Workload definition: redis — in-memory key-value store.
# Paper configuration: ~155 GB working set (KEY_MAX = 1<<29 keys, 30 M lookups).
#
# The patched server preloads every key and then signals readiness, so the
# trace records the request-serving phase only.

DESCRIPTION="Redis in-memory key-value store (~155 GB working set)"

BINARY="bench_redis_st"
ARGS=""

READY_FILE="/tmp/enablement/redis_watch"

pre_run() {
    service redis stop 2>/dev/null || true
    killall redis-server   2>/dev/null || true
    killall bench_redis_st 2>/dev/null || true
    # The benchmark writes its snapshot into the directory it is started from.
    rm -f "$REPO_ROOT/dump.rdb"
}
