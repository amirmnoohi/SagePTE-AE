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
#          4  decode the capture (raw2trace)   here, in the guest
#          5  simulation                       here, in the guest
#
#      The decode is a stage of its own rather than something the simulator
#      does on the way in. It is hours of work on a full capture, and folded
#      into the simulation it is reported as simulating — with a progress bar
#      measuring the wrong thing.
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

# Bash reads a script incrementally, executing each command as it is parsed, so
# a script that is edited — or pulled — while it is running continues reading
# from a byte offset into a file whose contents have moved underneath it. What
# it finds there is a fragment of some other line, and the result is a run that
# fails in a way bearing no relation to the code ("-o: command not found" at a
# blank line). A capture takes hours, which is ample time for a git pull.
#
# Wrapping the body in a brace group forces the whole file to be parsed before
# any of it runs, so an edit mid-run cannot affect the run in flight.
{

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
HOST_STAGE=""            # where the host tooling is placed; set in stage 3
ARCHES=()                # simulator configurations to run; default: x86
readonly KNOWN_ARCHES=(arm x86)
OUTPUT_DIR=""            # default: Data/<workload>
FREEZE=1                 # 1 = hold the workload while its page table is read
TRACE_STALL=1800         # seconds without progress before a capture is judged stuck

# --force selects which stages to discard and redo. They are separate because
# they cost wildly different amounts: re-capturing Redis means preloading a
# 155 GB working set again, while re-simulating only replays an existing trace.
FORCE_CAPTURE=0          # trace + guest page table (they are captured together)
FORCE_HOST=0             # host page table
FORCE_DECODE=0           # raw2trace decode of the capture
FORCE_SIM=0              # the simulation and its analysis

# One multiplexed connection for the whole run. Progress is reported by asking
# the host how large the file it is receiving has become, which would otherwise
# mean a fresh SSH handshake every couple of seconds.
readonly SSH_CTL_DIR="${TMPDIR:-/tmp}/sagepte-ssh-$$"
readonly SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new
                   -o ConnectTimeout=10
                   -o ControlMaster=auto -o "ControlPath=${SSH_CTL_DIR}/%r@%h:%p"
                   -o ControlPersist=120)

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
  arch           arm, x86, or both        (default: x86)

  Order does not matter — arm, x86 and both are recognised wherever they
  appear. Naming both simulates the same capture twice: stages 1-4 produce the
  trace and the page tables, which do not depend on the modelled machine, and
  only the simulation is repeated.

${C_BOLD}OPTIONS${C_RESET}
  -c, --config arm|x86   same as passing the arch positionally
  -o, --output DIR       capture directory            (default: Data/<workload>)
      --host ADDR        the KVM host                 (default: ${HOST})
      --host-user USER   ssh user on the host         (default: ${HOST_USER})
      --no-freeze        do not pause the workload during the snapshot
  -f, --force [STAGES]   discard existing output and redo it. With no argument
                         this means everything; otherwise a comma-separated
                         list of: capture, host-pt, decode, sim
                           --force sim        re-simulate an existing capture
                           --force host-pt    redo just the host translation
                           --force capture    re-trace from scratch
  -l, --list             list the available workloads
      --no-color         disable coloured output
  -h, --help             show this message
  -V, --version          show the version

${C_BOLD}EXAMPLES${C_RESET}
  ./${PROG} debug                    smoke-test the whole pipeline
  ./${PROG} redis                    the paper's configuration
  ./${PROG} gups arm                 simulate the ARM machine instead
  ./${PROG} redis both               capture once, simulate both machines

${C_BOLD}REQUIRES${C_RESET}
  Key-based SSH from this guest to ${HOST_USER}@${HOST}, and kernel headers
  there. The host tooling is copied over and built by this script; nothing
  needs to be installed on the host beforehand.
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
# Copy the host-side tooling to the KVM host, so the only machine that needs
# this artifact installed is the one being run from.
#
# Sources only: the module and the augmentor are rebuilt there against the
# host's own kernel, and shipping our binaries would mean shipping objects
# built for the guest's. PageTables/Host expects Lib/ui.sh two directories
# above it, so the pair is unpacked with that shape intact.
# Arguments:
#   $1 — destination directory on the host.
#######################################
push_host_code() {
  local dest="$1"
  on_host "rm -rf '${dest}' && mkdir -p '${dest}'" || return 1
  tar -C "${REPO_ROOT}" \
    --exclude='*.o' --exclude='*.ko' --exclude='*.mod' --exclude='*.mod.c' \
    --exclude='.*.cmd' --exclude='Module.symvers' --exclude='modules.order' \
    --exclude='host_pt_augmentor' --exclude='*.log' --exclude='build.log' \
    -cf - PageTables/Host Lib |
    on_host "tar -C '${dest}' -xf -"
}

#######################################
# Put both machines into the state the measurements assume: no transparent
# huge pages, and a cold page cache.
#
# The host matters most. Its THP setting decides how deep the terminal Stage-2
# walk is, because guest RAM backed by 2 MB pages ends the walk a level early
# and makes the h-final phase cheaper than the hardware being modelled would.
# khugepaged also collapses while the guest runs, so leaving it enabled makes
# the result depend on how long the VM has been up.
# Globals:
#   Reads REPO_ROOT, HOST, HOST_USER.
#######################################
ensure_prepared() {
  local prep="${REPO_ROOT}/scripts/prepare_system.sh"

  # Unconditionally, on both machines, before anything is measured. Setting THP
  # is idempotent, but dropping the page cache is not: it has to happen every
  # run, or a capture inherits whatever the previous one left resident.

  # --- this guest -----------------------------------------------------------
  if [[ -x "${prep}" ]]; then
    ${SUDO:-} "${prep}" > /dev/null 2>&1 || true
    if "${prep}" --check > /dev/null 2>&1; then
      ui::ok "guest prepared  THP disabled, page cache dropped"
    else
      ui::warn "guest still reports transparent huge pages enabled"
      ui::note "run scripts/prepare_system.sh as root here"
    fi
  fi

  # --- the KVM host ---------------------------------------------------------
  # The same four operations, over SSH. This is the only place in the artifact
  # that reaches the host.
  on_host 'echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
           echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
           sync
           echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true' > /dev/null 2>&1 || true

  local mode
  mode="$(on_host 'sed -n "s/.*\[\([a-z+]*\)\].*/\1/p" /sys/kernel/mm/transparent_hugepage/enabled' 2> /dev/null || true)"
  if [[ "${mode}" == never ]]; then
    ui::ok "host prepared  THP disabled, page cache dropped"
  else
    ui::warn "host transparent huge pages are '\''${mode:-unknown}'\''"
    ui::note "the host page table will record 2 MB mappings and the walk will be short"
  fi

  # Disabling THP stops new collapses but splits nothing already collapsed, so a
  # guest whose RAM is on huge pages stays that way until it restarts. That is
  # measurable, so it is reported rather than assumed away.
  local huge
  huge="$(on_host 'q=$(pgrep -f "qemu-system|qemu-kvm" | head -1);
                   [ -n "$q" ] && awk "/^AnonHugePages:/ {print \$2}" /proc/$q/smaps_rollup 2>/dev/null || echo 0' 2> /dev/null || echo 0)"
  huge="${huge//[^0-9]/}"
  if (( ${huge:-0} > 0 )); then
    ui::warn "this guest already holds $(ui::bytes $(( huge * 1024 ))) of host huge pages"
    ui::note "they were collapsed before THP was disabled and persist until the VM restarts"
    ui::note "restart the VM for a capture that measures a full-depth host walk"
  fi
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
#######################################
# A signature of a capture's forward motion, for telling "still working" from
# "wedged".
#
# Two independent signals, because either alone gives a false reading: a
# workload that prints nothing while it allocates would look stalled by its
# output, and one blocked on a futex still has its log sitting there unchanged.
# Together they only agree when nothing at all is happening. Output is measured
# in bytes rather than content because the workload's log is block-buffered and
# the visible tail can repeat for a minute at a time while the file grows.
# Globals:
#   Reads OUTPUT_DIR, TRACER_PID.
# Outputs:
#   "<log bytes> <cpu ticks>", or empty when the tracer is gone.
#######################################
capture_signature() {
  local log="${OUTPUT_DIR}/meta/tracer.log" bytes=0 ticks=0 pid value
  [[ -f "${log}" ]] && bytes="$(stat -c %s "${log}" 2> /dev/null || echo 0)"
  for pid in $(process_tree "${TRACER_PID}"); do
    value="$(awk '{print $14 + $15}' "/proc/${pid}/stat" 2> /dev/null)"
    ticks=$(( ticks + ${value:-0} ))
  done
  printf '%s %s' "${bytes}" "${ticks}"
}

#######################################
# Every descendant of a pid, the tracer's own children included: the workload
# runs several processes deep and only the leaves consume the CPU.
# Arguments:
#   $1 - pid to walk from.
# Outputs:
#   Whitespace-separated pids.
#######################################
process_tree() {
  local pid="$1" child
  for child in $(pgrep -P "${pid}" 2> /dev/null || true); do
    printf '%s ' "${child}"
    process_tree "${child}"
  done
}

capture_progress() {
  local pid rss published
  # The tracer publishes the workload's own progress -- a percentage and an
  # estimate where the workload reports one -- which beats anything derivable
  # from outside the process.
  local progress_file="${OUTPUT_DIR}/meta/progress.txt"
  if [[ -r "${progress_file}" ]]; then
    published="$(< "${progress_file}")"
    if [[ -n "${published}" ]]; then
      printf '%s' "${published}"
      return 0
    fi
  fi
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
# Size of a file on the host, 0 when it does not exist yet.
# Arguments:
#   $1 — remote path.
#######################################
remote_size() {
  on_host "stat -c %s '$1' 2> /dev/null || echo 0" 2> /dev/null | tr -cd '0-9' || echo 0
}

#######################################
# Size of a local file, 0 when absent.
#######################################
local_size() { stat -c %s "$1" 2> /dev/null || echo 0; }

#######################################
# Run a command with its output captured, showing a live progress line.
#
# With a total and a way to measure what is done, the line carries a bar and an
# estimate; without them it carries the label and the elapsed time. Nothing
# here invents a completion figure for work whose size is not known in advance.
# Globals:
#   Reads PROBE_CMD and PROBE_TOTAL when set, to measure progress as a
#   fraction; or PROBE_TEXT_CMD, for work whose remaining time is not
#   predictable but whose current activity is worth naming.
# Arguments:
#   $1 — label; $2 — log path; $3… — the command.
# Returns:
#   The command's exit status.
#######################################
run_logged() {
  local label="$1" log="$2"
  shift 2
  local rc=0 pid done=0 last=0 last_t=${SECONDS} rate=0 now delta
  ui::wait_begin "${label}"
  "$@" >> "${log}" 2>&1 &
  pid=$!
  while kill -0 "${pid}" 2> /dev/null; do
    if [[ -n "${PROBE_CMD:-}" ]] && (( ${PROBE_TOTAL:-0} > 0 )); then
      done="$(${PROBE_CMD})"
      now=${SECONDS}
      delta=$(( now - last_t ))
      if (( delta >= 4 )); then
        (( done > last )) && rate=$(( (done - last) / delta ))
        last=${done}
        last_t=${now}
      fi
      ui::wait_tick "$(ui::progress "${label}" "${done}" "${PROBE_TOTAL}" "${rate}")"
    elif [[ -n "${PROBE_TEXT_CMD:-}" ]]; then
      ui::wait_tick "${label}  ${C_DIM}$(${PROBE_TEXT_CMD})${C_RESET}"
    else
      ui::wait_tick "${label}"
    fi
    ui::wait_sleep 2
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
  ui::result_banner fail "PIPELINE FAILED: ${WORKLOAD}"
  exit 3
}

#######################################
# Release everything this script holds: the frozen workload, and the shared SSH
# connection. Safe to call more than once.
#######################################
cleanup() {
  thaw
  if [[ -d "${SSH_CTL_DIR}" ]]; then
    ssh "${SSH_OPTS[@]}" -O exit "${HOST_USER}@${HOST}" 2> /dev/null || true
    rm -rf "${SSH_CTL_DIR}"
  fi
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
  ui::result_banner fail "PIPELINE INTERRUPTED: ${WORKLOAD}"
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
    --no-freeze)    FREEZE=0; shift ;;
    -f | --force)
      # The argument is optional, so it is only consumed when it names stages
      # rather than being the workload or another flag.
      if [[ "${2:-}" =~ ^(all|capture|trace|guest-pt|host-pt|decode|sim)(,(all|capture|trace|guest-pt|host-pt|decode|sim))*$ ]]; then
        _stages="$2"; shift 2
      else
        _stages="all"; shift
      fi
      IFS=',' read -r -a _list <<< "${_stages}"
      for _s in "${_list[@]}"; do
        case "${_s}" in
          all)                       FORCE_CAPTURE=1; FORCE_HOST=1; FORCE_DECODE=1; FORCE_SIM=1 ;;
          # The guest page table is captured during the trace, so neither can
          # be redone alone; and a new capture invalidates the host table
          # derived from it.
          capture | trace | guest-pt) FORCE_CAPTURE=1; FORCE_HOST=1; FORCE_DECODE=1 ;;
          host-pt)                   FORCE_HOST=1 ;;
          decode)                    FORCE_DECODE=1 ;;
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

(( ${#ARCHES[@]} > 0 )) || ARCHES=(x86)
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
trap cleanup EXIT

RUN_START=${SECONDS}
mkdir -p "${LOG_DIR}"
mkdir -p "${SSH_CTL_DIR}" && chmod 700 "${SSH_CTL_DIR}"

# Five capture stages, then one simulation per machine being modelled.
ui::set_steps $(( 5 + ${#ARCHES[@]} ))
ui::banner "SagePTE ${G_DOT} End-to-end pipeline" "${WORKLOAD} (${ARCHES[*]})"

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

# Build on demand rather than sending the operator away to do it. This is the
# one command the artifact asks for, so it should not stop to ask for another.
NEED_BUILD=0
for tool in "Tracer/build/bin64/drrun" "Simulator/build/bin64/drrun"; do
  [[ -x "${REPO_ROOT}/${tool}" ]] || NEED_BUILD=1
done

if (( NEED_BUILD )); then
  ui::info "the artifact is not built yet; building it first"
  BUILD_LOG="${LOG_DIR}/build.log"
  : > "${BUILD_LOG}"
  run_logged "building the artifact" "${BUILD_LOG}" "${REPO_ROOT}/build.sh" ||
    stage_failed "the build" "${BUILD_LOG}"
  for tool in "Tracer/build/bin64/drrun" "Simulator/build/bin64/drrun"; do
    [[ -x "${REPO_ROOT}/${tool}" ]] ||
      UI_EXIT_CODE=2 ui::die "${tool} is still missing after the build" \
        "see $(ui::relpath "${BUILD_LOG}" "${REPO_ROOT}")"
  done
fi
ui::ok "tracer and simulator built"

ui::wait_begin "contacting ${HOST_USER}@${HOST}"
if ! on_host true 2> /dev/null; then
  ui::wait_abort
  UI_EXIT_CODE=2 ui::die "cannot reach ${HOST_USER}@${HOST} over SSH" \
    "stage 3 runs on the KVM host and needs key-based access to it" \
    "check: ssh ${HOST_USER}@${HOST} true"
fi
ui::wait_end "host reachable  ${HOST_USER}@${HOST}"

# Nothing needs to be installed on the host: the tooling is copied there when
# stage 3 runs. What the host must have is a kernel it can build against.
if on_host 'test -d /lib/modules/$(uname -r)/build' 2> /dev/null; then
  ui::ok "host can build kernel modules"
else
  ui::warn "the host has no build tree for its running kernel"
  ui::note "install linux-headers there, or stage 3 will fail"
fi

HOST_KERNEL="$(on_host 'uname -r' 2> /dev/null || echo unknown)"
if [[ "${HOST_KERNEL}" =~ ^([0-9]+)\.([0-9]+) ]] &&
  (( BASH_REMATCH[1] < 6 || (BASH_REMATCH[1] == 6 && BASH_REMATCH[2] < 1) )); then
  ui::warn "host kernel ${HOST_KERNEL} is below 6.1 — stage 3 will not build its module"
else
  ui::ok "host kernel  ${HOST_KERNEL}"
fi

ensure_prepared

ui::field "simulate"  "${ARCHES[*]}"
ui::field "capture"   "$(ui::relpath "${OUTPUT_DIR}" "${REPO_ROOT}")"

# ------------------------------------------------------------------------------
#  2/5 — Memory trace
# ------------------------------------------------------------------------------
ui::step "Memory trace"

TRACE_LOG="${LOG_DIR}/${WORKLOAD}.trace.log"

# A capture directory is named drmemtrace.<binary>.<pid>.<tid>.dir, never
# "drmemtrace.dir". Matching the literal name finds nothing, concludes there is
# no capture, and falls through to the branch that deletes one.
# The directory is absent on a first capture, and find exits non-zero for it.
# Under `set -e` with pipefail that failure propagates out of the assignment and
# kills the run with no message at all, so it is guarded rather than relied on.
EXISTING_TRACE=""
if [[ -d "${OUTPUT_DIR}" ]]; then
  EXISTING_TRACE="$(find "${OUTPUT_DIR}" -maxdepth 1 -name 'drmemtrace*' -type d 2> /dev/null |
    sort | head -1 || true)"
fi

if [[ -n "${EXISTING_TRACE}" && -f "${GUEST_PT}" ]] && (( ! FORCE_CAPTURE )); then
  ui::ok "already captured  $(ui::relpath "${EXISTING_TRACE}" "${REPO_ROOT}") ($(ui::size_of "${EXISTING_TRACE}"))"
  ui::note "re-run with --force capture to capture again"
  SKIP_CAPTURE=1
else
  SKIP_CAPTURE=0

  # Nothing is deleted unless --force capture asked for it. A capture costs
  # hours, and the page-table dumps cannot be remade at all once the traced
  # process has exited, so a directory that looks incomplete stops the run
  # rather than being cleared.
  if [[ -e "${OUTPUT_DIR}" ]] && (( ! FORCE_CAPTURE )); then
    UI_EXIT_CODE=2 ui::die "$(ui::relpath "${OUTPUT_DIR}" "${REPO_ROOT}") exists but looks incomplete" \
      "trace directory:  ${EXISTING_TRACE:-none found}" \
      "guest page table: $([[ -f "${GUEST_PT}" ]] && echo present || echo missing)" \
      "" \
      "Nothing has been deleted. To capture again and discard what is there:" \
      "    ./${PROG} ${WORKLOAD} --force capture" \
      "or send this run elsewhere with --output DIR"
  fi

  if [[ -e "${OUTPUT_DIR}" ]]; then
    ui::info "discarding the previous capture in $(ui::relpath "${OUTPUT_DIR}" "${REPO_ROOT}") ($(ui::size_of "${OUTPUT_DIR}"))"
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
  # Judged on progress, not on elapsed time. How long a workload needs to build
  # its working set is a property of the workload -- Redis preloads 155 GB in
  # under two hours, graph500 runs eight passes over 4.3 billion edges and needs
  # far longer -- so any fixed deadline is wrong for something. What a wedged
  # run does have in common is that it stops moving.
  stall_since=${SECONDS}
  last_signature=""
  while :; do
    status="$(state_field STATUS "${STATE_FILE}")"
    [[ "${status}" == tracing ]] && break
    if [[ "${status}" == failed ]] || ! kill -0 "${TRACER_PID}" 2> /dev/null; then
      ui::wait_abort
      stage_failed "the tracer" "${TRACE_LOG}"
    fi
    signature="$(capture_signature)"
    if [[ "${signature}" != "${last_signature}" ]]; then
      last_signature="${signature}"
      stall_since=${SECONDS}
    elif (( SECONDS - stall_since >= TRACE_STALL )); then
      ui::wait_abort
      UI_EXIT_CODE=3 ui::die \
        "the capture has made no progress for $(ui::duration "${TRACE_STALL}")" \
        "the workload has produced no output and used no CPU in that time" \
        "log: $(ui::relpath "${TRACE_LOG}" "${REPO_ROOT}")"
    fi
    ui::wait_sleep 2
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
    ui::result_banner fail "PIPELINE FAILED: ${WORKLOAD}"; exit 3; }
  ui::ok "workload resumed"

  # Let the trace finish; it stops itself at the reference limit.
  if [[ -n "${TRACER_PID}" ]]; then
    # No ETA here on purpose: the trace ends at a reference count, not at a
    # size, so nothing on disk predicts when it stops. Rate and total written
    # are what can honestly be shown.
    ui::wait_begin "finishing the trace"
    tr_last=0 tr_last_t=${SECONDS} tr_rate=0
    while kill -0 "${TRACER_PID}" 2> /dev/null; do
      tr_now="$(du -sb "${OUTPUT_DIR}" 2> /dev/null | cut -f1)"
      tr_now="${tr_now:-0}"
      tr_delta=$(( SECONDS - tr_last_t ))
      if (( tr_delta >= 4 )); then
        (( tr_now > tr_last )) && tr_rate=$(( (tr_now - tr_last) / tr_delta ))
        tr_last=${tr_now}; tr_last_t=${SECONDS}
      fi
      if (( tr_rate > 0 )); then
        ui::wait_tick "finishing the trace  ${C_DIM}$(ui::bytes "${tr_now}") at $(ui::bytes "${tr_rate}")/s${C_RESET}"
      else
        ui::wait_tick "finishing the trace  ${C_DIM}$(ui::bytes "${tr_now}")${C_RESET}"
      fi
      ui::wait_sleep 2
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
    ui::info "discarding the previous host page table ($(ui::size_of "${HOST_PT}"))"
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
  HOST_STAGE="${REMOTE_HOME}/sagepte-host"

  on_host "mkdir -p '${REMOTE_DIR}'" >> "${HOST_LOG}" 2>&1

  run_logged "copying the host tooling to ${HOST}" "${HOST_LOG}" \
    push_host_code "${HOST_STAGE}" ||
    stage_failed "the copy to ${HOST}" "${HOST_LOG}"

  # Upload: the total is the local file, and the host reports what has landed.
  probe_upload() { remote_size "${REMOTE_DIR}/pt_dump.guest"; }
  PROBE_CMD=probe_upload PROBE_TOTAL="$(local_size "${GUEST_PT}")" \
    run_logged "uploading the guest page table" "${HOST_LOG}" \
      scp "${SSH_OPTS[@]}" -q "${GUEST_PT}" "${HOST_USER}@${HOST}:${REMOTE_DIR}/pt_dump.guest" ||
    stage_failed "the upload to ${HOST}" "${HOST_LOG}"

  # PageTables/Host/run.sh loads its own module and runs the augmentor; it
  # needs the guest to still be running, which it is — we are inside it.
  # No bar for the translation. Its output stops growing once the module has
  # written the raw table, and the augmentor then rewrites that file in place
  # for as long again -- so a size-driven bar parks near the end and sits
  # there, which is worse than no bar at all. The host script announces each
  # of its own phases, so those are shown instead.
  probe_translate() {
    tail -n 40 "${HOST_LOG}" 2> /dev/null |
      sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' |
      grep -oE '(\[\.\.\]|\[OK\]|•|✔) .*' | tail -1 |
      sed -e 's/^\(\[\.\.\]\|\[OK\]\|•\|✔\) *//' -e 's/\.\.\.$//' | cut -c1-52
  }
  PROBE_TEXT_CMD=probe_translate \
    run_logged "translating GPA -> HPA on ${HOST}" "${HOST_LOG}" \
      on_host "cd '${HOST_STAGE}' && ./PageTables/Host/run.sh '${REMOTE_DIR}/pt_dump.guest' \
               --output '${REMOTE_DIR}/pt_dump.host'" ||
    stage_failed "the host translation" "${HOST_LOG}"

  # Download: the total is now known exactly, from the host.
  probe_download() { local_size "${HOST_PT}"; }
  PROBE_CMD=probe_download PROBE_TOTAL="$(remote_size "${REMOTE_DIR}/pt_dump.host")" \
    run_logged "fetching the host page table" "${HOST_LOG}" \
      scp "${SSH_OPTS[@]}" -q "${HOST_USER}@${HOST}:${REMOTE_DIR}/pt_dump.host" "${HOST_PT}" ||
    stage_failed "the download from ${HOST}" "${HOST_LOG}"

  [[ -s "${HOST_PT}" ]] ||
    UI_EXIT_CODE=3 ui::die "the host page table came back empty"
  ui::ok "host page table  $(ui::relpath "${HOST_PT}" "${REPO_ROOT}") ($(ui::size_of "${HOST_PT}"))"
fi

# ------------------------------------------------------------------------------
#  Decode
#
#  Done here rather than inside the simulator. The simulator will decode a raw
#  capture on its own, but then the hours it spends in raw2trace are reported
#  under "Simulation", which is both wrong and impossible to read progress
#  from. Decoding as its own stage names the work and lets the simulator start
#  on a trace that is ready.
# ------------------------------------------------------------------------------
ui::step "Decode"

TRACE_SUBDIR="$(find "${OUTPUT_DIR}" -maxdepth 1 -name 'drmemtrace*' -type d 2> /dev/null |
  sort | head -1 || true)"
[[ -n "${TRACE_SUBDIR}" ]] ||
  UI_EXIT_CODE=3 ui::die "no drmemtrace directory in $(ui::relpath "${OUTPUT_DIR}" "${REPO_ROOT}")"

DECODE_ARGS=(--dir "${TRACE_SUBDIR}" --compact)
(( FORCE_DECODE )) && DECODE_ARGS+=(--force)

if ! "${REPO_ROOT}/Tracer/convert_trace.sh" "${DECODE_ARGS[@]}"; then
  ui::fail "decoding the trace failed"
  ui::result_banner fail "PIPELINE FAILED: ${WORKLOAD}"
  exit 3
fi

# ------------------------------------------------------------------------------
#  5/5 — Simulation
# ------------------------------------------------------------------------------
# Each machine is simulated from the same capture; only this stage is repeated.
for arch in "${ARCHES[@]}"; do
  ui::step "Simulation (${arch})"
  analysis="${REPO_ROOT}/Results/${WORKLOAD}/analysis_${arch}.txt"

  # A simulation over a full trace runs for hours, so a finished one is never
  # repeated by accident.
  if [[ -s "${analysis}" ]] && (( ! FORCE_SIM )); then
    ui::ok "already simulated  $(ui::relpath "${analysis}" "${REPO_ROOT}")"
    ui::note "re-run with --force sim to simulate again"
    continue
  fi
  if [[ -e "${analysis}" ]]; then
    ui::info "discarding the previous ${arch} result"
    rm -f "${analysis}" "${REPO_ROOT}/Results/${WORKLOAD}/sim_${arch}.log"
  fi

  ui::info "handing over to Simulator/run_${arch}.sh"
  ui::blank
  if ! "${REPO_ROOT}/Simulator/run_${arch}.sh" "${OUTPUT_DIR}"; then
    ui::fail "the ${arch} simulation failed"
    ui::result_banner fail "PIPELINE FAILED: ${WORKLOAD} (${arch})"
    exit 3
  fi
done

# ------------------------------------------------------------------------------
#  Done
# ------------------------------------------------------------------------------
ui::result_banner ok "PIPELINE COMPLETE: ${WORKLOAD} (${ARCHES[*]})"
ui::field "elapsed"  "$(ui::duration $(( SECONDS - RUN_START )))"
ui::field "trace"    "$(ui::relpath "${EXISTING_TRACE:-${OUTPUT_DIR}}" "${REPO_ROOT}")"
ui::field "guest PT" "$(ui::relpath "${GUEST_PT}" "${REPO_ROOT}")"
ui::field "host PT"  "$(ui::relpath "${HOST_PT}" "${REPO_ROOT}")"
for arch in "${ARCHES[@]}"; do
  ui::field "analysis ${arch}" "Results/${WORKLOAD}/analysis_${arch}.txt"
done
ui::blank

}
