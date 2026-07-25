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

# Redis prints "Key <n> M / <total> M" to the tracer log as it inserts, which is
# the only visible sign of progress during the hour and three quarters it spends
# building its working set. Reporting it turns the readiness wait into a
# percentage and an ETA instead of a bare elapsed counter that looks like a hang.
ready_progress() {
  local line done total
  line="$(grep -o 'Key [0-9]\+ M / [0-9]\+ M' "${TRACER_LOG}" 2>/dev/null | tail -1)"
  [[ -n "${line}" ]] || return 0
  read -r _ done _ _ total _ <<< "${line}"
  printf '%s %s M keys' "${done}" "${total}"
}
