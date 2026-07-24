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
# Usage: ./run_arm.sh <TRACE> [GUEST_PT] [HOST_PT]
#
#   TRACE     the drmemtrace.*.dir offline trace directory produced by the
#             tracer, or a directory containing one
#   GUEST_PT  guest page table dump  (default: pt_dump.guest next to the trace)
#   HOST_PT   host page table dump   (default: pt_dump.host next to the trace)
#
# Examples:
#   ./run_arm.sh example
#   ./run_arm.sh ../Data/redis ../Data/redis/pt_dump ../Data/redis/pt_dump_redis_aug
#
# Outputs (Data/ holds only simulator inputs; results go to Results/):
#   Results/<name>/sim_arm.log       full simulator log (also streams to terminal)
#   Results/<name>/analysis_arm.txt  parsed final stats (NPW/SagePTE/DMT speedups)
# where <name> is the input directory name (e.g. "redis").
# Override the output directory with OUT_DIR=/path ./run_arm.sh ...

set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath -e "${BASH_SOURCE[0]:-$0}")")

usage() {
    echo "Usage: $0 <TRACE> [GUEST_PT] [HOST_PT]" >&2
    echo "  TRACE     drmemtrace.*.dir trace directory, or a directory containing one" >&2
    echo "  GUEST_PT  guest page table dump  (default: <TRACE>/pt_dump.guest)" >&2
    echo "  HOST_PT   host page table dump   (default: <TRACE>/pt_dump.host)" >&2
    exit 1
}

DRRUN="$SCRIPT_DIR/build/bin64/drrun"
if [ ! -x "$DRRUN" ]; then
    echo "Error: $DRRUN not found. Build the simulator first: ./install.sh" >&2
    exit 1
fi

TRACE_ARG="${1:-${TRACE_DIR:-}}"
[ -n "$TRACE_ARG" ] || usage
TRACE_ARG=$(realpath -e "$TRACE_ARG") || usage

# Accept either the drmemtrace.*.dir itself or a directory containing one.
if [[ "$(basename "$TRACE_ARG")" == drmemtrace* ]]; then
    TRACE="$TRACE_ARG"
    TRACE_DIR=$(dirname "$TRACE_ARG")
else
    TRACE_DIR="$TRACE_ARG"
    TRACE=$(find "$TRACE_DIR" -maxdepth 1 -name "drmemtrace*" -type d | sort | head -n 1)
    if [ -z "$TRACE" ]; then
        echo "Error: no drmemtrace* directory found in $TRACE_DIR" >&2
        exit 1
    fi
fi

# Guest dump: prefer the current name (pt_dump.guest), fall back to the older
# flat name (pt_dump) so directories captured before the rename still work.
if [ -n "${2:-}" ]; then
    GUEST_PT="$2"
elif [ -f "$TRACE_DIR/pt_dump.guest" ]; then
    GUEST_PT="$TRACE_DIR/pt_dump.guest"
else
    GUEST_PT="$TRACE_DIR/pt_dump"
fi
# Host dump: prefer the current name, then the legacy "*_aug" produced by the
# augmentor before the rename, so shipped datasets remain simulatable.
if [ -n "${3:-}" ]; then
    HOST_PT="$3"
elif [ -f "$TRACE_DIR/pt_dump.host" ]; then
    HOST_PT="$TRACE_DIR/pt_dump.host"
else
    HOST_PT=$(find "$TRACE_DIR" -maxdepth 1 -name 'pt_dump*_aug' 2>/dev/null | sort | head -1)
    HOST_PT="${HOST_PT:-$TRACE_DIR/pt_dump.host}"
fi

for f in "$GUEST_PT" "$HOST_PT"; do
    if [ ! -f "$f" ]; then
        echo "Error: page table dump not found: $f" >&2
        echo "Pass the dumps explicitly: $0 <TRACE> <GUEST_PT> <HOST_PT>" >&2
        exit 1
    fi
done

# Results go to Results/<input-dir-name>/ at the repo root, next to Data/.
NAME=$(basename "$TRACE_DIR")
OUT_DIR="${OUT_DIR:-$(dirname "$SCRIPT_DIR")/Results/$NAME}"
mkdir -p "$OUT_DIR"
OUTPUT_FILE="$OUT_DIR/sim_arm.log"
ANALYSIS_FILE="$OUT_DIR/analysis_arm.txt"

echo "Trace    : $TRACE"
echo "Guest PT : $GUEST_PT"
echo "Host PT  : $HOST_PT"
echo "Log      : $OUTPUT_FILE"

"$DRRUN" -t drcachesim \
                    -indir "$TRACE" \
                    -pt_dump_file "$GUEST_PT" \
                    -vt_pt_dump_file "$HOST_PT" \
                    -warmup_refs     300000000                   \
                    -TLB_L1I_entries 48                          \
                    -TLB_L1I_assoc   48                          \
                    -TLB_L1D_entries 48                          \
                    -TLB_L1D_assoc   48                          \
                    -TLB_L2_entries  1280                        \
                    -TLB_L2_assoc    5                           \
                    -L1I_size  $(( 64 * 1024 ))                  \
                    -L1I_assoc 4                                 \
                    -L1D_size  $(( 64 * 1024 ))                  \
                    -L1D_assoc 4                                 \
                    -L2_size   $(( 1 * 1024 * 1024 ))            \
                    -L2_assoc  8                                 \
                    -LL_size   $(( 16 * 1024 * 1024 ))           \
                    -LL_assoc  16                                \
                    -cores 96                                    \
                    2>&1 | tee "$OUTPUT_FILE"

sync

# Parse the final stats dump into the analysis file.
if "$SCRIPT_DIR/scripts/analyze_log.sh" "$OUTPUT_FILE" > "$ANALYSIS_FILE"; then
    echo
    cat "$ANALYSIS_FILE"
else
    echo "WARNING: analysis failed (no Page Walk Statistics in log?)" >&2
fi

echo "--- SIM DONE $TRACE ---"
echo "    log      : $OUTPUT_FILE"
echo "    analysis : $ANALYSIS_FILE"
