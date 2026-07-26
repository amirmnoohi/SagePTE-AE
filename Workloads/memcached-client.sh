#!/usr/bin/env bash
#
# ==============================================================================
#  SagePTE Artifact — memcached load generator
# ==============================================================================
#
#  DESCRIPTION
#      Drives the memcached workload with the bundled YCSB client, in the two
#      phases the evaluation needs: a load phase that fills the cache, and a run
#      phase that is what the tracer records.
#
#      Between the two it writes the readiness file. memcached itself is the
#      distribution's binary and has no enablement patch, unlike every other
#      workload here, so the signal has to come from the client -- which is also
#      the only thing that knows when the cache is full. This mirrors
#      dmt/eval/driver/memcached-client.sh from the DMT artifact.
#
#  PROFILE
#      workloads/perfeval: 100 million 1 KB records (~95 GB), read-only,
#      uniformly distributed.
#
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &> /dev/null && pwd)"
readonly YCSB_DIR="${SCRIPT_DIR}/ycsb"
readonly PROFILE="${MEMCACHED_PROFILE:-workloads/perfeval}"
readonly HOSTS="${MEMCACHED_HOSTS:-127.0.0.1}"
readonly READY_FILE="/tmp/enablement/memcached_watch"

cd "${YCSB_DIR}"

echo "[memcached-client] loading ${PROFILE} into ${HOSTS}"
./bin/ycsb load memcached -s -P "${PROFILE}" -p "memcached.hosts=${HOSTS}" 2>&1

# The server acknowledges the last write before it has finished settling; the
# DMT driver waits here too.
sleep 5

echo "[memcached-client] cache loaded, signalling readiness"
mkdir -p "$(dirname "${READY_FILE}")"
date > "${READY_FILE}"

echo "[memcached-client] starting the measured phase"
./bin/ycsb run memcached -s -P "${PROFILE}" -p "memcached.hosts=${HOSTS}" 2>&1
