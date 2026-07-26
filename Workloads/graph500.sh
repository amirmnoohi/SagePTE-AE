#!/usr/bin/env bash
#
# Workload definition: graph500 — BFS over a large Kronecker graph (seq-csr).
# Paper configuration: scale 27, edge factor 32 (~123 GB).
#
# The CSR adjacency lists give the inner loop batched-sequential access, which
# keeps leaf PTEs warm in cache; this is the workload where the h-final phase
# contributes the least (20.5%) and SagePTE's speedup is smallest.

DESCRIPTION="Graph500 BFS, scale 27 (~123 GB)"

BINARY="bench_graph500_st"
# Arguments after "--" are forwarded by the common driver to the benchmark.
ARGS="-- -s 27 -e 32 -V"

READY_FILE="/tmp/enablement/graph500_watch"

pre_run() {
    killall bench_graph500_st 2>/dev/null || true
}

# graph500 spends hours building its graph before the BFS that gets traced, and
# it does so as a sequence of passes, each counting to the same total. Reporting
# which pass is running, and where it has got to, turns an opaque wait into one
# with a visible end. The pass order is the order the binary runs them in.
GRAPH500_PASSES=(Generating find_nv setup_deg_off gather_edges pack_edges
                 setup_deg_off2 setup_deg_off3 setup_deg_off4)

ready_progress() {
  local line pass done total index=0 i
  # Matches both "Generating edge N / T" and "<pass> N / T". The anchor and the
  # complete-line pattern skip the half-written record at the end of the log,
  # which is block-buffered and so is usually truncated mid-number.
  line="$(grep -oE '^[A-Za-z_]+( edge)? [0-9]+ / [0-9]+' "${TRACER_LOG}" 2> /dev/null | tail -1)"
  [[ -n "${line}" ]] || return 0
  pass="${line%% *}"
  done="$(awk '{print $(NF-2)}' <<< "${line}")"
  total="$(awk '{print $NF}' <<< "${line}")"
  [[ -n "${done}" && -n "${total}" ]] || return 0
  for i in "${!GRAPH500_PASSES[@]}"; do
    [[ "${GRAPH500_PASSES[${i}]}" == "${pass}" ]] && index=$(( i + 1 ))
  done
  printf '%s %s M (%s %s/%s)' "$(( done / 1000000 ))" "$(( total / 1000000 ))" \
    "${pass}" "${index}" "${#GRAPH500_PASSES[@]}"
}
