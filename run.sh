#!/usr/bin/env bash
#
# ==============================================================================
#  SagePTE Artifact — End-to-end pipeline
# ==============================================================================
#
#  SYNOPSIS
#      run.sh <workload> [options]
#      run.sh --list
#
#  DESCRIPTION
#      Runs the complete pipeline for one workload, from an idle VM to a
#      parsed result, without stopping to hand work to the operator:
#
#          1  memory trace                     here, in the guest
#          2  guest page table (GVA->GPA)      here, in the guest
#          3  host page table  (GPA->HPA)      on the KVM host, over SSH
#          4  simulation                       here, in the guest
#
#      Stage 3 is the reason this script exists. The host page table can only
#      be produced on the KVM host, from a dump made inside the guest, while
#      that guest is running — so the artifact otherwise asks the operator to
#      copy a file up, change machines, run a command, and copy the result
#      back. That round trip is done here over SSH instead.
#
#  WHY STAGES 1 AND 2 OVERLAP
#      /proc exposes a process's page table only while that process is alive,
#      so the guest page table has to be captured *during* the trace, not
#      after it. The tracer is started in the background and the dumper waits
#      for it to begin recording; the workload is then frozen for the length
#      of the snapshot so that the trace and the page table describe the same
#      state, and resumed immediately afterwards. Pass --no-freeze to skip the
#      freeze on workloads that cannot tolerate a pause (a server with a live
#      client, for instance).
#
#  RESUMING
#      Every stage checks for its own output first and is skipped if it is
#      already there, so an interrupted run can simply be repeated. Use
#      --force to redo a stage that has already completed.
#
#  OUTPUT
#      Data/<workload>/drmemtrace.dir/    the memory trace
#      Data/<workload>/pt_dump.guest      guest page table
#      Data/<workload>/pt_dump.host       host page table, fetched from the host
#      Results/<workload>/analysis_*.txt  the parsed result
#      Logs/pipeline/<workload>.*.log     per-stage logs
#
#  EXIT CODES
#      0    the pipeline completed
#      1    usage error
#      2    environment error (not built, host unreachable, no such workload)
#      3    a stage failed
#      130  interrupted (Ctrl-C)
#
#  SEE ALSO
#      build.sh                   build everything this needs
#      Tracer/run.sh              stage 1 on its own
#      PageTables/Guest/run.sh    stage 2 on its own
#      PageTables/Host/run.sh     stage 3, run on the host
#      Simulator/run_arm.sh       stage 4 on its own
#
# ==============================================================================

set -euo pipefail

readonly VERSION="1.0.0"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="${SCRIPT_DIR}"
PROG="$(basename "${BASH_SOURCE[0]:-$0}")"
readonly PROG
readonly WORKLOAD_DIR="${REPO_ROOT}/Workloads"
readonly LOG_DIR="${REPO_ROOT}/Logs/pipeline"

# shellcheck source=Lib/ui.sh
source "${REPO_ROOT}/Lib/ui.sh"

# ------------------------------------------------------------------------------
# Tunables. Each is overridable from the command line; see usage().
# ------------------------------------------------------------------------------
HOST="192.168.122.1"     # the KVM host, as seen from inside this guest
HOST_USER="root"
HOST_REPO=""             # default: discovered on the host, see find_host_repo
ARCHES=()                # simulator configurations to run; default: arm
readonly KNOWN_ARCHES=(arm x86)
OUTPUT_DIR=""            # default: Data/<workload>
FREEZE=1                 # 1 = hold the workload while its page table is read
TRACE_TIMEOUT=7200       # seconds to wait for recording to start

# --force selects which stages to discard and redo. They are separate because
# they cost wildly different amounts: re-capturing Redis means preloading a
# 155 GB working set again, while re-simulating only replays an existing trace.
FORCE_CAPTURE=0          # trace + guest page table (they are captured together)
FORCE_HOST=0             # host page table
FORCE_SIM=0              # the simulation and its analysis

readonly SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new
                   -o ConnectTimeout=10)

# Populated as the run progresses; referenced by the trap handler.
WORKLOAD=""
APP_BINARY=""            # the workload's binary, used to find it in /proc
TRACER_PID=""
APP_PID=""
FROZEN=0
RUN_START=0

#######################################
# Print the help text.
#######################################
usage() {
  cat << EOF
${C_BOLD}SagePTE end-to-end pipeline${C_RESET} v${VERSION}

${C_BOLD}USAGE${C_RESET}
  ./${PROG} <workload> [arch...] [options]

${C_BOLD}ARGUMENTS${C_RESET}
  workload       a name from ./${PROG} --list
  arch           arm, x86, or both        (default: arm, the paper's machine)

  Order does not matter — arm, x86 and both are recognised wherever they
  appear. Naming both simulates the same capture twice: stages 1-4 produce the
  trace and the page tables, which do not depend on the modelled machine, and
  only the simulation is repeated.

${C_BOLD}OPTIONS${C_RESET}
  -c, --config arm|x86   same as passing the arch positionally
  -o, --output DIR       capture directory            (default: Data/<workload>)
      --host ADDR        the KVM host                 (default: ${HOST})
      --host-user USER   ssh user on the host         (default: ${HOST_USER})
      --host-repo PATH   artifact path on the host    (default: discovered)
      --no-freeze        do not pause the workload during the snapshot
  -f, --force [STAGES]   discard existing output and redo it. With no argument
                         this means everything; otherwise a comma-separated
                         list of: capture, host-pt, sim
                           --force sim        re-simulate an existing capture
                           --force host-pt    redo just the host translation
                           --force capture    re-trace from scratch
  -l, --list             list the available workloads
      --no-color         disable coloured output
  -h, --help             show this message
  -V, --version          show the version

${C_BOLD}EXAMPLES${C_RESET}
  ./${PROG} debug                    smoke-test the whole pipeline (arm)
  ./${PROG} redis                    the paper's configuration
  ./${PROG} gups x86                 simulate the x86 machine instead
  ./${PROG} redis both               capture once, simulate arm and x86

${C_BOLD}REQUIRES${C_RESET}
  Key-based SSH from this guest to ${HOST_USER}@${HOST}, and the artifact
  checked out and built on that host.
EOF
}

# ==============================================================================
#  Helpers
# ==============================================================================

#######################################
# Run a command on the KVM host.
# Arguments:
#   $@ — the command line, run through the remote shell.
#######################################
on_host() { ssh "${SSH_OPTS[@]}" "${HOST_USER}@${HOST}" "$@"; }

#######################################
# Locate the artifact on the host, so --host-repo is only needed when the
# checkout is somewhere unusual.
# Outputs:
#   The remote path on stdout, empty when nothing was found.
#######################################
find_host_repo() {
  on_host 'for d in ~/SagePTE-AE /root/SagePTE-AE /home/*/SagePTE-AE /opt/SagePTE-AE; do
             [ -x "$d/PageTables/Host/run.sh" ] && { echo "$d"; exit 0; }
           done' 2> /dev/null || true
}

#######################################
# Read one field out of the tracer's state file.
# Arguments:
#   $1 — key; $2 — state file path.
# Outputs:
#   The value on stdout, empty when absent.
#######################################
state_field() {
  [[ -f "$2" ]] || return 0
  sed -n "s/^$1=//p" "$2" | tail -1
}

#######################################
# Describe what the workload is doing before recording starts.
#
# Nothing reports this directly: the tracer is waiting on a readiness file the
# workload writes once its working set is built, and for Redis that means
# preloading ~155 GB first. Resident memory is therefore the honest progress
# signal — it is the working set being built — and the tracer's own last log
# line covers the phases before the process exists.
# Globals:
#   Reads APP_BINARY, TRACE_LOG.
# Outputs:
#   A short status string on stdout.
#######################################
capture_progress() {
  local pid rss
  if [[ -n "${APP_BINARY}" ]] && pid="$(pgrep -x "${APP_BINARY}" 2> /dev/null | head -1)" &&
    [[ -n "${pid}" ]]; then
    rss="$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\) kB/\1/p' "/proc/${pid}/status" 2> /dev/null)"
    if [[ -n "${rss}" ]]; then
      printf 'building working set  %s resident' "$(ui::bytes $(( rss * 1024 )))"
      return 0
    fi
  fi
  # Fall back to whatever the tracer last reported, with its colour stripped.
  local line
  line="$(tail -n 25 "${TRACE_LOG}" 2> /dev/null |
    sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/^[[:space:]]*//' |
    grep -vE '^[[:space:]]*$|^[─│╭╰]' | tail -1 | cut -c1-58)"
  printf '%s' "${line:-waiting for the workload to start}"
}

#######################################
# Run a command with its output captured, showing a live progress line.
# Arguments:
#   $1 — label; $2 — log path; $3… — the command.
# Returns:
#   The command's exit status.
#######################################
run_logged() {
  local label="$1" log="$2"
  shift 2
  local rc=0 pid
  ui::wait_begin "${label}"
  "$@" >> "${log}" 2>&1 &
  pid=$!
  while kill -0 "${pid}" 2> /dev/null; do
    ui::wait_tick "${label}"
    sleep 0.5
  done
  wait "${pid}" || rc=$?
  (( rc == 0 )) && ui::wait_end "${label}" || ui::wait_abort
  return "${rc}"
}

#######################################
# Report a failed stage: the tail of its log, then stop.
# Arguments:
#   $1 — stage name; $2 — log path.
# Returns:
#   Never; exits 3.
#######################################
stage_failed() {
  local stage="$1" log="$2"
  ui::fail "${stage} failed"
  ui::blank
  while IFS= read -r line; do
    printf '      %s%s%s\n' "${C_DIM}" "${line}" "${C_RESET}"
  done < <(tail -n 8 "${log}" 2> /dev/null)
  ui::blank
  ui::note "full log: $(ui::relpath "${log}" "${REPO_ROOT}")"
  ui::result_banner fail "PIPELINE FAILED ${G_DOT} ${WORKLOAD}"
  exit 3
}

#######################################
# Resume the workload if this script froze it. Safe to call more than once.
#######################################
thaw() {
  (( FROZEN )) || return 0
  kill -CONT "${APP_PID}" 2> /dev/null || true
  FROZEN=0
}

#######################################
# Stop everything this script started and report an interrupted run.
# Returns:
#   Never; exits 130.
#######################################
on_interrupt() {
  trap - INT TERM
  ui::wait_abort
  thaw
  [[ -n "${TRACER_PID}" ]] && kill "${TRACER_PID}" 2> /dev/null || true
  ui::blank
  ui::fail "interrupted"
  ui::result_banner fail "PIPELINE INTERRUPTED ${G_DOT} ${WORKLOAD}"
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
    -l | --list)    exec "${REPO_ROOT}/Tracer/run.sh" --list ;;
    --no-color)     ui::set_color off; shift ;;
    -c | --config)  ARCHES+=("${2:?--config requires arm or x86}"); shift 2 ;;
    -o | --output)  OUTPUT_DIR="${2:?--output requires a directory}"; shift 2 ;;
    --host)         HOST="${2:?--host requires an address}"; shift 2 ;;
    --host-user)    HOST_USER="${2:?--host-user requires a user}"; shift 2 ;;
    --host-repo)    HOST_REPO="${2:?--host-repo requires a path}"; shift 2 ;;
    --no-freeze)    FREEZE=0; shift ;;
    -f | --force)
      # The argument is optional, so it is only consumed when it names stages
      # rather than being the workload or another flag.
      if [[ "${2:-}" =~ ^(all|capture|trace|guest-pt|host-pt|sim)(,(all|capture|trace|guest-pt|host-pt|sim))*$ ]]; then
        _stages="$2"; shift 2
      else
        _stages="all"; shift
      fi
      IFS=',' read -r -a _list <<< "${_stages}"
      for _s in "${_list[@]}"; do
        case "${_s}" in
          all)                       FORCE_CAPTURE=1; FORCE_HOST=1; FORCE_SIM=1 ;;
          # The guest page table is captured during the trace, so neither can
          # be redone alone; and a new capture invalidates the host table
          # derived from it.
          capture | trace | guest-pt) FORCE_CAPTURE=1; FORCE_HOST=1 ;;
          host-pt)                   FORCE_HOST=1 ;;
          sim)                       FORCE_SIM=1 ;;
        esac
      done
      unset _stages _list _s ;;
    -*)             UI_EXIT_CODE=1 ui::die "unknown option: $1" "try './${PROG} --help'" ;;
    # An architecture is recognised wherever it appears: the set is closed, so
    # there is nothing to disambiguate against a workload name.
    arm | x86)  ARCHES+=("$1"); shift ;;
    both)       ARCHES+=(arm x86); shift ;;
    *)
      # A second positional is either a second workload or a mistyped arch;
      # naming both possibilities beats guessing which one was meant.
      [[ -z "${WORKLOAD}" ]] ||
        UI_EXIT_CODE=1 ui::die "unexpected argument: $1" \
          "the workload is already '${WORKLOAD}'" \
          "architectures are: ${KNOWN_ARCHES[*]}, or 'both'"
      WORKLOAD="$1"; shift ;;
  esac
done

[[ -n "${WORKLOAD}" ]] || { usage; exit 1; }

(( ${#ARCHES[@]} > 0 )) || ARCHES=(arm)
for _a in "${ARCHES[@]}"; do
  [[ " ${KNOWN_ARCHES[*]} " == *" ${_a} "* ]] ||
    UI_EXIT_CODE=1 ui::die "unknown architecture: ${_a}" \
      "known: ${KNOWN_ARCHES[*]}, or 'both'"
  [[ -x "${REPO_ROOT}/Simulator/run_${_a}.sh" ]] ||
    UI_EXIT_CODE=2 ui::die "Simulator/run_${_a}.sh is missing or not executable"
done
unset _a
# De-duplicate, so "arm arm" or "both x86" still simulates each machine once.
readarray -t ARCHES < <(printf '%s\n' "${ARCHES[@]}" | awk '!seen[$0]++')

OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/Data/${WORKLOAD}}"
readonly STATE_FILE="${OUTPUT_DIR}/meta/trace.state"
readonly GUEST_PT="${OUTPUT_DIR}/pt_dump.guest"
readonly HOST_PT="${OUTPUT_DIR}/pt_dump.host"

# ==============================================================================
#  Main
# ==============================================================================

trap on_interrupt INT TERM
trap thaw EXIT

RUN_START=${SECONDS}
mkdir -p "${LOG_DIR}"

# Four capture stages, then one simulation per machine being modelled.
ui::set_steps $(( 4 + ${#ARCHES[@]} ))
ui::banner "SagePTE ${G_DOT} End-to-end pipeline" \
  "${WORKLOAD} ${G_DOT} ${ARCHES[*]} ${G_DOT} capture here, translate on the host, then simulate"

# ------------------------------------------------------------------------------
#  1/5 — Preflight
# ------------------------------------------------------------------------------
ui::step "Preflight"

[[ -f "${WORKLOAD_DIR}/${WORKLOAD}.sh" ]] ||
  UI_EXIT_CODE=2 ui::die "no such workload: ${WORKLOAD}" \
    "list them with: ./${PROG} --list"
ui::ok "workload  $(ui::relpath "${WORKLOAD_DIR}/${WORKLOAD}.sh" "${REPO_ROOT}")"

# Read the binary's name out of the definition rather than sourcing it: the
# definition also declares shell functions, and this is only needed to spot the
# process in /proc while it builds its working set.
APP_BINARY="$(sed -n 's/^BINARY=["'\'']\{0,1\}\([^"'\'']*\).*/\1/p' \
  "${WORKLOAD_DIR}/${WORKLOAD}.sh" | head -1)"
APP_BINARY="$(basename "${APP_BINARY:-}")"

for tool in "Tracer/build/bin64/drrun" "Simulator/build/bin64/drrun"; do
  [[ -x "${REPO_ROOT}/${tool}" ]] ||
    UI_EXIT_CODE=2 ui::die "${tool} is missing — the artifact is not built" \
      "build it with:" "    ./build.sh"
done
ui::ok "tracer and simulator built"

ui::wait_begin "contacting ${HOST_USER}@${HOST}"
if ! on_host true 2> /dev/null; then
  ui::wait_abort
  UI_EXIT_CODE=2 ui::die "cannot reach ${HOST_USER}@${HOST} over SSH" \
    "stage 3 runs on the KVM host and needs key-based access to it" \
    "check: ssh ${HOST_USER}@${HOST} true"
fi
ui::wait_end "host reachable  ${HOST_USER}@${HOST}"

if [[ -z "${HOST_REPO}" ]]; then
  HOST_REPO="$(find_host_repo)"
  [[ -n "${HOST_REPO}" ]] ||
    UI_EXIT_CODE=2 ui::die "the artifact was not found on ${HOST}" \
      "stage 3 runs PageTables/Host/run.sh there" \
      "point at it with: --host-repo /path/to/SagePTE-AE"
fi
ui::ok "host artifact  ${HOST_REPO}"

HOST_KERNEL="$(on_host 'uname -r' 2> /dev/null || echo unknown)"
if [[ "${HOST_KERNEL}" =~ ^([0-9]+)\.([0-9]+) ]] &&
  (( BASH_REMATCH[1] < 6 || (BASH_REMATCH[1] == 6 && BASH_REMATCH[2] < 1) )); then
  ui::warn "host kernel ${HOST_KERNEL} is below 6.1 — stage 3 will not build its module"
else
  ui::ok "host kernel  ${HOST_KERNEL}"
fi

ui::field "simulate"  "${ARCHES[*]}"
ui::field "capture"   "$(ui::relpath "${OUTPUT_DIR}" "${REPO_ROOT}")"

# ------------------------------------------------------------------------------
#  2/5 — Memory trace
# ------------------------------------------------------------------------------
ui::step "Memory trace"

TRACE_LOG="${LOG_DIR}/${WORKLOAD}.trace.log"

if [[ -d "${OUTPUT_DIR}/drmemtrace.dir" && -f "${GUEST_PT}" ]] && (( ! FORCE_CAPTURE )); then
  ui::ok "already captured  $(ui::relpath "${OUTPUT_DIR}/drmemtrace.dir" "${REPO_ROOT}") ($(ui::size_of "${OUTPUT_DIR}/drmemtrace.dir"))"
  ui::note "re-run with --force capture to capture again"
  SKIP_CAPTURE=1
else
  SKIP_CAPTURE=0
  if [[ -e "${OUTPUT_DIR}" ]]; then
    ui::warn "discarding the previous capture in $(ui::relpath "${OUTPUT_DIR}" "${REPO_ROOT}") ($(ui::size_of "${OUTPUT_DIR}"))"
    rm -rf "${OUTPUT_DIR}"
  fi
  : > "${TRACE_LOG}"

  # --no-pause: the tracer would otherwise hold for an operator to capture the
  # page table by hand, which is what stage 3 of this script does instead.
  # --force: reaching here means this capture is being (re)made, and the
  # tracer refuses to write into a directory that already exists.
  "${REPO_ROOT}/Tracer/run.sh" "${WORKLOAD}" --output "${OUTPUT_DIR}" --no-pause --force \
    >> "${TRACE_LOG}" 2>&1 &
  TRACER_PID=$!
  ui::info "tracer started  $(ui::relpath "${TRACE_LOG}" "${REPO_ROOT}")"

  # Wait for recording to actually begin. The workload builds its working set
  # first and only then signals readiness, so this is the long part of a
  # capture -- Redis preloads ~155 GB before it says it is ready.
  ui::wait_begin "waiting for recording to start"
  deadline=$(( SECONDS + TRACE_TIMEOUT ))
  while :; do
    status="$(state_field STATUS "${STATE_FILE}")"
    [[ "${status}" == tracing ]] && break
    if [[ "${status}" == failed ]] || ! kill -0 "${TRACER_PID}" 2> /dev/null; then
      ui::wait_abort
      stage_failed "the tracer" "${TRACE_LOG}"
    fi
    (( SECONDS < deadline )) || { ui::wait_abort
      UI_EXIT_CODE=3 ui::die "recording did not start within $(ui::duration "${TRACE_TIMEOUT}")" \
        "the workload never signalled readiness" \
        "log: $(ui::relpath "${TRACE_LOG}" "${REPO_ROOT}")"; }
    sleep 2
    ui::wait_tick "$(capture_progress)"
  done
  APP_PID="$(state_field APP_PID "${STATE_FILE}")"
  ui::wait_end "recording  pid ${APP_PID}"
fi

# ------------------------------------------------------------------------------
#  3/5 — Guest page table
# ------------------------------------------------------------------------------
ui::step "Guest page table"

if (( SKIP_CAPTURE )); then
  ui::ok "already captured  $(ui::relpath "${GUEST_PT}" "${REPO_ROOT}") ($(ui::size_of "${GUEST_PT}"))"
else
  DUMP_LOG="${LOG_DIR}/${WORKLOAD}.guest-pt.log"
  : > "${DUMP_LOG}"

  # Freeze the workload so the trace and the snapshot describe the same state.
  if (( FREEZE )) && [[ -n "${APP_PID}" ]] && kill -STOP "${APP_PID}" 2> /dev/null; then
    FROZEN=1
    ui::ok "workload held  ${C_DIM}(pid ${APP_PID}, for the snapshot)${C_RESET}"
  elif (( FREEZE )); then
    ui::warn "could not hold the workload; capturing while it runs"
  fi

  set +e
  "${REPO_ROOT}/PageTables/Guest/run.sh" "${WORKLOAD}" --output "${OUTPUT_DIR}" --compact
  dump_rc=$?
  set -e
  thaw
  (( dump_rc == 0 )) || { ui::fail "the guest page-table capture failed (exit ${dump_rc})"
    ui::result_banner fail "PIPELINE FAILED ${G_DOT} ${WORKLOAD}"; exit 3; }
  ui::ok "workload resumed"

  # Let the trace finish; it stops itself at the reference limit.
  if [[ -n "${TRACER_PID}" ]]; then
    ui::wait_begin "finishing the trace"
    while kill -0 "${TRACER_PID}" 2> /dev/null; do
      ui::wait_tick "finishing the trace  ${C_DIM}$(ui::size_of "${OUTPUT_DIR}")${C_RESET}"
      sleep 2
    done
    trace_rc=0
    wait "${TRACER_PID}" || trace_rc=$?
    TRACER_PID=""
    (( trace_rc == 0 )) && ui::wait_end "trace complete  ($(ui::size_of "${OUTPUT_DIR}"))" ||
      { ui::wait_abort; stage_failed "the tracer" "${TRACE_LOG}"; }
  fi
fi

[[ -f "${GUEST_PT}" ]] ||
  UI_EXIT_CODE=3 ui::die "no guest page table at $(ui::relpath "${GUEST_PT}" "${REPO_ROOT}")"

# ------------------------------------------------------------------------------
#  4/5 — Host page table, over SSH
# ------------------------------------------------------------------------------
ui::step "Host page table"

if [[ -f "${HOST_PT}" ]] && (( ! FORCE_HOST )); then
  ui::ok "already present  $(ui::relpath "${HOST_PT}" "${REPO_ROOT}") ($(ui::size_of "${HOST_PT}"))"
  ui::note "re-run with --force host-pt to translate again"
else
  if [[ -f "${HOST_PT}" ]]; then
    ui::warn "discarding the previous host page table ($(ui::size_of "${HOST_PT}"))"
    rm -f "${HOST_PT}"
  fi
  HOST_LOG="${LOG_DIR}/${WORKLOAD}.host-pt.log"
  : > "${HOST_LOG}"
  # Absolute, resolved on the host: the translation runs after a cd into the
  # host's checkout, so a path relative to the ssh user's home would be looked
  # up inside that checkout instead.
  REMOTE_HOME="$(on_host 'echo $HOME' 2> /dev/null | tr -d '\r')"
  [[ -n "${REMOTE_HOME}" ]] ||
    UI_EXIT_CODE=3 ui::die "could not determine the home directory of ${HOST_USER}@${HOST}"
  REMOTE_DIR="${REMOTE_HOME}/sagepte-${WORKLOAD}"

  on_host "mkdir -p '${REMOTE_DIR}'" >> "${HOST_LOG}" 2>&1

  run_logged "uploading the guest page table ($(ui::size_of "${GUEST_PT}"))" "${HOST_LOG}" \
    scp "${SSH_OPTS[@]}" -q "${GUEST_PT}" "${HOST_USER}@${HOST}:${REMOTE_DIR}/pt_dump.guest" ||
    stage_failed "the upload to ${HOST}" "${HOST_LOG}"

  # PageTables/Host/run.sh loads its own module and runs the augmentor; it
  # needs the guest to still be running, which it is — we are inside it.
  run_logged "translating GPA -> HPA on ${HOST}" "${HOST_LOG}" \
    on_host "cd '${HOST_REPO}' && ./PageTables/Host/run.sh '${REMOTE_DIR}/pt_dump.guest' \
             --output '${REMOTE_DIR}/pt_dump.host'" ||
    stage_failed "the host translation" "${HOST_LOG}"

  run_logged "fetching the host page table" "${HOST_LOG}" \
    scp "${SSH_OPTS[@]}" -q "${HOST_USER}@${HOST}:${REMOTE_DIR}/pt_dump.host" "${HOST_PT}" ||
    stage_failed "the download from ${HOST}" "${HOST_LOG}"

  [[ -s "${HOST_PT}" ]] ||
    UI_EXIT_CODE=3 ui::die "the host page table came back empty"
  ui::ok "host page table  $(ui::relpath "${HOST_PT}" "${REPO_ROOT}") ($(ui::size_of "${HOST_PT}"))"
fi

# ------------------------------------------------------------------------------
#  5/5 — Simulation
# ------------------------------------------------------------------------------
# Each machine is simulated from the same capture; only this stage is repeated.
for arch in "${ARCHES[@]}"; do
  ui::step "Simulation ${G_DOT} ${arch}"
  analysis="${REPO_ROOT}/Results/${WORKLOAD}/analysis_${arch}.txt"

  # A simulation over a full trace runs for hours, so a finished one is never
  # repeated by accident.
  if [[ -s "${analysis}" ]] && (( ! FORCE_SIM )); then
    ui::ok "already simulated  $(ui::relpath "${analysis}" "${REPO_ROOT}")"
    ui::note "re-run with --force sim to simulate again"
    continue
  fi
  if [[ -e "${analysis}" ]]; then
    ui::warn "discarding the previous ${arch} result"
    rm -f "${analysis}" "${REPO_ROOT}/Results/${WORKLOAD}/sim_${arch}.log"
  fi

  ui::info "handing over to Simulator/run_${arch}.sh"
  ui::blank
  if ! "${REPO_ROOT}/Simulator/run_${arch}.sh" "${OUTPUT_DIR}"; then
    ui::fail "the ${arch} simulation failed"
    ui::result_banner fail "PIPELINE FAILED ${G_DOT} ${WORKLOAD} (${arch})"
    exit 3
  fi
done

# ------------------------------------------------------------------------------
#  Done
# ------------------------------------------------------------------------------
ui::result_banner ok "PIPELINE COMPLETE ${G_DOT} ${WORKLOAD} (${ARCHES[*]})"
ui::field "elapsed"  "$(ui::duration $(( SECONDS - RUN_START )))"
ui::field "trace"    "$(ui::relpath "${OUTPUT_DIR}/drmemtrace.dir" "${REPO_ROOT}")"
ui::field "guest PT" "$(ui::relpath "${GUEST_PT}" "${REPO_ROOT}")"
ui::field "host PT"  "$(ui::relpath "${HOST_PT}" "${REPO_ROOT}")"
for arch in "${ARCHES[@]}"; do
  ui::field "analysis ${arch}" "Results/${WORKLOAD}/analysis_${arch}.txt"
done
ui::blank
