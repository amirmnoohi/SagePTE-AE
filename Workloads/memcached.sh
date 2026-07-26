#!/usr/bin/env bash
#
# Workload definition: memcached — distributed caching system.
# Paper configuration: ~95 GB working set (128 GB server limit).
#
# memcached differs from every other workload here: the server never reaches a
# steady state on its own, so it cannot signal readiness itself.  An external
# load generator (YCSB) populates the cache and writes the readiness file when
# the load phase is done.  That generator is launched from post_start(), i.e.
# after the server starts but before recording begins.
#
# The generator is memcached-client.sh, which drives the YCSB client bundled in
# Workloads/ycsb with the same profile the DMT artifact used: 100 million 1 KB
# records, read-only, uniformly distributed.  Point MEMCACHED_CLIENT at your own
# executable to replace it; anything that fills the cache and then writes a
# timestamp to READY_FILE will do.
#
#     MEMCACHED_CLIENT=/path/to/client.sh Tracer/run.sh memcached
#
# Unlike the other workloads this one runs the distribution's memcached rather
# than a binary built here, so build.sh installs it along with a JRE and the
# Python 2 the YCSB launcher is written for.

DESCRIPTION="Memcached with an external YCSB load generator (~95 GB)"

# Defaults to the bundled YCSB driver; override to use your own generator.
MEMCACHED_CLIENT="${MEMCACHED_CLIENT:-${WORKLOAD_DIR}/memcached-client.sh}"

BINARY="/usr/bin/memcached"
ARGS="-u root -m 131000 -p 11211 -l 127.0.0.1"

READY_FILE="/tmp/enablement/memcached_watch"

# Both the server and the load generator must exist before we start.
REQUIRES="/usr/bin/memcached${MEMCACHED_CLIENT:+ $MEMCACHED_CLIENT}"

pre_run() {
    service memcached stop 2>/dev/null || true
    killall memcached      2>/dev/null || true
}

post_start() {
    if [ -z "$MEMCACHED_CLIENT" ]; then
        echo "[memcached] ERROR: MEMCACHED_CLIENT is not set." >&2
        echo "[memcached] Nothing will populate the cache, so the readiness" >&2
        echo "[memcached] signal ($READY_FILE) would never arrive." >&2
        exit 1
    fi
    echo "[memcached] starting load generator: $MEMCACHED_CLIENT"
    "$MEMCACHED_CLIENT" &
}

post_run() {
    killall memcached 2>/dev/null || true
}
