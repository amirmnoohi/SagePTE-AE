#!/usr/bin/env bash
#
# ==============================================================================
#  SagePTE Artifact — Nested-Page-Walk Simulator (shared driver)
# ==============================================================================
#
#  NOT RUN DIRECTLY. run_x86.sh and run_arm.sh each declare one machine
#  configuration and then source this file, which does everything else:
#  resolving inputs, running the simulation, reporting progress and parsing the
#  result. The two front-ends differ only in cache and TLB geometry, so that is
#  all they contain — the same split the tracer uses between run.sh and
#  Workloads/<name>.sh.
#
#  CONTRACT
#      A front-end sets three variables and then sources this file with "$@":
#
#          CONFIG_NAME   short tag used in filenames        e.g. arm
#          CONFIG_LABEL  one line describing the machine    e.g. "Ampere ..."
#          SIM_OPTS      array of -TLB_*/-L*_*/-cores flags
#
#  WHY THE LOG IS NOT ON THE TERMINAL
#      The simulator emits a line per page walk: the debug trace alone produces
#      a 4 MB, 56,000-line log. Streaming that hides the one thing worth
#      watching — how far along the run is — and a run over a full trace lasts
#      hours. The log therefore goes to a file, and the terminal shows a single
#      progress line. Pass --follow to stream it anyway, or tail the file from
#      another shell; the path is printed before the run starts.
#
#  HOW PROGRESS IS KNOWN
#      The simulator prints no progress of its own, so it is measured from
#      outside: the analyzer holds the decoded trace open, and the kernel
#      reports how far into it that descriptor has read
#      (/proc/<pid>/fdinfo/<fd>). Position over file size is a true percentage,
#      and its rate of change gives the estimate. When the trace has not been
#      decoded yet the simulator does that first, and the same line follows the
#      decoded file growing towards its expected size instead.
#
#  OUTPUT
#      Results/<name>/sim_<config>.log       full simulator log
#      Results/<name>/analysis_<config>.txt  parsed final statistics
#
#  EXIT CODES
#      0    the simulation finished and was analysed
#      1    usage error
#      2    environment error (simulator not built, input missing)
#      3    the simulation itself failed
#      130  interrupted (Ctrl-C)
#
# ==============================================================================

set -euo pipefail

readonly VERSION="1.0.0"

# ------------------------------------------------------------------------------
# Paths. Derived from this driver's own location, not the caller's, so the
# front-ends work from any working directory.
# ------------------------------------------------------------------------------
SIM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SIM_DIR
REPO_ROOT="$(cd -- "${SIM_DIR}/.." &> /dev/null && pwd)"
readonly REPO_ROOT
# Name the front-end that sourced us, not this file: that is what the user ran.
PROG="$(basename "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")"
readonly PROG
readonly DRRUN="${SIM_DIR}/build/bin64/drrun"
readonly ANALYZER="${SIM_DIR}/scripts/analyze_log.sh"
# Set by the tracer's raw2trace; see clients/drcachesim/tracer/raw2trace.h.
readonly TRACE_FILENAME="drmemtrace.trace"
# Observed expansion from raw capture to decoded trace, used only to size the
# progress bar while decoding. 7.1x measured on the debug capture.
readonly DECODE_EXPANSION=7
# Below this multiple of the raw capture a decoded trace is treated as the
# truncated remains of an interrupted run. Set well under DECODE_EXPANSION so
# that a workload which happens to expand less than usual is not rejected.
readonly MIN_DECODE_EXPANSION=3

# shellcheck source=../Lib/ui.sh
source "${REPO_ROOT}/Lib/ui.sh"

# ------------------------------------------------------------------------------
# Options
# ------------------------------------------------------------------------------
TRACE_ARG=""          # the trace directory, positional
GUEST_PT_ARG=""       # optional override, positional
HOST_PT_ARG=""        # optional override, positional
FOLLOW=0              # 1 = stream the simulator log instead of a progress line
ASSUME_DECODED=0      # 1 = trust a decoded trace that looks too small
OUT_DIR_OPT=""        # -o/--output

# Populated as the run progresses; referenced by the trap handler.
SIM_PID=""
TAIL_PID=""
RUN_START=0
# Which half of the run is in progress. The simulator decodes the raw capture
# before it replays any of it, and those two phases fail for entirely different
# reasons -- reporting a decode that ran out of disk as "the simulation failed"
# sends the reader looking in the wrong place.
SIM_PHASE="starting"

#######################################
# Print the help text.
# Outputs:
#   Usage information on stdout.
#######################################
usage() {
  cat << EOF
${C_BOLD}SagePTE nested-page-walk simulator${C_RESET} ${C_DIM}(${CONFIG_NAME})${C_RESET} v${VERSION}
  ${CONFIG_LABEL}

${C_BOLD}USAGE${C_RESET}
  ./${PROG} <TRACE> [GUEST_PT] [HOST_PT] [options]

${C_BOLD}ARGUMENTS${C_RESET}
  TRACE          a drmemtrace.*.dir, or a directory containing one
  GUEST_PT       guest page table dump   (default: <TRACE>/pt_dump.guest)
  HOST_PT        host page table dump    (default: <TRACE>/pt_dump.host)

${C_BOLD}OPTIONS${C_RESET}
  -o, --output DIR   where results go       (default: Results/<trace name>)
  -f, --follow       stream the simulator log instead of a progress line
      --assume-decoded  replay a decoded trace even if it looks truncated
      --no-color     disable coloured output
  -h, --help         show this message
  -V, --version      show the version

${C_BOLD}EXAMPLES${C_RESET}
  ./${PROG} example                     the bundled smoke test
  ./${PROG} ../Data/debug               a capture made by Tracer/run.sh
  ./${PROG} ../Data/redis --follow      watch the log go by

${C_BOLD}NOTES${C_RESET}
  The log is written to a file rather than the terminal — it holds one line per
  page walk. Follow it from another shell with:
      tail -f Results/<name>/sim_${CONFIG_NAME}.log
EOF
}

# ==============================================================================
#  Input resolution
# ==============================================================================

#######################################
# Resolve the trace directory, accepting either a drmemtrace.*.dir or a
# directory holding one.
# Globals:
#   Reads TRACE_ARG; sets TRACE and TRACE_DIR.
#######################################
resolve_trace() {
  local arg
  arg="$(realpath -e "${TRACE_ARG}" 2> /dev/null)" ||
    UI_EXIT_CODE=2 ui::die "no such trace: ${TRACE_ARG}"

  if [[ "$(basename "${arg}")" == drmemtrace* && -d "${arg}" ]]; then
    TRACE="${arg}"
    TRACE_DIR="$(dirname "${arg}")"
  else
    TRACE_DIR="${arg}"
    TRACE="$(find "${arg}" -maxdepth 1 -name 'drmemtrace*' -type d | sort | head -n 1)"
    [[ -n "${TRACE}" ]] ||
      UI_EXIT_CODE=2 ui::die "no drmemtrace* directory inside $(ui::relpath "${arg}" "${REPO_ROOT}")" \
        "pass the trace directory produced by the tracer, or the directory holding it"
  fi
}

#######################################
# Resolve the two page-table dumps, preferring the current names and falling
# back to the ones used before they were renamed, so datasets captured earlier
# remain simulatable.
# Globals:
#   Reads GUEST_PT_ARG, HOST_PT_ARG, TRACE_DIR; sets GUEST_PT and HOST_PT.
#######################################
resolve_dumps() {
  if [[ -n "${GUEST_PT_ARG}" ]]; then
    GUEST_PT="${GUEST_PT_ARG}"
  elif [[ -f "${TRACE_DIR}/pt_dump.guest" ]]; then
    GUEST_PT="${TRACE_DIR}/pt_dump.guest"
  else
    GUEST_PT="${TRACE_DIR}/pt_dump"          # pre-rename flat name
  fi

  if [[ -n "${HOST_PT_ARG}" ]]; then
    HOST_PT="${HOST_PT_ARG}"
  elif [[ -f "${TRACE_DIR}/pt_dump.host" ]]; then
    HOST_PT="${TRACE_DIR}/pt_dump.host"
  else
    HOST_PT="$(find "${TRACE_DIR}" -maxdepth 1 -name 'pt_dump*_aug' 2> /dev/null | sort | head -1)"
    HOST_PT="${HOST_PT:-${TRACE_DIR}/pt_dump.host}"   # pre-rename augmentor name
  fi

  local f
  for f in "${GUEST_PT}" "${HOST_PT}"; do
    [[ -f "${f}" ]] ||
      UI_EXIT_CODE=2 ui::die "page table dump not found: $(ui::relpath "${f}" "${REPO_ROOT}")" \
        "the simulator needs both the guest (GVA->GPA) and host (GPA->HPA) dumps" \
        "" \
        "pass them explicitly:" \
        "    ./${PROG} <TRACE> <GUEST_PT> <HOST_PT>"
  done
}

# ==============================================================================
#  Progress
# ==============================================================================

#######################################
# Find the analyzer process and the descriptor it is reading the trace through.
# The simulator is launched via drrun, which execs the analyzer, so the pid is
# discovered rather than remembered: the process holding this exact trace file
# open is unambiguous even when several simulations run at once.
# Globals:
#   Reads TRACE_FILE.
# Outputs:
#   "<pid> <fd>" on stdout when found.
# Returns:
#   0 when found, 1 otherwise.
#######################################
find_reader() {
  local pid fd target
  for pid in $(pgrep -x drcachesim 2> /dev/null); do
    for fd in /proc/"${pid}"/fd/*; do
      target="$(readlink "${fd}" 2> /dev/null)" || continue
      if [[ "${target}" == "${TRACE_FILE}" ]]; then
        printf '%s %s' "${pid}" "${fd##*/}"
        return 0
      fi
    done
  done
  return 1
}

#######################################
# Render one progress line: a bar, how far through, and an estimate.
# Arguments:
#   $1 — verb ("replaying"/"decoding"); $2 — bytes done; $3 — bytes total;
#   $4 — bytes per second, 0 when not yet known.
# Outputs:
#   The label on stdout, for ui::wait_tick.
#######################################
progress_label() {
  local verb="$1" done_b="$2" total_b="$3" rate="$4"
  local pct=0 eta=""
  (( total_b > 0 )) && pct=$(( done_b * 100 / total_b ))
  if (( rate > 0 && total_b > done_b )); then
    eta="  ${C_DIM}ETA $(ui::duration $(( (total_b - done_b) / rate )))${C_RESET}"
  fi
  printf '%s %3d%%  %s  %s / %s%s' \
    "${verb}" "${pct}" "$(ui::bar "${pct}" 20)" \
    "$(ui::bytes "${done_b}")" "$(ui::bytes "${total_b}")" "${eta}"
}

#######################################
# Follow the simulation to completion, drawing a progress line.
#
# Two phases are possible. If the trace has not been decoded, the simulator
# decodes it first and the decoded file's growth is tracked against its
# expected size; once the analyzer opens it for reading, the true read position
# takes over. Either way this only ever observes — it never interferes.
# Globals:
#   Reads SIM_PID, TRACE_FILE, RAW_BYTES, DECODED_AT_START.
#######################################
watch_simulation() {
  local pid_fd pid fd pos=0 total=0 verb
  local last_pos=0 last_time=${SECONDS} rate=0 now delta

  (( DECODED_AT_START )) || SIM_PHASE="decoding"
  ui::wait_begin "starting the simulation"
  while kill -0 "${SIM_PID}" 2> /dev/null; do
    if pid_fd="$(find_reader)"; then
      # Replaying: ask the kernel how far into the trace the analyzer has read.
      read -r pid fd <<< "${pid_fd}"
      pos="$(sed -n 's/^pos:[[:space:]]*//p' "/proc/${pid}/fdinfo/${fd}" 2> /dev/null || echo 0)"
      total="$(stat -c %s "${TRACE_FILE}" 2> /dev/null || echo 0)"
      verb="replaying"; SIM_PHASE="replaying"
    elif [[ -f "${TRACE_FILE}" ]] && (( ! DECODED_AT_START )); then
      # Decoding: the decoded file is still being written.
      pos="$(stat -c %s "${TRACE_FILE}" 2> /dev/null || echo 0)"
      total=$(( RAW_BYTES * DECODE_EXPANSION ))
      verb="decoding"; SIM_PHASE="decoding"
    else
      ui::wait_tick "starting the simulation"
      sleep 1
      continue
    fi

    # Rate over the last few seconds, so the estimate settles rather than
    # swinging with every sample.
    now=${SECONDS}
    delta=$(( now - last_time ))
    if (( delta >= 5 )); then
      (( pos > last_pos )) && rate=$(( (pos - last_pos) / delta ))
      last_pos=${pos}
      last_time=${now}
    fi

    ui::wait_tick "$(progress_label "${verb}" "${pos}" "${total}" "${rate}")"
    sleep 1
  done
}

# ==============================================================================
#  Signal handling
# ==============================================================================

#######################################
# Stop the simulation and report an interrupted run.
# Returns:
#   Never; exits 130.
#######################################
on_interrupt() {
  trap - INT TERM
  ui::wait_abort
  [[ -n "${TAIL_PID}" ]] && kill "${TAIL_PID}" 2> /dev/null || true
  [[ -n "${SIM_PID}" ]] && kill "${SIM_PID}" 2> /dev/null || true
  ui::blank
  ui::fail "interrupted"
  [[ -n "${SIM_LOG:-}" ]] && ui::note "partial log: $(ui::relpath "${SIM_LOG}" "${REPO_ROOT}")"
  ui::result_banner fail "SIMULATION INTERRUPTED"
  exit 130
}

# ==============================================================================
#  Argument parsing
# ==============================================================================

ui::init

while (( $# > 0 )); do
  case "$1" in
    -h | --help)    usage; exit 0 ;;
    -V | --version) printf '%s %s\n' "${PROG}" "${VERSION}"; exit 0 ;;
    --no-color)     ui::set_color off; shift ;;
    -f | --follow)  FOLLOW=1; shift ;;
    --assume-decoded) ASSUME_DECODED=1; shift ;;
    -o | --output)  OUT_DIR_OPT="${2:?--output requires a directory}"; shift 2 ;;
    -*)             UI_EXIT_CODE=1 ui::die "unknown option: $1" "try './${PROG} --help'" ;;
    *)
      if   [[ -z "${TRACE_ARG}"    ]]; then TRACE_ARG="$1"
      elif [[ -z "${GUEST_PT_ARG}" ]]; then GUEST_PT_ARG="$1"
      elif [[ -z "${HOST_PT_ARG}"  ]]; then HOST_PT_ARG="$1"
      else UI_EXIT_CODE=1 ui::die "unexpected argument: $1" "try './${PROG} --help'"
      fi
      shift ;;
  esac
done

# TRACE_DIR is also honoured as an environment variable, as it always was.
TRACE_ARG="${TRACE_ARG:-${TRACE_DIR:-}}"
[[ -n "${TRACE_ARG}" ]] || { usage; exit 1; }

# ==============================================================================
#  Main
# ==============================================================================

trap on_interrupt INT TERM
RUN_START=${SECONDS}

ui::set_steps 4
ui::banner "SagePTE ${G_DOT} Nested-Page-Walk Simulator" "${CONFIG_LABEL}"

# ------------------------------------------------------------------------------
#  1/4 — Inputs
# ------------------------------------------------------------------------------
ui::step "Inputs"

resolve_trace
resolve_dumps

NAME="$(basename "${TRACE_DIR}")"
OUT_DIR="${OUT_DIR_OPT:-${OUT_DIR:-${REPO_ROOT}/Results/${NAME}}}"
mkdir -p "${OUT_DIR}"
readonly SIM_LOG="${OUT_DIR}/sim_${CONFIG_NAME}.log"
readonly ANALYSIS_FILE="${OUT_DIR}/analysis_${CONFIG_NAME}.txt"
readonly TRACE_FILE="${TRACE}/${TRACE_FILENAME}"

ui::ok "trace  $(ui::relpath "${TRACE}" "${REPO_ROOT}")"
ui::field "guest PT" "$(ui::relpath "${GUEST_PT}" "${REPO_ROOT}")"
ui::field "host PT"  "$(ui::relpath "${HOST_PT}" "${REPO_ROOT}")"
ui::field "results"  "$(ui::relpath "${OUT_DIR}" "${REPO_ROOT}")"

# ------------------------------------------------------------------------------
#  2/4 — Environment
# ------------------------------------------------------------------------------
ui::step "Environment"

[[ -x "${DRRUN}" ]] ||
  UI_EXIT_CODE=2 ui::die "the simulator is not built: ${DRRUN} is missing" \
    "build it with:" \
    "    ./build.sh --only simulator" \
    "or, from this directory:" \
    "    ./install.sh"
ui::ok "simulator  $(ui::relpath "${DRRUN}" "${REPO_ROOT}")"

RAW_BYTES="$(du -sb "${TRACE}/raw" 2> /dev/null | cut -f1 || true)"
RAW_BYTES="${RAW_BYTES:-0}"

if [[ -s "${TRACE_FILE}" ]]; then
  # A decode that was interrupted leaves a truncated file behind, and a
  # truncated trace replays without complaining -- it just ends early and
  # reports statistics for however much of the workload survived. Since a
  # complete decode is several times the raw capture, anything close to the
  # raw size is the remains of a killed run, not a trace.
  if (( RAW_BYTES > 0 )) && (( ! ASSUME_DECODED )) &&
    (( $(stat -c %s "${TRACE_FILE}") < RAW_BYTES * MIN_DECODE_EXPANSION )); then
    ui::warn "the decoded trace looks incomplete"
    ui::field "decoded" "$(ui::size_of "${TRACE_FILE}")"
    ui::field "raw"     "$(ui::size_of "${TRACE}/raw")"
    ui::field "expected" "~$(ui::bytes $(( RAW_BYTES * DECODE_EXPANSION )))"
    UI_EXIT_CODE=2 ui::die "refusing to replay what looks like a partial decode" \
      "an interrupted decode leaves a truncated file that replays silently," \
      "reporting statistics for only the part that was written" \
      "" \
      "delete it and let this run decode again:" \
      "    rm $(ui::relpath "${TRACE_FILE}" "${REPO_ROOT}")" \
      "" \
      "or pass --assume-decoded if the trace really is complete"
  fi
  DECODED_AT_START=1
  ui::ok "decoded trace  $(ui::size_of "${TRACE_FILE}")"
else
  DECODED_AT_START=0
  ui::warn "the trace is not decoded yet — the simulator will decode it first"
  ui::note "this is a one-off cost of roughly ${DECODE_EXPANSION}x the raw capture" \
    ""
  ui::note "expected size  ~$(ui::bytes $(( RAW_BYTES * DECODE_EXPANSION )))"
  ui::note "do it separately next time with: Tracer/convert_trace.sh <workload>"
fi

ui::field "log" "$(ui::relpath "${SIM_LOG}" "${REPO_ROOT}")"
(( FOLLOW )) || ui::note "follow it live from another shell: tail -f $(ui::relpath "${SIM_LOG}" "${REPO_ROOT}")"

# ------------------------------------------------------------------------------
#  3/4 — Simulation
# ------------------------------------------------------------------------------
ui::step "Simulation"

"${DRRUN}" -t drcachesim \
  -indir "${TRACE}" \
  -pt_dump_file "${GUEST_PT}" \
  -vt_pt_dump_file "${HOST_PT}" \
  "${SIM_OPTS[@]}" \
  > "${SIM_LOG}" 2>&1 &
SIM_PID=$!

SIM_STATUS=0
if (( FOLLOW )); then
  # Streaming and a self-rewriting progress line cannot share a terminal, so
  # --follow gets the log and nothing else.
  ui::info "streaming the log (--follow)"
  ui::rule
  tail -n +1 -f --pid="${SIM_PID}" "${SIM_LOG}" &
  TAIL_PID=$!
  wait "${SIM_PID}" || SIM_STATUS=$?
  wait "${TAIL_PID}" 2> /dev/null || true
  TAIL_PID=""
  ui::rule
else
  watch_simulation
  wait "${SIM_PID}" || SIM_STATUS=$?
fi
SIM_PID=""

if (( SIM_STATUS != 0 )); then
  ui::wait_abort

  # Name the phase, not the command. The simulator decodes the raw capture
  # before replaying any of it, and a decode that ran out of disk has nothing
  # to do with the simulation the reader would otherwise go looking at.
  case "${SIM_PHASE}" in
    decoding)  what="decoding the trace" ;;
    replaying) what="the simulation" ;;
    *)         what="the simulator" ;;
  esac

  # An exit above 128 is a signal, not a failure of the run's own making.
  if (( SIM_STATUS > 128 )); then
    signo=$(( SIM_STATUS - 128 ))
    ui::fail "${what} was terminated by signal ${signo} ($(kill -l "${signo}" 2> /dev/null || echo "signal ${signo}"))"
    ui::note "something outside this run stopped it — it did not fail on its own"
    outcome="STOPPED"
  else
    ui::fail "${what} failed (exit ${SIM_STATUS})"
    outcome="FAILED"
  fi

  ui::blank
  while IFS= read -r line; do
    printf '      %s%s%s\n' "${C_DIM}" "${line}" "${C_RESET}"
  done < <(tail -n 8 "${SIM_LOG}" 2> /dev/null)
  ui::blank

  # A decode stopped part-way leaves a truncated trace that would otherwise be
  # mistaken for a finished one on the next run.
  if [[ "${SIM_PHASE}" == decoding && -s "${TRACE_FILE}" ]]; then
    ui::warn "a partial decode is left at $(ui::relpath "${TRACE_FILE}" "${REPO_ROOT}") ($(ui::size_of "${TRACE_FILE}"))"
    ui::note "delete it before re-running, or the next run replays a truncated trace:"
    ui::command "rm $(ui::relpath "${TRACE_FILE}" "${REPO_ROOT}")"
  fi

  ui::note "full log: $(ui::relpath "${SIM_LOG}" "${REPO_ROOT}")"
  ui::result_banner fail "${what^^} ${outcome} ${G_DOT} ${NAME}"
  exit 3
fi

(( FOLLOW )) || ui::wait_end "simulation complete"
sync

# ------------------------------------------------------------------------------
#  4/4 — Analysis
# ------------------------------------------------------------------------------
ui::step "Analysis"

if "${ANALYZER}" "${SIM_LOG}" > "${ANALYSIS_FILE}" 2> /dev/null; then
  ui::ok "analysis  $(ui::relpath "${ANALYSIS_FILE}" "${REPO_ROOT}")"
  ui::blank
  ui::rule
  cat "${ANALYSIS_FILE}"
  ui::rule
else
  rm -f "${ANALYSIS_FILE}"
  ui::warn "no \"Page Walk Statistics\" section in the log — nothing to analyse"
  ui::note "the run may have ended before the statistics were dumped"
  ui::note "log: $(ui::relpath "${SIM_LOG}" "${REPO_ROOT}")"
fi

ui::result_banner ok "SIMULATION COMPLETE ${G_DOT} ${NAME} (${CONFIG_NAME})"
ui::field "elapsed"  "$(ui::duration $(( SECONDS - RUN_START )))"
ui::field "log"      "$(ui::relpath "${SIM_LOG}" "${REPO_ROOT}")  ($(ui::size_of "${SIM_LOG}"))"
[[ -f "${ANALYSIS_FILE}" ]] &&
  ui::field "analysis" "$(ui::relpath "${ANALYSIS_FILE}" "${REPO_ROOT}")"
ui::blank
