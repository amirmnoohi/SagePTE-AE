#!/usr/bin/env bash
# SagePTE artifact
# Run the nested-page-walk simulation with the ARM configuration used in the
# paper: Ampere Altra Max (96x Arm Neoverse N1).
#
#   L1I/L1D TLB: 48-entry fully associative
#   L2 (S)TLB:   1280-entry 5-way
#   L1I/L1D:     64 KiB 4-way
#   L2:          1 MiB 8-way
#   SLC:         16 MiB 16-way (shared)
#
# Everything other than that geometry — resolving the trace and the page-table
# dumps, running the simulation, reporting progress, parsing the result — lives
# in _simulate.sh, which this sources. Run with --help for the full usage.
#
# Usage: ./run_arm.sh <TRACE> [GUEST_PT] [HOST_PT] [options]
#
# Outputs (Data/ holds only simulator inputs; results go to Results/):
#   Results/<name>/sim_arm.log       full simulator log
#   Results/<name>/analysis_arm.txt  parsed final stats (NPW/SagePTE/DMT speedups)
# where <name> is the input directory name (e.g. "redis").
# Override the output directory with -o DIR, or OUT_DIR=/path ./run_arm.sh ...

set -euo pipefail

CONFIG_NAME="arm"
CONFIG_LABEL="Ampere Altra Max — 96x Arm Neoverse N1"

SIM_OPTS=(
  -warmup_refs     300000000
  -TLB_L1I_entries 48
  -TLB_L1I_assoc   48
  -TLB_L1D_entries 48
  -TLB_L1D_assoc   48
  -TLB_L2_entries  1280
  -TLB_L2_assoc    5
  -L1I_size        $(( 64 * 1024 ))
  -L1I_assoc       4
  -L1D_size        $(( 64 * 1024 ))
  -L1D_assoc       4
  -L2_size         $(( 1 * 1024 * 1024 ))
  -L2_assoc        8
  -LL_size         $(( 16 * 1024 * 1024 ))
  -LL_assoc        16
  -cores           96
)

_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &> /dev/null && pwd)"
# shellcheck source=_simulate.sh
source "${_SELF_DIR}/_simulate.sh" "$@"
