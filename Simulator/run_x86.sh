#!/usr/bin/env bash
# SagePTE artifact
# Run the nested-page-walk simulation with an x86 server configuration
# (Intel Xeon-class: 20 cores, 32 KiB L1, 1 MiB L2, 22 MiB shared LLC).
#
# Everything other than that geometry — resolving the trace and the page-table
# dumps, running the simulation, reporting progress, parsing the result — lives
# in _simulate.sh, which this sources. Run with --help for the full usage.
#
# Usage: ./run_x86.sh <TRACE> [GUEST_PT] [HOST_PT] [options]
#
# Outputs (Data/ holds only simulator inputs; results go to Results/):
#   Results/<name>/sim_x86.log       full simulator log
#   Results/<name>/analysis_x86.txt  parsed final stats (NPW/SagePTE/DMT speedups)
# where <name> is the input directory name (e.g. "redis").
# Override the output directory with -o DIR, or OUT_DIR=/path ./run_x86.sh ...

set -euo pipefail

CONFIG_NAME="x86"
CONFIG_LABEL="Intel Xeon-class — 20 cores, 32 KiB L1, 1 MiB L2, 22 MiB LLC"

SIM_OPTS=(
  -warmup_refs     300000000
  -TLB_L1I_entries 128
  -TLB_L1I_assoc   8
  -TLB_L1D_entries 64
  -TLB_L1D_assoc   4
  -TLB_L2_entries  1536
  -TLB_L2_assoc    12
  -L1I_size        $(( 32 * 1024 ))
  -L1I_assoc       8
  -L1D_size        $(( 32 * 1024 ))
  -L1D_assoc       8
  -L2_size         $(( 1 * 1024 * 1024 ))
  -L2_assoc        16
  -LL_size         $(( 11 * 1024 * 1024 * 16 / 8 ))
  -LL_assoc        11
  -cores           20
)

_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &> /dev/null && pwd)"
# shellcheck source=_simulate.sh
source "${_SELF_DIR}/_simulate.sh" "$@"
