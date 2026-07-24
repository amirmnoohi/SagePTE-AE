#!/usr/bin/env bash
#
# ==============================================================================
#  SagePTE Artifact — Guest Page-Table Dumper
# ==============================================================================
#
#  SYNOPSIS
#      run.sh <workload> [options]
#      run.sh --pid <pid> --output <dir>
#
#  DESCRIPTION
#      Captures the guest page table of a traced run and converts it into the
#      form the simulator reads. It is the counterpart of Tracer/run.sh:
#      that script publishes <output-dir>/meta/trace.state, this one consumes it, so
#      neither needs to know anything about the tracer's internal handshake.
#
#      The snapshot must be taken while the workload is running — a page table
#      cannot be recovered from a process that has exited — and after the
#      workload has built its working set, which is exactly the window the
#      tracer signals by moving its state to "tracing". This script therefore
#      waits for that state by default and can be started before or after the
#      tracer.
#
#  USAGE PATTERNS
#      Two shells:    Tracer/run.sh redis        (pauses, waiting)
#                     PageTables/Guest/run.sh redis
#      Ad hoc:        PageTables/Guest/run.sh --pid 1234 --output /tmp/snap
#
#  OUTPUT
#      <output-dir>/pt_dump.guest          guest page table, simulator-ready
#      <output-dir>/meta/pt_dump.guest.raw the untouched /proc/page_tables dump
#      <output-dir>/meta/pmap.txt     the process's VMA map, for reference
#
#  WHY THE CONVERSION EXISTS
#      The kernel module prints the selected PID as the first line of its dump
#      (`seq_printf(s, "%16d\n", selected_pid)`, dump_pagetables.c).
#      The simulator, however, reads that first line as a decimal *record count*
#      (`fscanf(f, "%d\n", &page_table_record_num)`, cache_simulator.cpp) and
#      then reads exactly that many records. Handing a raw dump to the simulator
#      would silently load only <pid> entries — for a PID of 9712, fewer than
#      ten thousand of several million mappings, with no error reported.
#      This script replaces the header with the true record count. Only the
#      header changes; every record is passed through byte for byte.
#
#  FORMAT
#      Line 1     record count, decimal
#      Line 2..N  VA,PE1,PE2,PE3,PE4,PA   (hexadecimal, no 0x prefix)
#                 where PE1..PE4 are the guest-physical frame numbers of the
#                 four page-table levels and PA is the mapped data frame.
#
#  EXIT CODES
#      0    page table captured
#      1    usage error
#      2    environment error (dumper module not loaded)
#      3    no dumpable run (nothing is tracing, or the process has exited)
#      130  interrupted (Ctrl-C)
#
#  SEE ALSO
#      Tracer/run.sh                    produces the run this script snapshots
#      ../Host/run.sh                 produces the matching HOST page table
#      dump_pagetables.c     the kernel module behind /proc/page_tables
#
# ==============================================================================

set -euo pipefail

readonly VERSION="1.0.0"


# ------------------------------------------------------------------------------
# Paths
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &> /dev/null && pwd)"
readonly REPO_ROOT
# How this script names itself in help: every component exposes a run.sh,
# so the path relative to the artifact root is what disambiguates it.
PROG="${SCRIPT_DIR#"${REPO_ROOT}/"}/$(basename "${BASH_SOURCE[0]:-$0}")"
readonly PROG
readonly PT_PROC="/proc/page_tables"        # interface exported by the module
readonly MODULE_DIR="${SCRIPT_DIR}"          # the module sources live beside this script
readonly HOST_DUMPER="${SCRIPT_DIR}/../Host/run.sh"

# shellcheck source=../../Lib/ui.sh
source "${REPO_ROOT}/Lib/ui.sh"

# ------------------------------------------------------------------------------
# Options
# ------------------------------------------------------------------------------
WORKLOAD=""           # workload name; resolves the run through its state file
OUTPUT_DIR=""         # default: Data/<workload>
PID=""                # explicit target, bypassing the state file
WAIT_SECONDS=600      # how long to wait for a run to reach the "tracing" state
CONVERT=1             # 1 = also write the simulator-ready pt_dump
KEEP_RAW=1            # 0 = delete the raw dump after a successful conversion
COMPACT=0             # 1 = running nested inside run.sh's output
SUDO=""               # set to "sudo" when not already root

RECORDS=0             # populated by convert_dump()

# ==============================================================================
#  Usage
# ==============================================================================

#######################################
# Print the help text.
# Outputs:
#   Usage information on stdout.
#######################################
usage() {
  cat <<EOF
${C_BOLD}SagePTE guest page-table dumper${C_RESET} v${VERSION}

${C_BOLD}USAGE${C_RESET}
  ${PROG} <workload> [options]
  ${PROG} --pid <pid> --output <dir>

${C_BOLD}OPTIONS${C_RESET}
  -o, --output DIR   where to write the snapshot   (default: Data/<workload>)
  -p, --pid PID      dump this process directly, ignoring the trace state file
  -w, --wait SEC     how long to wait for a trace to start (default: ${WAIT_SECONDS}; 0 = no wait)
      --raw-only     capture only; skip the simulator-format conversion
      --no-raw       delete the raw dump once it has been converted
      --compact      render as status lines only (used when nested in run.sh)
      --no-color     disable coloured output
  -h, --help         show this message
  -V, --version      show the version

${C_BOLD}NOTES${C_RESET}
  The page table can only be captured while the workload is running. Start the
  trace first (Tracer/run.sh <workload>); it pauses so this can be run.
EOF
}

# ==============================================================================
#  Helpers
# ==============================================================================

#######################################
# Read one KEY=VALUE field from a trace state file.
# Arguments:
#   $1 — key; $2 — path to the state file.
# Outputs:
#   The value on stdout, empty if the key is absent.
#######################################
state_get() {
  # "|| true": a bare assignment from this would abort the caller under `set -e`.
  sed -n "s/^$1=\(.*\)$/\1/p" "$2" 2>/dev/null | tail -1 || true
}

#######################################
# Block until a run for ${WORKLOAD} reports that it is recording, then adopt its
# PID. Distinguishes "not started yet" (worth waiting for) from "already
# finished" (hopeless, and worth saying so plainly).
# Globals:
#   Reads WORKLOAD, OUTPUT_DIR, WAIT_SECONDS; sets PID.
# Returns:
#   0 on success; exits 3 if no dumpable run appears.
#######################################
await_running_trace() {
  # meta/ is the current layout; the flat path is accepted so directories
  # captured by an earlier version still work.
  local state_file="${OUTPUT_DIR}/meta/trace.state"
  [[ -f "${state_file}" ]] || [[ ! -f "${OUTPUT_DIR}/trace.state" ]] ||
    state_file="${OUTPUT_DIR}/trace.state"
  local deadline=$(( SECONDS + WAIT_SECONDS ))
  local status

  ui::wait_begin "waiting for a running trace of '${WORKLOAD}'"
  while :; do
    if [[ -f "${state_file}" ]]; then
      status="$(state_get STATUS "${state_file}")"
      PID="$(state_get APP_PID "${state_file}")"
      case "${status}" in
        tracing)
          if [[ -n "${PID}" ]]; then
            ui::wait_end "found running trace, pid ${PID}"
            return 0
          fi
          ui::wait_abort
          UI_EXIT_CODE=3 ui::die "the trace is running but reported no PID" \
            "the DynamoRIO client never acknowledged; nothing can be dumped"
          ;;
        done|failed|interrupted)
          ui::wait_abort
          UI_EXIT_CODE=3 ui::die \
            "the trace for '${WORKLOAD}' has already finished (status: ${status})" \
            "a page table can only be captured while the workload is running." \
            "" \
            "re-run the workload and capture in one step:" \
            "    Tracer/run.sh ${WORKLOAD}      (it pauses; run this script then)"
          ;;
      esac
    fi

    if (( SECONDS >= deadline )); then
      ui::wait_abort
      UI_EXIT_CODE=3 ui::die "timed out waiting for a running trace of '${WORKLOAD}'" \
        "start it first:" \
        "    Tracer/run.sh ${WORKLOAD}" \
        "" \
        "or capture in one step:" \
        "    Tracer/run.sh ${WORKLOAD}      (it pauses; run this script then)"
    fi
    sleep 1
    ui::wait_tick
  done
}

#######################################
# Read /proc/page_tables for the target process.
#
# The module is stateful: writing "U<pid>" selects userspace mode for that PID,
# and the subsequent read walks that process's tables. Reads of a large working
# set take a while and produce gigabytes, so the read runs in the background and
# progress is reported while it drains.
# Globals:
#   Reads PID, PT_PROC, SUDO; writes ${RAW}.
# Arguments:
#   $1 — destination path for the raw dump.
# Returns:
#   0 on success; exits 3 if the dump is empty.
#######################################
capture_dump() {
  local raw="$1" reader_pid reader_status=0

  printf 'U%s\n' "${PID}" | ${SUDO} tee "${PT_PROC}" > /dev/null

  # Written through tee so the file is created with the same privileges as the
  # read: the tracer runs as root, so its output directory is root-owned and a
  # plain redirect by a non-root user would fail with EACCES.
  ${SUDO} cat "${PT_PROC}" | ${SUDO} tee "${raw}" > /dev/null &
  reader_pid=$!

  ui::wait_begin "reading ${PT_PROC}"
  while kill -0 "${reader_pid}" 2>/dev/null; do
    sleep 1
    ui::wait_tick
  done
  wait "${reader_pid}" || reader_status=$?

  # The most likely failure by far is that the workload exited while its table
  # was being walked: the module then has no mm_struct to traverse and fails the
  # read. Diagnose that explicitly — the generic errno is deeply unhelpful here.
  if (( reader_status != 0 )) || [[ ! -s "${raw}" ]]; then
    ui::wait_abort
    rm -f "${raw}"
    if ! kill -0 "${PID}" 2>/dev/null; then
      UI_EXIT_CODE=3 ui::die \
        "the workload exited while its page table was being read" \
        "a snapshot must complete before the traced process finishes." \
        "" \
        "this normally means the trace was too short. raise the reference" \
        "budget so the workload outlives the dump, e.g.:" \
        "    Tracer/run.sh ${WORKLOAD:-<workload>} --max-refs 2000000000"
    fi
    UI_EXIT_CODE=3 ui::die "reading ${PT_PROC} failed (exit ${reader_status})" \
      "the module rejected the request; check dmesg for details"
  fi
  ui::wait_end "page table captured, $(ui::size_of "${raw}")"
}

#######################################
# Rewrite the dump's header so the simulator loads every record. See the
# "WHY THE CONVERSION EXISTS" note at the top of this file.
# Globals:
#   Reads PID; sets RECORDS.
# Arguments:
#   $1 — raw dump path; $2 — destination path.
# Returns:
#   0 on success; exits 3 if the dump holds no records.
#######################################
convert_dump() {
  local raw="$1" out="$2" header total

  # Sanity check: the header the module writes is the PID we selected. If it is
  # anything else the module's format has changed, so warn rather than silently
  # producing a subtly wrong input file.
  header="$(head -1 "${raw}" | tr -d '[:space:]')"
  if [[ "${header}" != "${PID}" ]]; then
    ui::warn "unexpected header '${header}' (expected the dumped pid ${PID})"
    ui::warn "still treating it as a one-line header — verify the module's format"
  fi

  total="$(wc -l < "${raw}")"
  RECORDS=$(( total - 1 ))
  (( RECORDS > 0 )) ||
    UI_EXIT_CODE=3 ui::die "the dump contains no page-table records"

  local writer_pid writer_status=0
  { printf '%d\n' "${RECORDS}"; tail -n +2 "${raw}"; } > "${out}" &
  writer_pid=$!

  ui::wait_begin "writing simulator-ready dump ($(ui::number "${RECORDS}") records)"
  while kill -0 "${writer_pid}" 2>/dev/null; do
    sleep 1
    ui::wait_tick
  done
  wait "${writer_pid}" || writer_status=$?

  if (( writer_status != 0 )); then
    ui::wait_abort
    UI_EXIT_CODE=3 ui::die "writing ${out} failed (exit ${writer_status})"
  fi
  ui::wait_end "converted to simulator format, $(ui::size_of "${out}")"
}

#######################################
# Handle Ctrl-C without leaving a half-written dump that looks complete.
# Returns:
#   Never; exits 130.
#######################################
on_interrupt() {
  ui::wait_abort
  ui::warn "interrupted — any partial dump in ${OUTPUT_DIR:-.} should be discarded"
  exit 130
}

# ==============================================================================
#  Argument parsing
# ==============================================================================

ui::init

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -V|--version) echo "run.sh ${VERSION}"; exit 0 ;;
    --no-color)   ui::set_color off; shift ;;
    -o|--output)  OUTPUT_DIR="${2:?--output requires a directory}"; shift 2 ;;
    -p|--pid)     PID="${2:?--pid requires a process id}"; shift 2 ;;
    -w|--wait)    WAIT_SECONDS="${2:?--wait requires a number of seconds}"; shift 2 ;;
    --raw-only)   CONVERT=0; shift ;;
    --no-raw)     KEEP_RAW=0; shift ;;
    --compact)    COMPACT=1; ui::set_compact on; shift ;;
    -*)           UI_EXIT_CODE=1 ui::die "unknown option: $1" "try '${PROG} --help'" ;;
    *)
      [[ -z "${WORKLOAD}" ]] ||
        UI_EXIT_CODE=1 ui::die "only one workload may be given" \
          "got '${WORKLOAD}' and '$1'"
      WORKLOAD="$1"; shift ;;
  esac
done

if [[ -z "${WORKLOAD}" && -z "${PID}" ]]; then
  usage >&2
  exit 1
fi
[[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]] ||
  UI_EXIT_CODE=1 ui::die "--wait must be a non-negative integer (got '${WAIT_SECONDS}')"

[[ "$(id -u)" -eq 0 ]] || SUDO="sudo"

trap on_interrupt INT TERM

ui::set_steps 4

# ==============================================================================
#  1/4 — Target
# ==============================================================================

ui::banner "SagePTE ${G_DOT} Page-Table Dumper" "guest GVA->GPA snapshot for nested-paging simulation"
ui::step "Target"

if [[ -z "${PID}" ]]; then
  OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/Data/${WORKLOAD}}"
  await_running_trace
else
  [[ -n "${OUTPUT_DIR}" ]] ||
    UI_EXIT_CODE=1 ui::die "--pid also requires --output DIR"
  ui::ok "explicit target  ${C_DIM}(pid ${PID})${C_RESET}"
fi

kill -0 "${PID}" 2>/dev/null ||
  UI_EXIT_CODE=3 ui::die "process ${PID} is not running" \
    "a page table can only be captured while the workload is alive"

# Only the converted page table is a simulator input, so it sits at the top of
# the output directory; the raw dump and the VMA map are intermediates and live
# under meta/ alongside the tracer's logs. See Tracer/run.sh for the layout.
readonly META_DIR="${OUTPUT_DIR}/meta"
mkdir -p "${META_DIR}"

readonly PT_DUMP="${OUTPUT_DIR}/pt_dump.guest"
readonly RAW_DUMP="${META_DIR}/pt_dump.guest.raw"
readonly PMAP_FILE="${META_DIR}/pmap.txt"

# Nested in run.sh these are already on screen; only the standalone run needs
# to restate what it is operating on.
if (( ! COMPACT )); then
  ui::field "Workload" "${WORKLOAD:-<none — explicit pid>}"
  ui::field "Target pid" "${PID}"
  ui::field "Output" "$(ui::relpath "${OUTPUT_DIR}" "${REPO_ROOT}")"
fi

# ==============================================================================
#  2/4 — Environment
# ==============================================================================

ui::step "Environment"

[[ -e "${PT_PROC}" ]] ||
  UI_EXIT_CODE=2 ui::die "${PT_PROC} does not exist — the dumper module is not loaded" \
    "build and load it with:" \
    "    cd ${MODULE_DIR} && make && sudo insmod dump_pagetables.ko"
# These confirm a healthy environment, which matters when the dumper is run on
# its own; nested, they are noise — a failure still aborts loudly either way.
if (( ! COMPACT )); then
  ui::ok "module interface  ${PT_PROC}"
  [[ -n "${SUDO}" ]] && ui::info "not running as root — privileged steps use sudo"
  ui::ok "target process alive"
fi

# ==============================================================================
#  3/4 — Capture
# ==============================================================================

ui::step "Capture"

capture_dump "${RAW_DUMP}"

if ${SUDO} pmap -XX "${PID}" > "${PMAP_FILE}" 2>/dev/null; then
  ui::ok "VMA map  $(ui::relpath "${PMAP_FILE}" "${REPO_ROOT}")"
else
  ui::warn "pmap failed (the process may have exited) — continuing"
  rm -f "${PMAP_FILE}"
fi

# ==============================================================================
#  4/4 — Conversion
# ==============================================================================

ui::step "Conversion"

if (( CONVERT )); then
  convert_dump "${RAW_DUMP}" "${PT_DUMP}"
  if (( ! KEEP_RAW )); then
    rm -f "${RAW_DUMP}"
    ui::ok "raw dump removed (--no-raw)"
  fi
else
  ui::info "conversion skipped (--raw-only)"
  ui::warn "the raw dump is NOT loadable by the simulator: its first line is the"
  ui::warn "pid, where a record count is expected"
fi

# ==============================================================================
#  Summary
# ==============================================================================

if (( COMPACT )); then
  # Nested in run.sh: one summary line. run.sh prints the full result box
  # and the "what to do next" guidance for the run as a whole.
  ui::ok "guest page table  $(ui::relpath "${PT_DUMP}" "${REPO_ROOT}")  ${C_DIM}($(ui::number "${RECORDS}") records, $(ui::size_of "${PT_DUMP}"))${C_RESET}"
  exit 0
fi

ui::result_banner ok "PAGE TABLE CAPTURED ${G_DOT} ${WORKLOAD:-pid ${PID}}"

ui::field "Target pid" "${PID}"
if (( CONVERT )); then
  ui::field "Guest page table" "$(ui::relpath "${PT_DUMP}" "${REPO_ROOT}")"
  ui::field "Records" "$(ui::number "${RECORDS}")"
  ui::field "Size" "$(ui::size_of "${PT_DUMP}")"
fi
[[ -f "${RAW_DUMP}"  ]] && ui::field "Raw dump" "$(ui::relpath "${RAW_DUMP}" "${REPO_ROOT}")"
[[ -f "${PMAP_FILE}" ]] && ui::field "VMA map" "$(ui::relpath "${PMAP_FILE}" "${REPO_ROOT}")"

ui::blank
ui::rule
ui::blank
ui::note "the simulator also needs the matching HOST page table (GPA->HPA),"
ui::note "produced on the KVM host from this guest dump:"
ui::command "PageTables/Host/run.sh <this dump, on the host>"
ui::blank
