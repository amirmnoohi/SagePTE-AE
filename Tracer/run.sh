#!/usr/bin/env bash
#
# ==============================================================================
#  SagePTE Artifact — Workload Tracer
# ==============================================================================
#
#  SYNOPSIS
#      run.sh <workload> [options]
#      run.sh --list
#
#  DESCRIPTION
#      Captures a memory-access trace of one benchmark under the bundled
#      DynamoRIO tracer. The benchmark is named, not spelled out: everything
#      specific to it lives in a declarative definition file,
#      Workloads/<workload>.sh, so adding a benchmark never means editing this
#      script. Run `run.sh --list` to see what is available and
#      Workloads/_template.sh for the definition format.
#
#  WHY RECORDING IS DELAYED
#      Tracing does not begin when the process starts. Every benchmark here
#      first builds its working set — Redis loads its dataset, GUPS touches its
#      whole table — and that setup phase is not what the paper measures. The
#      workload writes a readiness file when it is done; only then is recording
#      switched on. This has a second, essential consequence: the guest page
#      table is fully populated at that moment, so the trace and the page-table
#      snapshot taken by the dumper describe the same steady state.
#
#  HOW THE TRACER IS TOLD TO START
#      The DynamoRIO client polls a small "enabler" file and reports back
#      through it. The protocol has three states:
#
#          0        keep running, do not record yet   (written here)
#          1        begin recording now               (written here)
#          <pid>    acknowledgement: recording, and this is the traced PID
#                                                     (written by the client)
#
#      That protocol is an implementation detail and it stops at this script.
#      What the rest of the artifact consumes is a documented state file:
#
#          <output-dir>/meta/trace.state   KEY=VALUE, see write_state()
#
#      PageTables/Guest/run.sh reads it to learn which process to snapshot.
#      Nothing downstream needs to know that an enabler file exists.
#
#  SCOPE — THIS SCRIPT ONLY RECORDS A TRACE
#      Capturing the guest page table is a separate stage with its own script,
#      PageTables/Guest/run.sh. The two stages must nevertheless *overlap in
#      time*: /proc exposes a process's page table only while that process is
#      alive, so once this run ends its page table is gone for good. This
#      script therefore prints the dumper command the moment recording starts,
#      and the dumper waits for a run to reach that point — so it may be
#      started first, in a second shell, and will fire by itself.
#
#  OUTPUT
#      <output-dir>/drmemtrace.dir/    the offline trace
#      <output-dir>/pt_dump            guest page table (written by run.sh)
#      <output-dir>/meta/              state, logs and raw intermediates:
#                     trace.state        run state (see above)
#                     tracer.log         DynamoRIO + benchmark output
#                     enabler.txt        tracer handshake file
#
#  EXIT CODES
#      0    trace completed successfully
#      1    usage error, or a faulty/missing workload definition
#      2    environment error (tracer not built, prerequisite missing)
#      3    the workload or the tracer failed
#      130  interrupted (Ctrl-C)
#
#  SEE ALSO
#      PageTables/Guest/run.sh   captures the page table of a running trace
#      Workloads/_template.sh      the workload definition contract
#
# ==============================================================================

set -euo pipefail

readonly VERSION="1.0.0"


# ------------------------------------------------------------------------------
# Paths. Everything is derived from this script's own location so the artifact
# can be unpacked anywhere and still work.
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
readonly REPO_ROOT
# How this script names itself in help: every component exposes a run.sh,
# so the path relative to the artifact root is what disambiguates it.
PROG="${SCRIPT_DIR#"${REPO_ROOT}/"}/$(basename "${BASH_SOURCE[0]:-$0}")"
readonly PROG
readonly WORKLOAD_DIR="${REPO_ROOT}/Workloads"
readonly BIN_DIR="${WORKLOAD_DIR}/bin"
readonly DRRUN="${SCRIPT_DIR}/build/bin64/drrun"
readonly DUMPER="${REPO_ROOT}/PageTables/Guest/run.sh"

# shellcheck source=../Lib/ui.sh
source "${REPO_ROOT}/Lib/ui.sh"

# ------------------------------------------------------------------------------
# Tunables. Each is overridable from the command line; see usage().
# ------------------------------------------------------------------------------
MAX_REFS=2000000000   # -exit_after_tracing: stop the run after this many refs
ACK_TIMEOUT=120       # seconds to wait for the client to confirm recording
OUTPUT_DIR=""         # default: Data/<workload>
FORCE=0               # 1 = overwrite an existing output directory
VERBOSE=0             # 1 = mirror the tracer's own output to the terminal
PAUSE=1               # 1 = hold the workload while the page table is captured

# Populated as the run progresses; referenced by the trap handler.
WORKLOAD=""
TRACER_PID=""
APP_PID=""
STATE_FILE=""
RUN_START=0
WORKLOAD_STOPPED=0    # 1 while the workload is held by SIGSTOP

# ==============================================================================
#  Usage and discovery
# ==============================================================================

#######################################
# Print the help text.
# Outputs:
#   Usage information on stdout.
#######################################
usage() {
  cat <<EOF
${C_BOLD}SagePTE workload tracer${C_RESET} v${VERSION}

${C_BOLD}USAGE${C_RESET}
  ${PROG} <workload> [options]
  ${PROG} --list

${C_BOLD}OPTIONS${C_RESET}
  -o, --output DIR       output directory            (default: Data/<workload>)
  -n, --max-refs N       stop after N references     (default: ${MAX_REFS})
  -t, --ack-timeout SEC  wait SEC for recording to start (default: ${ACK_TIMEOUT})
  -f, --force            overwrite an existing output directory
  -v, --verbose          mirror the tracer's own output to the terminal
      --no-pause         do not hold the workload for the page-table capture
  -l, --list             list the available workloads
      --no-color         disable coloured output
  -h, --help             show this message
  -V, --version          show the version

${C_BOLD}EXAMPLES${C_RESET}
  ${PROG} debug                 smoke-test the pipeline (16 GB GUPS)
  ${PROG} redis                 trace Redis (capture its page table separately)
  ${PROG} gups -o /mnt/scratch  write the trace somewhere else
EOF
}

#######################################
# List the workload definitions found in Workloads/, with their descriptions.
# Definitions whose name begins with "_" are internal (templates, scratch
# files) and are omitted.
# Globals:
#   Reads WORKLOAD_DIR.
# Outputs:
#   A formatted table on stdout.
#######################################
list_workloads() {
  ui::banner "Available workloads" "defined in $(ui::relpath "${WORKLOAD_DIR}" "${REPO_ROOT}")/<name>.sh"
  local file name desc found=0
  for file in "${WORKLOAD_DIR}"/*.sh; do
    [[ -e "${file}" ]] || continue
    name="$(basename "${file}" .sh)"
    [[ "${name}" == _* ]] && continue
    desc="$(sed -n 's/^DESCRIPTION="\(.*\)"$/\1/p' "${file}" | head -1 || true)"
    printf '  %s%-12s%s %s%s%s\n' \
      "${C_BOLD}" "${name}" "${C_RESET}" "${C_DIM}" "${desc}" "${C_RESET}"
    found=1
  done
  (( found )) || ui::warn "no workload definitions found in ${WORKLOAD_DIR}"
  ui::blank
  ui::note "run one with:  ${PROG} <name>"
  ui::blank
}

# ==============================================================================
#  Run state
# ==============================================================================

#######################################
# Publish the run state. This is the artifact's contract between the tracer and
# the page-table dumper, so it is written atomically (temp file + rename): a
# concurrent reader either sees the previous state or the new one, never a
# half-written file.
# Globals:
#   Reads WORKLOAD, OUTPUT_DIR, STATE_FILE, APP_BIN.
# Arguments:
#   $1 — status: starting | tracing | done | failed | interrupted
#   $2 — traced PID, if known.
#   $3 — trace directory, if it exists yet.
# Outputs:
#   Writes ${STATE_FILE}.
#######################################
write_state() {
  local status="$1" pid="${2:-}" trace_dir="${3:-}" tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  {
    echo "# SagePTE trace state — written by Tracer/run.sh, read by run.sh"
    echo "WORKLOAD=${WORKLOAD}"
    echo "STATUS=${status}"
    echo "APP_PID=${pid}"
    echo "OUTPUT_DIR=${OUTPUT_DIR}"
    echo "TRACE_DIR=${trace_dir}"
    echo "BINARY=${APP_BIN:-}"
    echo "UPDATED_AT=$(date -Is)"
  } > "${tmp}"
  # mktemp creates the file 0600; the dumper may run as another user.
  chmod 644 "${tmp}"
  mv -f "${tmp}" "${STATE_FILE}"
}

#######################################
# Locate the trace directory DynamoRIO created inside the output directory.
# Globals:
#   Reads OUTPUT_DIR.
# Outputs:
#   The directory path on stdout, or nothing if it does not exist yet.
#######################################
find_trace_dir() {
  # "|| true": head closing the pipe early can surface as a failure, and under
  # `set -o pipefail` that would abort a run that has actually succeeded.
  find "${OUTPUT_DIR}" -maxdepth 1 -name 'drmemtrace*' -type d 2>/dev/null |
    sort | head -1 || true
}

#######################################
# Give the trace directory a stable, readable name.
#
# DynamoRIO names it drmemtrace.<app>.<pid>.<seq>.dir, which embeds a PID and a
# sequence number: unpredictable, and different for every run of the same
# workload. Renaming it to drmemtrace.dir keeps paths stable across runs and
# quotable in documentation, while still matching the "drmemtrace*" glob the
# simulator's run scripts use to discover it.
#
# Safe at this point: the tracer has exited, so nothing holds the directory.
# Globals:
#   Reads OUTPUT_DIR.
# Outputs:
#   Renames the directory in place; prints nothing on success.
#######################################
tidy_trace_dir() {
  local current tidy="${OUTPUT_DIR}/drmemtrace.dir"
  current="$(find_trace_dir)"
  [[ -n "${current}" ]] || return 0
  [[ "${current}" == "${tidy}" ]] && return 0
  # Never clobber an existing directory; leave the DR name if one is there.
  [[ -e "${tidy}" ]] && return 0
  mv -T "${current}" "${tidy}" 2>/dev/null || return 0
}

# How many consecutive idle samples (one per second) must agree before a run is
# treated as finished-but-parked. Generous on purpose: it is only ever paid once
# at the end of a capture that has already taken hours, and the cost of being
# too eager is a truncated trace.
readonly PARKED_GRACE=30

#######################################
# A signature of the traced process, non-empty only while it looks finished.
#
# -exit_after_tracing terminates the application once the reference limit is
# reached, but it terminates the thread that hit the limit. Threads parked on a
# futex when that happens are never woken and never exit, so the thread group
# never empties: the leader stays in Z state, the PID remains allocated, and a
# loop watching for that PID to disappear is waiting for something that cannot
# happen. Redis parks three background threads at startup and hangs this way on
# every capture.
#
# A zombie leader is not enough to act on by itself, because a program may call
# pthread_exit() from main and leave genuine workers running behind it. So the
# signature also carries the total CPU consumed by every thread and the size of
# the capture; the caller compares consecutive samples and only acts once
# neither has moved for PARKED_GRACE seconds, which a working thread would
# disturb.
# Arguments:
#   $1 — pid of the traced process.
# Outputs:
#   "<cpu-ticks> <capture-bytes>" when the leader has exited, else nothing.
#######################################
parked_signature() {
  local pid="$1" rest cpu=0 bytes=0 dir tstat
  local -a f

  [[ -r "/proc/${pid}/stat" ]] || return 0
  # comm sits in parentheses and may itself contain spaces, so everything up to
  # the last ')' is discarded and the state becomes the first field.
  rest="$(sed 's/^.*) //' "/proc/${pid}/stat" 2>/dev/null)" || return 0
  [[ "${rest%% *}" == Z ]] || return 0

  for tstat in "/proc/${pid}/task/"*/stat; do
    [[ -r "${tstat}" ]] || continue
    rest="$(sed 's/^.*) //' "${tstat}" 2>/dev/null)" || continue
    read -r -a f <<< "${rest}"
    # utime and stime are fields 14 and 15 of the original line.
    cpu=$(( cpu + ${f[11]:-0} + ${f[12]:-0} ))
  done

  dir="$(find_trace_dir)"
  if [[ -n "${dir}" ]]; then
    bytes="$(du -sb "${dir}" 2>/dev/null | cut -f1)" || bytes=0
  fi

  printf '%s %s' "${cpu}" "${bytes:-0}"
}

# Anchor for the initialisation ETA: the first sample seen, so the rate is
# measured from real progress rather than from a start that included process
# launch.
_READY_HAVE=0
_READY_T0=0
_READY_V0=0
_READY_LAST=0

#######################################
# The label for the readiness progress line, with a percentage and an ETA when
# the workload can say how far it has got.
#
# Initialisation is the longest silent stretch of a capture — Redis spends an
# hour and three quarters inserting 512 million keys before a single reference
# is recorded — and an elapsed counter on its own is indistinguishable from a
# hang. A definition may override ready_progress() to print
#
#     <done> <total> [unit...]
#
# in any consistent unit, and this turns consecutive samples into a percentage
# and a projected finish. The rate is averaged over the whole wait rather than
# taken between adjacent samples, which would jitter with every log flush.
# The result is left in READY_LABEL rather than written to stdout, because the
# anchor has to survive between calls: read through $(...) the function would
# run in a subshell, every call would re-anchor on its own reading, and the
# elapsed-since-anchor would be zero forever, so the ETA branch could never be
# taken.
# Globals:
#   Reads and writes _READY_HAVE, _READY_T0, _READY_V0, _READY_LAST;
#   sets READY_LABEL.
#######################################
readiness_label() {
  local done total unit elapsed remain

  READY_LABEL="waiting for the workload to finish initialising"

  read -r done total unit <<< "$(ready_progress 2>/dev/null || true)"
  [[ "${done}" =~ ^[0-9]+$ && "${total}" =~ ^[0-9]+$ ]] || return 0
  (( total > 0 && done <= total )) || return 0

  # First reading, or a restart that moved the counter backwards.
  # A separate flag rather than a zero sentinel on _READY_T0, which a run that
  # reached this stage within a second of starting would collide with.
  # Compared against the previous reading, not against the anchor: a counter
  # that restarts is still above an anchor of zero, and the rate computed
  # across the restart would be nonsense.
  if (( ! _READY_HAVE || done < _READY_LAST )); then
    _READY_HAVE=1
    _READY_T0=${SECONDS}
    _READY_V0=${done}
  fi
  _READY_LAST=${done}

  elapsed=$(( SECONDS - _READY_T0 ))
  if (( done > _READY_V0 && elapsed > 0 )); then
    remain=$(( (total - done) * elapsed / (done - _READY_V0) ))
    printf -v READY_LABEL 'building the working set  %s/%s%s  %s%%  ETA %s' \
      "${done}" "${total}" "${unit:+ ${unit}}" \
      "$(( done * 100 / total ))" "$(ui::duration "${remain}")"
  else
    printf -v READY_LABEL 'building the working set  %s/%s%s  %s%%' \
      "${done}" "${total}" "${unit:+ ${unit}}" "$(( done * 100 / total ))"
  fi
}

# ==============================================================================
#  Environment
# ==============================================================================

#######################################
# Disable transparent huge pages, so a 4 KB-page trace really uses 4 KB pages.
# Not fatal when unavailable: THP control needs root, but a non-root user can
# still capture a (THP-backed) trace, and saying so is more useful than
# refusing to run.
# Outputs:
#   One status line.
#######################################
disable_thp() {
  local file
  for file in /sys/kernel/mm/transparent_hugepage/enabled \
              /sys/kernel/mm/transparent_hugepage/defrag; do
    [[ -w "${file}" ]] && echo never > "${file}" 2>/dev/null
  done

  local current
  current="$(sed -n 's/.*\[\(.*\)\].*/\1/p' \
    /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)"
  if [[ "${current}" == "never" ]]; then
    ui::ok "transparent huge pages disabled"
  else
    ui::warn "could not disable THP (currently '${current:-unknown}') — re-run as root for 4 KB traces"
  fi
}

#######################################
# Hold the workload while the guest page table is captured in another terminal.
#
# The two stages have to overlap: /proc exposes a page table only while its
# process lives, so the snapshot cannot be taken after this run. Simply printing
# a reminder is not enough either — a short workload finishes long before anyone
# can type the command. The workload is therefore SIGSTOPped, which freezes it
# without disturbing its address space (the page table stays fully readable),
# and resumed once the capture is confirmed. The trace is a sequence of memory
# references, so the pause costs nothing but wall-clock time; it also pins the
# snapshot to an exact point in the trace.
#
# Skipped when stdin is not a terminal (scripted runs) or with --no-pause.
# Globals:
#   Reads APP_PID, WORKLOAD, DUMPER, OUTPUT_DIR, PAUSE.
#   Sets WORKLOAD_STOPPED so the interrupt handler can resume the process.
#######################################
pause_for_page_table() {
  if (( ! PAUSE )); then
    ui::blank
    ui::note "capture the guest page table while this run is going, in another shell:"
    ui::command "$(ui::relpath "${DUMPER}" "${REPO_ROOT}") ${WORKLOAD} --output ${OUTPUT_DIR}"
    ui::blank
    return 0
  fi

  if [[ ! -t 0 ]]; then
    ui::warn "stdin is not a terminal — not pausing for the page-table capture"
    ui::note "capture it concurrently instead:"
    ui::command "$(ui::relpath "${DUMPER}" "${REPO_ROOT}") ${WORKLOAD} --output ${OUTPUT_DIR}"
    return 0
  fi

  # Freeze the workload so it cannot finish while the snapshot is being taken.
  if kill -STOP "${APP_PID}" 2>/dev/null; then
    WORKLOAD_STOPPED=1
    ui::ok "workload paused ${C_DIM}(held so its page table can be captured)${C_RESET}"
  else
    ui::warn "could not pause the workload; capture the page table quickly"
  fi

  ui::blank
  printf '  %s%s  Capture the guest page table now%s\n' \
    "${C_BOLD}${C_YELLOW}" "${G_ARROW}" "${C_RESET}"
  ui::blank
  printf '     %sIn another terminal, run:%s\n' "${C_DIM}" "${C_RESET}"
  ui::command "$(ui::relpath "${DUMPER}" "${REPO_ROOT}") ${WORKLOAD} --output ${OUTPUT_DIR}"
  ui::blank
  printf '  %sPress ENTER once it has finished (Ctrl-C to abort)%s ' \
    "${C_BOLD}" "${C_RESET}"
  read -r || true
  ui::blank

  # Report what actually landed, rather than trusting the keystroke.
  if [[ -f "${OUTPUT_DIR}/pt_dump.guest" ]]; then
    ui::ok "guest page table present  $(ui::relpath "${OUTPUT_DIR}/pt_dump.guest" "${REPO_ROOT}")"
  else
    ui::warn "no page table at $(ui::relpath "${OUTPUT_DIR}/pt_dump.guest" "${REPO_ROOT}")"
    ui::warn "continuing, but this trace cannot be simulated without one"
  fi

  if (( WORKLOAD_STOPPED )); then
    kill -CONT "${APP_PID}" 2>/dev/null || true
    WORKLOAD_STOPPED=0
    ui::ok "workload resumed"
  fi
}

#######################################
# Terminate the run cleanly on Ctrl-C. A benchmark here can hold hundreds of
# gigabytes, so leaving it orphaned is not acceptable: take the tracer and its
# children down, and record that the run was interrupted.
# Globals:
#   Reads TRACER_PID, APP_PID.
# Returns:
#   Never; exits 130.
#######################################
on_interrupt() {
  ui::wait_abort
  # A SIGSTOPped process ignores SIGINT/SIGTERM until it runs again, so resume
  # it first — otherwise Ctrl-C would leave a frozen, un-killable workload.
  if (( WORKLOAD_STOPPED )) && [[ -n "${APP_PID}" ]]; then
    kill -CONT "${APP_PID}" 2>/dev/null || true
    WORKLOAD_STOPPED=0
  fi
  if [[ -n "${TRACER_PID}" ]] && kill -0 "${TRACER_PID}" 2>/dev/null; then
    ui::warn "interrupted — stopping the tracer (pid ${TRACER_PID})"
    pkill -INT -P "${TRACER_PID}" 2>/dev/null || true
    kill -INT "${TRACER_PID}" 2>/dev/null || true
  fi
  [[ -n "${STATE_FILE}" ]] && write_state "interrupted" "${APP_PID}" "$(find_trace_dir)"
  ui::result_banner fail "TRACE INTERRUPTED"
  exit 130
}

# ==============================================================================
#  Argument parsing
# ==============================================================================

ui::init

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--list)        ui::init; list_workloads; exit 0 ;;
    -h|--help)        usage; exit 0 ;;
    -V|--version)     echo "run.sh ${VERSION}"; exit 0 ;;
    --no-color)       ui::set_color off; shift ;;
    -o|--output)      OUTPUT_DIR="${2:?--output requires a directory}"; shift 2 ;;
    -n|--max-refs)    MAX_REFS="${2:?--max-refs requires a number}"; shift 2 ;;
    -t|--ack-timeout) ACK_TIMEOUT="${2:?--ack-timeout requires seconds}"; shift 2 ;;
    -f|--force)       FORCE=1; shift ;;
    -v|--verbose)     VERBOSE=1; shift ;;
    --no-pause)       PAUSE=0; shift ;;
    -*)               UI_EXIT_CODE=1 ui::die "unknown option: $1" "try '${PROG} --help'" ;;
    *)
      [[ -z "${WORKLOAD}" ]] ||
        UI_EXIT_CODE=1 ui::die "only one workload may be given" \
          "got '${WORKLOAD}' and '$1'"
      WORKLOAD="$1"; shift ;;
  esac
done

if [[ -z "${WORKLOAD}" ]]; then
  usage >&2
  ui::blank
  list_workloads >&2
  exit 1
fi

[[ "${MAX_REFS}" =~ ^[0-9]+$ ]] ||
  UI_EXIT_CODE=1 ui::die "--max-refs must be a positive integer (got '${MAX_REFS}')"
[[ "${ACK_TIMEOUT}" =~ ^[0-9]+$ ]] ||
  UI_EXIT_CODE=1 ui::die "--ack-timeout must be a positive integer (got '${ACK_TIMEOUT}')"

RUN_START=${SECONDS}
ui::set_steps 7

# ==============================================================================
#  1/7 — Workload definition
# ==============================================================================

ui::banner "SagePTE ${G_DOT} Workload Tracer" "memory-trace capture for nested-paging simulation"
ui::step "Workload definition"

readonly WORKLOAD_FILE="${WORKLOAD_DIR}/${WORKLOAD}.sh"
if [[ ! -f "${WORKLOAD_FILE}" ]]; then
  ui::fail "no such workload: ${WORKLOAD}"
  ui::blank
  list_workloads >&2
  exit 1
fi

# Defaults for everything a definition may set. Declaring them here means a
# definition only states what differs, and a typo cannot leak a value from the
# caller's environment. See Workloads/_template.sh for the full contract.
DESCRIPTION=""
BINARY=""
ARGS=""
ARGV=()
READY_FILE=""
READY_DELAY=3
REQUIRES=""
pre_run()    { :; }
post_start() { :; }
post_run()   { :; }
# Overridden by definitions that can report how far initialisation has got. See
# readiness_label() for the contract and Workloads/redis.sh for an example.
ready_progress() { :; }

# shellcheck source=/dev/null
source "${WORKLOAD_FILE}"

[[ -n "${BINARY}" ]] &&
  ui::ok "loaded $(ui::relpath "${WORKLOAD_FILE}" "${REPO_ROOT}")" ||
  UI_EXIT_CODE=1 ui::die "${WORKLOAD}.sh does not set BINARY" \
    "see Workloads/_template.sh for the definition format"

# A bare name resolves inside Workloads/bin; an absolute path is taken as given,
# which is how system binaries such as /usr/bin/memcached are supported.
case "${BINARY}" in
  /*) APP_BIN="${BINARY}" ;;
  *)  APP_BIN="${BIN_DIR}/${BINARY}" ;;
esac
readonly APP_BIN

# ARGV (an array) wins over ARGS (a string), so a definition can pass arguments
# containing spaces; ARGS stays the convenient form for the common case.
if [[ ${#ARGV[@]} -eq 0 && -n "${ARGS}" ]]; then
  read -r -a ARGV <<< "${ARGS}"
fi

ui::field "Workload" "${C_BOLD}${WORKLOAD}${C_RESET}"
[[ -n "${DESCRIPTION}" ]] && ui::field_cont "${DESCRIPTION}"
ui::field "Command" "$(basename "${APP_BIN}") ${ARGV[*]:-}"
ui::field "Ready signal" "${READY_FILE:-<none — waiting ${READY_DELAY}s>}"

# ==============================================================================
#  2/7 — Environment
# ==============================================================================

ui::step "Environment"

[[ -x "${DRRUN}" ]] ||
  UI_EXIT_CODE=2 ui::die "the tracer is not built: ${DRRUN} is missing" \
    "build it with:  cd ${SCRIPT_DIR} && ./build.sh"
ui::ok "tracer  $(ui::relpath "${DRRUN}" "${REPO_ROOT}")"

# A definition naming an absolute path wants a binary from the system, which
# no amount of building here will produce; saying "run make" sends the reader
# somewhere that cannot help.
if [[ ! -x "${APP_BIN}" ]]; then
  case "${BINARY}" in
    /*) UI_EXIT_CODE=2 ui::die "workload binary not found or not executable:" \
          "${APP_BIN}" \
          "${WORKLOAD} runs a system binary, not one this repository builds" \
          "install it with the package manager, then run again" ;;
    *)  UI_EXIT_CODE=2 ui::die "workload binary not found or not executable:" \
          "${APP_BIN}" \
          "build the benchmarks with:  cd ${WORKLOAD_DIR} && make" ;;
  esac
fi
ui::ok "binary  $(ui::relpath "${APP_BIN}" "${REPO_ROOT}")"

# Datasets and helper programs the workload cannot run without. Checking here
# turns a confusing mid-run failure into an immediate, actionable message.
for requirement in ${REQUIRES}; do
  [[ -e "${requirement}" ]] ||
    UI_EXIT_CODE=2 ui::die "${WORKLOAD} requires a file that does not exist:" \
      "${requirement}" \
      "see $(ui::relpath "${WORKLOAD_FILE}" "${REPO_ROOT}") for how to obtain it"
done
[[ -n "${REQUIRES}" ]] && ui::ok "prerequisites present"

disable_thp

OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/Data/${WORKLOAD}}"
if [[ -d "${OUTPUT_DIR}" ]]; then
  if (( FORCE )); then
    ui::warn "removing the existing output directory (--force)"
    rm -rf "${OUTPUT_DIR}"
  else
    UI_EXIT_CODE=2 ui::die "the output directory already exists:" \
      "${OUTPUT_DIR}" \
      "" \
      "re-run with --force to overwrite it, or choose another with --output DIR."
  fi
fi
mkdir -p "${OUTPUT_DIR}"
ui::ok "output  $(ui::relpath "${OUTPUT_DIR}" "${REPO_ROOT}")"

# Layout of an output directory. Only three entries are simulator inputs; every
# log, handshake file and intermediate lives under meta/ so that what matters is
# obvious at a glance:
#
#     Data/<workload>/
#     ├── drmemtrace.dir/   memory trace
#     ├── pt_dump.guest     guest page table  (GVA->GPA)
#     ├── pt_dump.host      host page table   (GPA->HPA)
#     └── meta/             state, logs, raw intermediates
#
readonly META_DIR="${OUTPUT_DIR}/meta"
mkdir -p "${META_DIR}"

readonly ENABLER_FILE="${META_DIR}/enabler.txt"  # per-run: parallel runs cannot clash
readonly TRACER_LOG="${META_DIR}/tracer.log"     # DynamoRIO + benchmark output
STATE_FILE="${META_DIR}/trace.state"
readonly STATE_FILE

trap on_interrupt INT TERM

# ==============================================================================
#  3/7 — Preparation
# ==============================================================================

ui::step "Preparation"

write_state "starting"

pre_run
ui::ok "workload pre-run hook completed"

# 0 = "running, but do not record yet". The client polls this file.
echo 0 > "${ENABLER_FILE}"

# Clear the readiness signal *before* the workload starts, so a file left over
# from an earlier run cannot make us start recording immediately — which would
# capture the initialisation phase we are trying to skip.
if [[ -n "${READY_FILE}" ]]; then
  mkdir -p "$(dirname "${READY_FILE}")"
  : > "${READY_FILE}"
  ui::ok "readiness signal reset"
fi

# ==============================================================================
#  4/7 — Launch
# ==============================================================================

ui::step "Launch"

# DynamoRIO and the benchmark are both chatty, and their output is asynchronous:
# left on the terminal it interleaves with — and visually destroys — the progress
# display, mid-word. It is captured to a log instead, which is also what you want
# afterwards for diagnosis. --verbose mirrors it to the terminal for debugging.
if (( VERBOSE )); then
  "${DRRUN}" -t drcachesim \
             -offline \
             -outdir "${OUTPUT_DIR}" \
             -verbose 1 \
             -enabler_filename "${ENABLER_FILE}" \
             -trace_after_instrs 1 \
             -exit_after_tracing "${MAX_REFS}" \
             -- "${APP_BIN}" ${ARGV[@]+"${ARGV[@]}"} > >(tee "${TRACER_LOG}") 2>&1 &
else
  "${DRRUN}" -t drcachesim \
             -offline \
             -outdir "${OUTPUT_DIR}" \
             -verbose 1 \
             -enabler_filename "${ENABLER_FILE}" \
             -trace_after_instrs 1 \
             -exit_after_tracing "${MAX_REFS}" \
             -- "${APP_BIN}" ${ARGV[@]+"${ARGV[@]}"} > "${TRACER_LOG}" 2>&1 &
fi
TRACER_PID=$!

ui::ok "tracer started ${C_DIM}(pid ${TRACER_PID}, recording off)${C_RESET}"
ui::ok "tracer output  $(ui::relpath "${TRACER_LOG}" "${REPO_ROOT}")"

# Hook for server-style workloads that need an external load generator to reach
# a steady state; it must start now, because the readiness signal it produces
# is what gates recording below.
post_start

# ==============================================================================
#  5/7 — Readiness
# ==============================================================================

ui::step "Readiness"

# --- wait until the workload has finished building its working set ------------
if [[ -n "${READY_FILE}" ]]; then
  ui::wait_begin "waiting for the workload to finish initialising"
  while kill -0 "${TRACER_PID}" 2>/dev/null && [[ ! -s "${READY_FILE}" ]]; do
    sleep 1
    # readiness_label() sets READY_LABEL in this shell; see the note there.
    readiness_label
    # Published so the pipeline driver can show the same figure; it runs in a
    # different process and cannot call the workload's hook itself.
    printf '%s\n' "${READY_LABEL}" > "${META_DIR}/progress.txt" 2>/dev/null || true
    ui::wait_tick "${READY_LABEL}"
  done

  if ! kill -0 "${TRACER_PID}" 2>/dev/null; then
    ui::wait_abort
    wait "${TRACER_PID}" 2>/dev/null || true
    write_state "failed"
    UI_EXIT_CODE=3 ui::die "the workload exited before it signalled readiness" \
      "$(tail -n 3 "${TRACER_LOG}" 2>/dev/null || true)" \
      "" \
      "full output: $(ui::relpath "${TRACER_LOG}" "${REPO_ROOT}")" \
      "(a benchmark that cannot allocate its working set is the usual cause)"
  fi
  rm -f "${META_DIR}/progress.txt" 2>/dev/null || true
  ui::wait_end "workload ready"
else
  ui::wait_begin "no readiness signal defined — waiting ${READY_DELAY}s"
  sleep "${READY_DELAY}"
  ui::wait_end "proceeding"
fi

# ==============================================================================
#  6/7 — Recording
# ==============================================================================

ui::step "Recording"

# --- switch recording on ------------------------------------------------------
echo 1 > "${ENABLER_FILE}"
ui::ok "recording enabled"

# The client acknowledges by writing the traced PID into the same file. Anything
# that is neither 0 nor 1 is that acknowledgement.
ui::wait_begin "waiting for the tracer to confirm"
ack_deadline=$(( SECONDS + ACK_TIMEOUT ))
while kill -0 "${TRACER_PID}" 2>/dev/null; do
  enabler_value="$(tr -d '[:space:]' < "${ENABLER_FILE}" 2>/dev/null || true)"
  case "${enabler_value}" in
    ''|0|1) ;;
    *)      APP_PID="${enabler_value}"; break ;;
  esac
  if (( SECONDS >= ack_deadline )); then
    ui::wait_abort
    ui::warn "the tracer did not confirm within ${ACK_TIMEOUT}s; continuing without a PID"
    break
  fi
  sleep 0.2
  ui::wait_tick
done

TRACE_DIR="$(find_trace_dir)"

if [[ -n "${APP_PID}" ]]; then
  ui::wait_end "recording — traced pid ${C_BOLD}${APP_PID}${C_RESET}"
  write_state "tracing" "${APP_PID}" "${TRACE_DIR}"

  # --- optional page-table capture --------------------------------------------
  # The snapshot has to be taken now, while the process is alive and its page
  # table is fully populated; it cannot be recovered after the run.
  # Hand over to the guest page-table stage. See pause_for_page_table().
  pause_for_page_table
else
  ui::wait_abort
  ui::warn "no traced PID was reported — the page table cannot be dumped for this run"
  write_state "tracing" "" "${TRACE_DIR}"
fi

# ==============================================================================
#  7/7 — Execution
# ==============================================================================

ui::step "Execution"

ui::wait_begin "tracing (stops after $(ui::number "${MAX_REFS}") references)"

# Set when the run had to be finished off by hand; see parked_signature().
reaped_parked=0
parked_samples=0
parked_prev=""

while kill -0 "${TRACER_PID}" 2>/dev/null; do
  sleep 1
  ui::wait_tick

  parked_now="$(parked_signature "${TRACER_PID}")"
  if [[ -z "${parked_now}" ]]; then
    # Still running normally, which is the case on every pass of a healthy run.
    parked_samples=0
    parked_prev=""
    continue
  fi

  if [[ "${parked_now}" == "${parked_prev}" ]]; then
    parked_samples=$(( parked_samples + 1 ))
  else
    parked_samples=0
    parked_prev="${parked_now}"
  fi
  (( parked_samples >= PARKED_GRACE )) || continue

  # Nothing has moved for PARKED_GRACE seconds and the leader is gone: the
  # trace is complete and only parked threads remain. SIGKILL empties the
  # thread group so the PID can be reaped and the pipeline can go on.
  kill -KILL "${TRACER_PID}" 2>/dev/null || true
  reaped_parked=1
  break
done

# The child has exited; `wait` now returns its status immediately.
tracer_status=0
wait "${TRACER_PID}" || tracer_status=$?
TRACER_PID=""
trap - INT TERM

if (( reaped_parked )); then
  # The SIGKILL above is the reason for the status, and it was sent after the
  # capture was complete, so it does not make the run a failure.
  tracer_status=0
  ui::wait_end "workload finished"
  ui::note "threads left parked after the reference limit were reaped; the trace is complete"
else
  ui::wait_end "workload finished"
fi

post_run

# The tracer has exited: give its output directory a stable name before the
# summary quotes the path.
tidy_trace_dir
TRACE_DIR="$(find_trace_dir)"
if (( tracer_status == 0 )); then
  write_state "done" "${APP_PID}" "${TRACE_DIR}"
else
  write_state "failed" "${APP_PID}" "${TRACE_DIR}"
fi

# ==============================================================================
#  Summary
# ==============================================================================

run_elapsed=$(( SECONDS - RUN_START ))

if (( tracer_status == 0 )); then
  ui::result_banner ok "TRACE COMPLETE ${G_DOT} ${WORKLOAD}"
else
  ui::result_banner fail "TRACE FAILED ${G_DOT} ${WORKLOAD} (exit ${tracer_status})"
fi

if [[ -n "${TRACE_DIR}" ]]; then
  ui::field "Trace" "$(ui::relpath "${TRACE_DIR}" "${REPO_ROOT}")"
  ui::field "Trace size" "$(ui::size_of "${TRACE_DIR}")"
else
  ui::field "Trace" "<none produced>"
fi
ui::field "Traced pid" "${APP_PID:-<not reported>}"
ui::field "Duration" "$(ui::duration "${run_elapsed}")"
ui::field "Tracer log" "$(ui::relpath "${TRACER_LOG}" "${REPO_ROOT}")"

if (( tracer_status != 0 )); then
  ui::blank
  ui::warn "last lines of $(ui::relpath "${TRACER_LOG}" "${REPO_ROOT}"):"
  tail -n 10 "${TRACER_LOG}" 2>/dev/null | sed 's/^/     /' >&2 || true
fi

#######################################
# Print the remaining stages of the capture pipeline, marking the guest
# page-table stage as done or outstanding depending on what this run produced.
#
# Simulating needs three inputs: the trace (produced here), the guest page
# table (GVA->GPA, captured in the guest) and the host page table (GPA->HPA,
# produced on the KVM host). The two page tables are separate stages with their
# own scripts, so the run ends by spelling out what is left.
# Globals:
#   Reads OUTPUT_DIR, WORKLOAD, REPO_ROOT, DUMPER.
#######################################
#######################################
# Render one line of the pipeline overview.
# Arguments:
#   $1 — state: "done" | "todo"
#   $2 — step number; $3 — description; $4 — trailing detail (optional).
#######################################
print_stage() {
  local state="$1" number="$2" text="$3" detail="${4:-}"
  if [[ "${state}" == done ]]; then
    printf '  %s%s%s  %s%s%s  %s  %s%s%s\n' \
      "${C_GREEN}" "${G_OK}" "${C_RESET}" "${C_DIM}" "${number}" "${C_RESET}" \
      "${text}" "${C_DIM}" "${detail}" "${C_RESET}"
  else
    printf '  %s%s%s  %s%s%s  %s%s\n' \
      "${C_DIM}" "${G_DOT}" "${C_RESET}" "${C_BOLD}" "${number}" "${C_RESET}" \
      "${text}" "${detail:+  ${C_DIM}${detail}${C_RESET}}"
  fi
}

#######################################
# Print the capture pipeline: what this run produced, and what still has to
# happen before the workload can be simulated.
#
# Simulating needs three inputs — the memory trace (produced here), the guest
# page table (GVA->GPA, captured in the guest) and the host page table
# (GPA->HPA, produced on the KVM host). Each is its own stage with its own
# script, so the run ends by showing the whole chain with the completed parts
# ticked off.
# Globals:
#   Reads OUTPUT_DIR, WORKLOAD, REPO_ROOT, DUMPER, TRACE_DIR.
#######################################
print_next_steps() {
  local out_rel; out_rel="$(ui::relpath "${OUTPUT_DIR}" "${REPO_ROOT}")"
  local dump_rel; dump_rel="$(ui::relpath "${DUMPER}" "${REPO_ROOT}")"

  ui::blank
  ui::rule
  ui::blank
  printf '  %sCapture pipeline%s\n' "${C_BOLD}" "${C_RESET}"
  ui::blank

  # 1 — the memory trace: this run's own product.
  print_stage done 1 "memory trace" \
    "$(ui::relpath "${TRACE_DIR}" "${REPO_ROOT}")  ($(ui::size_of "${TRACE_DIR}"))"

  # 2 — the guest page table, captured during the pause above.
  if [[ -f "${OUTPUT_DIR}/pt_dump.guest" ]]; then
    print_stage done 2 "guest page table" "${out_rel}/pt_dump.guest"
  else
    print_stage todo 2 "capture the guest page table" "(needs a running workload)"
    ui::command "${dump_rel} ${WORKLOAD} --output ${out_rel}"
  fi

  # 3 — optional: decode the raw trace now instead of during the first run.
  if [[ -s "${TRACE_DIR}/drmemtrace.trace" ]]; then
    print_stage done 3 "trace converted" "${out_rel}/.../drmemtrace.trace"
  else
    print_stage todo 3 "convert the trace" "(else the first simulation does it, at the same cost)"
    ui::command "Tracer/convert_trace.sh ${WORKLOAD}"
  fi

  print_stage todo 4 "copy the guest page table to the KVM host"
  ui::command "scp ${out_rel}/pt_dump.guest  <user>@<host>:~/pt_dump.${WORKLOAD}"

  print_stage todo 5 "on the host, translate GPA -> HPA"
  ui::command "PageTables/Host/run.sh ~/pt_dump.${WORKLOAD}"

  print_stage todo 6 "copy the host page table back, named pt_dump.host"
  ui::command "scp <user>@<host>:~/pt_dump.host  ${out_rel}/pt_dump.host"

  print_stage todo 7 "simulate"
  ui::command "cd Simulator && ./run_arm.sh ../${out_rel}"
}

(( tracer_status == 0 )) && print_next_steps
ui::blank

exit "${tracer_status}"
