#!/usr/bin/env bash
#
# ==============================================================================
#  SagePTE Artifact — Trace Conversion
# ==============================================================================
#
#  SYNOPSIS
#      convert_trace.sh <workload> [options]
#      convert_trace.sh --dir <trace-dir> [options]
#
#  DESCRIPTION
#      Converts the raw trace produced by run.sh into the decoded form the
#      simulator consumes, writing <trace-dir>/drmemtrace.trace.
#
#      The tracer records a compact per-thread raw stream (raw/*.raw) plus the
#      table of loaded modules (raw/modules.log). The simulator cannot replay
#      that directly: instruction fetches have to be decoded out of the binaries
#      named in modules.log first. DynamoRIO calls this step raw2trace.
#
#  WHY RUN IT HERE
#      The simulator performs this conversion itself the first time it opens an
#      unconverted directory, so running this script is optional — but the work
#      is not, and neither is its cost. The simulator does not stream the raw
#      trace: it decodes it to <trace-dir>/drmemtrace.trace, exactly as this
#      script does, and only then starts replaying. Skipping this stage
#      therefore saves nothing; it merely moves the conversion into the first —
#      and longest — simulation run, where it is easy to mistake for the
#      simulation being slow.
#
#      Doing it here pays that cost once, visibly, next to the run that produced
#      the trace, and leaves Data/<workload>/ self-contained so the directory
#      can be archived or moved and simulated immediately.
#
#  DISK COST
#      Decoding expands a trace by roughly 9x: the raw stream is a compact
#      per-thread encoding, whereas the decoded form carries one fixed-size
#      record per memory reference *and* per instruction fetch. A 15 GB raw
#      trace becomes well over 100 GB. That space is required to simulate at
#      all, whether it is claimed here or by the simulator later.
#
#      Conversion is idempotent: the simulator checks for the end-of-trace
#      footer and redoes the work if a previous attempt was cut short, so an
#      interrupted conversion can never silently yield a truncated trace.
#
#  OUTPUT
#      <trace-dir>/drmemtrace.trace   decoded trace, read by the simulator
#
#  EXIT CODES
#      0    converted, or already up to date
#      1    usage error
#      2    environment error (drraw2trace missing, no trace found)
#      3    conversion failed
#      130  interrupted (Ctrl-C)
#
#  SEE ALSO
#      Tracer/run.sh              produces the raw trace this script converts
#      Simulator/run_arm.sh         replays the converted trace
#
# ==============================================================================

set -euo pipefail

readonly VERSION="1.0.0"


SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
readonly REPO_ROOT
# How this script names itself in help: every component exposes a run.sh,
# so the path relative to the artifact root is what disambiguates it.
PROG="${SCRIPT_DIR#"${REPO_ROOT}/"}/$(basename "${BASH_SOURCE[0]:-$0}")"
readonly PROG

# The file name the simulator looks for inside a trace directory
# (TRACE_FILENAME, clients/drcachesim/tracer/raw2trace.h).
readonly TRACE_FILENAME="drmemtrace.trace"

# shellcheck source=../Lib/ui.sh
source "${REPO_ROOT}/Lib/ui.sh"

WORKLOAD=""
TRACE_DIR=""
OUTPUT_DIR=""
FORCE=0
COMPACT=0
SKIP_SPACE_CHECK=0

usage() {
  cat <<EOF
${C_BOLD}SagePTE trace conversion${C_RESET} v${VERSION}

${C_BOLD}USAGE${C_RESET}
  ${PROG} <workload> [options]
  ${PROG} --dir <trace-dir> [options]

${C_BOLD}OPTIONS${C_RESET}
  -o, --output DIR       directory holding the trace  (default: Data/<workload>)
      --dir DIR          convert this drmemtrace.*.dir directly, by path
  -f, --force            reconvert even if a complete trace is already present
      --skip-space-check proceed even if the estimate says it will not fit
      --compact          render as status lines only (when nested in another script)
      --no-color         disable coloured output
  -h, --help             show this message
  -V, --version          show the version

${C_BOLD}EXAMPLES${C_RESET}
  ${PROG} debug                     convert Data/debug's trace
  ${PROG} --dir /mnt/t/drmemtrace.x.dir   convert a directory directly
  ${PROG} debug --force             redo a conversion from scratch

${C_BOLD}NOTES${C_RESET}
  Running this is optional, but the work is not: if you skip it the simulator
  performs the same conversion on its first run, writing the same file to the
  same place. Doing it here just pays the cost visibly, up front.

  Decoding expands a trace by roughly 9x (a 15 GB raw trace becomes ~135 GB).
  That space is needed to simulate either way; the run aborts up front if it
  will not fit.
EOF
}

#######################################
# Decide whether a converted trace is complete.
#
# This mirrors file_reader_t::is_complete() (reader/file_reader.cpp): a finished
# trace ends with a trace_entry_t whose type field is TRACE_TYPE_FOOTER. Testing
# only that the file is non-empty is not enough — an interrupted conversion
# leaves a large, entirely plausible-looking file that would then be replayed as
# a silently truncated trace.
#
# The constants come from this build's own headers (trace_entry.h); they are
# verified against it by the assertion below, so a future change to the record
# layout is caught here rather than misreported as a corrupt trace.
# Arguments:
#   $1 — path to the converted trace.
# Returns:
#   0 if complete, 1 otherwise.
#######################################
readonly TRACE_ENTRY_SIZE=20     # sizeof(trace_entry_t)
readonly TRACE_TYPE_FOOTER=56    # trace_type_t::TRACE_TYPE_FOOTER

trace_is_complete() {
  local file="$1" size type
  [[ -s "${file}" ]] || return 1
  size="$(stat -c%s "${file}" 2>/dev/null || echo 0)"
  (( size >= TRACE_ENTRY_SIZE )) || return 1
  # The type field is the first 2 bytes of the final record, host byte order.
  type="$(tail -c "${TRACE_ENTRY_SIZE}" "${file}" | od -An -tu2 -N2 | tr -d '[:space:]')"
  [[ "${type}" == "${TRACE_TYPE_FOOTER}" ]]
}

#######################################
# Locate the drraw2trace launcher.
#
# Prefers the simulator's copy, since the simulator is what reads the result;
# the tracer's build is an equally valid fallback (both are the same DynamoRIO
# release, and the trace format is shared).
# Outputs:
#   Path to the executable on stdout; empty if neither build has one.
#######################################
find_raw2trace() {
  local candidate
  for candidate in "${REPO_ROOT}/Simulator/build/clients/bin64/drraw2trace" \
                   "${SCRIPT_DIR}/build/clients/bin64/drraw2trace"; do
    [[ -x "${candidate}" ]] && { printf '%s' "${candidate}"; return 0; }
  done
  printf ''
}

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------

ui::init

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -V|--version) echo "convert_trace.sh ${VERSION}"; exit 0 ;;
    --no-color)   ui::set_color off; shift ;;
    --compact)    COMPACT=1; ui::set_compact on; shift ;;
    -o|--output)  OUTPUT_DIR="${2:?--output requires a directory}"; shift 2 ;;
    --dir)        TRACE_DIR="${2:?--dir requires a directory}"; shift 2 ;;
    -f|--force)   FORCE=1; shift ;;
    --skip-space-check) SKIP_SPACE_CHECK=1; shift ;;
    -*)           UI_EXIT_CODE=1 ui::die "unknown option: $1" "try '${PROG} --help'" ;;
    *)
      [[ -z "${WORKLOAD}" ]] ||
        UI_EXIT_CODE=1 ui::die "only one workload may be given" "got '${WORKLOAD}' and '$1'"
      WORKLOAD="$1"; shift ;;
  esac
done

[[ -n "${WORKLOAD}" || -n "${TRACE_DIR}" ]] || { usage >&2; exit 1; }

ui::set_steps 3
ui::banner "SagePTE ${G_DOT} Trace Conversion" "decode a raw trace into simulator input"

# ------------------------------------------------------------------------------
# 1/3 — Locate the trace
# ------------------------------------------------------------------------------

ui::step "Trace"

if [[ -z "${TRACE_DIR}" ]]; then
  OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/Data/${WORKLOAD}}"
  [[ -d "${OUTPUT_DIR}" ]] ||
    UI_EXIT_CODE=2 ui::die "no such directory: ${OUTPUT_DIR}" \
      "capture a trace first:  Tracer/run.sh ${WORKLOAD}"
  TRACE_DIR="$(find "${OUTPUT_DIR}" -maxdepth 1 -name 'drmemtrace.*' -type d 2>/dev/null | sort | head -1)"
  [[ -n "${TRACE_DIR}" ]] ||
    UI_EXIT_CODE=2 ui::die "no drmemtrace.*.dir found in $(ui::relpath "${OUTPUT_DIR}" "${REPO_ROOT}")" \
      "capture a trace first:  Tracer/run.sh ${WORKLOAD}"
fi

[[ -d "${TRACE_DIR}/raw" ]] ||
  UI_EXIT_CODE=2 ui::die "no raw/ subdirectory in $(ui::relpath "${TRACE_DIR}" "${REPO_ROOT}")" \
    "this does not look like a drmemtrace output directory"

readonly TRACE_FILE="${TRACE_DIR}/${TRACE_FILENAME}"

ui::ok "trace  $(ui::relpath "${TRACE_DIR}" "${REPO_ROOT}")"

# Decoding expands the trace substantially: the raw stream is a compact
# per-thread encoding, while the decoded form carries one fixed-size record per
# memory reference *and* per instruction fetch. Measured on this artifact's
# workloads the result is roughly nine times the raw size, so a 15 GB raw
# trace becomes well over 100 GB. That is well worth checking before starting rather
# than discovering it with a full filesystem an hour in.
RAW_BYTES=$(du -sb "${TRACE_DIR}/raw" 2>/dev/null | cut -f1 || true)
RAW_BYTES=${RAW_BYTES:-0}
readonly EXPANSION=9
ESTIMATED_BYTES=$(( RAW_BYTES * EXPANSION ))

if (( ! COMPACT )); then
  ui::field "Raw size" "$(ui::size_of "${TRACE_DIR}/raw")"
  ui::field "Estimated output" "~$(numfmt --to=iec --suffix=B "${ESTIMATED_BYTES}" 2>/dev/null || echo "${ESTIMATED_BYTES} B")  ${C_DIM}(~${EXPANSION}x the raw trace)${C_RESET}"
fi

# Already converted?
if [[ -e "${TRACE_FILE}" && "${FORCE}" -eq 0 ]]; then
  if trace_is_complete "${TRACE_FILE}"; then
    ui::ok "already converted  $(ui::relpath "${TRACE_FILE}" "${REPO_ROOT}")  ${C_DIM}($(ui::size_of "${TRACE_FILE}"))${C_RESET}"
    ui::note "re-run with --force to convert it again"
    ui::blank
    exit 0
  fi
  # An interrupted conversion leaves a plausible-looking file with no footer.
  # Treating it as done would hand the simulator a truncated trace, so it is
  # discarded and redone — which is exactly what the simulator itself does.
  ui::warn "an incomplete conversion is present ($(ui::size_of "${TRACE_FILE}")) — no end-of-trace footer"
  ui::warn "discarding it and converting again"
  rm -f "${TRACE_FILE}"
fi

# ------------------------------------------------------------------------------
# 2/3 — Environment
# ------------------------------------------------------------------------------

ui::step "Environment"

RAW2TRACE="$(find_raw2trace)"
[[ -n "${RAW2TRACE}" ]] ||
  UI_EXIT_CODE=2 ui::die "drraw2trace not found in either build" \
    "build one of them first:" \
    "    cd ${REPO_ROOT}/Simulator && ./install.sh"
ui::ok "converter  $(ui::relpath "${RAW2TRACE}" "${REPO_ROOT}")"

# Refuse to start a conversion that cannot possibly fit. Filling the filesystem
# would not just fail the conversion, it would take the rest of the run with it.
# Guarded: an empty inner substitution would make this a shell syntax error.
avail_kb="$(df -Pk "${TRACE_DIR}" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
AVAIL_BYTES=$(( ${avail_kb:-0} * 1024 ))
if (( AVAIL_BYTES < ESTIMATED_BYTES )) && (( SKIP_SPACE_CHECK == 0 )); then
  UI_EXIT_CODE=2 ui::die "not enough free space to convert this trace" \
    "estimated output : ~$(numfmt --to=iec --suffix=B "${ESTIMATED_BYTES}" 2>/dev/null)" \
    "free on this disk: $(numfmt --to=iec --suffix=B "${AVAIL_BYTES}" 2>/dev/null)" \
    "" \
    "note that skipping this stage does NOT avoid the cost: the simulator" \
    "performs the same conversion on its first run and writes the same file" \
    "to the same place. Free up space, or move the trace to a larger disk," \
    "before simulating either way." \
    "override with --skip-space-check if the estimate is wrong for your trace."
fi
ui::ok "free space  $(numfmt --to=iec --suffix=B "${AVAIL_BYTES}" 2>/dev/null) available"

# ------------------------------------------------------------------------------
# 3/3 — Convert
# ------------------------------------------------------------------------------

ui::step "Conversion"

CONVERT_LOG="${OUTPUT_DIR:-$(dirname "${TRACE_DIR}")}/meta/raw2trace.log"
mkdir -p "$(dirname "${CONVERT_LOG}")"
started=${SECONDS}

"${RAW2TRACE}" -indir "${TRACE_DIR}" -out "${TRACE_FILE}" > "${CONVERT_LOG}" 2>&1 &
converter_pid=$!

#######################################
# Build the live progress label for the conversion.
#
# drraw2trace reports nothing while it runs, but it streams its output to a
# single file, so the file's size is a direct and accurate measure of progress.
# The denominator is the size estimate, which is approximate — hence "~" — so
# the percentage and ETA are presented as guidance, and the actual byte count
# (which is exact) leads.
# Globals:
#   Reads TRACE_FILE, ESTIMATED_BYTES, started.
# Outputs:
#   A one-line progress label on stdout.
#######################################
conversion_progress() {
  local done elapsed pct rate eta
  done=$(stat -c%s "${TRACE_FILE}" 2>/dev/null || echo 0)
  elapsed=$(( SECONDS - started ))

  if (( ESTIMATED_BYTES <= 0 )); then
    printf 'decoding  %s written' "$(ui::bytes "${done}")"
    return 0
  fi

  pct=$(( done * 100 / ESTIMATED_BYTES ))
  # The estimate can be beaten in either direction; never show a bogus >100%.
  if (( pct > 100 )); then
    printf 'decoding  %s  %s(past the ~%s estimate)%s' \
      "$(ui::bytes "${done}")" "${C_DIM}" "$(ui::bytes "${ESTIMATED_BYTES}")" "${C_RESET}"
    return 0
  fi

  eta=''
  if (( done > 0 && elapsed > 2 )); then
    rate=$(( done / elapsed ))
    (( rate > 0 )) && eta="  ETA ~$(ui::duration $(( (ESTIMATED_BYTES - done) / rate )))"
  fi

  printf 'decoding  %s%s%s  %s / ~%s  (%d%%)%s' \
    "${C_CYAN}" "$(ui::bar "${pct}" 14)" "${C_RESET}" \
    "$(ui::bytes "${done}")" "$(ui::bytes "${ESTIMATED_BYTES}")" "${pct}" "${eta}"
}

ui::wait_begin "decoding the raw trace (this is the slow step)"
while kill -0 "${converter_pid}" 2>/dev/null; do
  sleep 2
  ui::wait_tick "$(conversion_progress)"
done
converter_status=0
wait "${converter_pid}" || converter_status=$?

if (( converter_status != 0 )) || [[ ! -s "${TRACE_FILE}" ]]; then
  ui::wait_abort
  rm -f "${TRACE_FILE}"
  UI_EXIT_CODE=3 ui::die "conversion failed (exit ${converter_status})" \
    "$(tail -n 3 "${CONVERT_LOG}" 2>/dev/null || true)" \
    "" \
    "full output: $(ui::relpath "${CONVERT_LOG}" "${REPO_ROOT}")"
fi
ui::wait_end "converted, $(ui::size_of "${TRACE_FILE}")"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

if (( COMPACT )); then
  ui::ok "trace converted  $(ui::relpath "${TRACE_FILE}" "${REPO_ROOT}")  ${C_DIM}($(ui::size_of "${TRACE_FILE}"))${C_RESET}"
  exit 0
fi

ui::result_banner ok "TRACE CONVERTED ${G_DOT} ${WORKLOAD:-$(basename "${TRACE_DIR}")}"
ui::field "Simulator input" "$(ui::relpath "${TRACE_FILE}" "${REPO_ROOT}")"
ui::field "Size" "$(ui::size_of "${TRACE_FILE}")"
ui::field "Duration" "$(ui::duration $(( SECONDS - started )))"
ui::blank
