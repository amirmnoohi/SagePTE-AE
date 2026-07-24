#!/usr/bin/env bash
#
# ==============================================================================
#  SagePTE Artifact — Host Page-Table Translation
# ==============================================================================
#
#  SYNOPSIS
#      run.sh <guest-page-table> [options]
#
#  DESCRIPTION
#      Runs on the KVM *host*. Takes the guest page table captured inside the
#      VM (GVA->GPA) and resolves every guest-physical address it references to
#      a host-physical address (GPA->HPA), producing the second page table the
#      simulator needs.
#
#      Translation is done by the host_gpa_translator kernel module, which
#      locates the QEMU process's guest RAM mapping and walks QEMU's own page
#      tables for each guest frame. It is therefore specific to a *running* VM:
#      the QEMU process must be alive, and it must be the one that owns the
#      guest the dump came from.
#
#  WHERE THIS FITS
#      guest:  Tracer/run.sh            ->  memory trace
#              PageTables/Guest/run.sh  ->  pt_dump.guest   (GVA->GPA)
#                    |
#                    |  copy up to the host
#                    v
#      host:   PageTables/Host/run.sh   ->  pt_dump.host    (GPA->HPA)
#                  module translates, then host_pt_augmentor fills absent
#                  levels and writes the record-count header
#                    |
#                    |  copy back into the guest's Data/<workload>/
#                    v
#      guest:  Simulator/run_arm.sh     ->  page-walk latency
#
#  OUTPUT
#      A host page table whose first line is the record count and whose
#      remaining lines are:
#
#          GPA,hostPFN1,hostPFN2,hostPFN3,hostPFN4,hostPFN5
#
#      (hexadecimal, no 0x prefix). Absent levels — a mapping that terminates
#      early at a huge page, say — are marked "NAN" by the kernel module and
#      then replaced by the augmentation stage, so the delivered file contains
#      none: the simulator parses every field with %llx and cannot read them.
#
#  REQUIREMENTS
#      - Linux >= 6.1 on this host: the module uses the maple-tree VMA
#        iterators (VMA_ITERATOR / for_each_vma) introduced in that release.
#      - kernel headers for the running kernel, to build the module.
#      - a running QEMU/KVM guest, and root (via sudo) to load the module.
#
#  EXIT CODES
#      0    host page table produced
#      1    usage error
#      2    environment error (no QEMU, module will not build or load)
#      3    translation failed or produced nothing
#      130  interrupted (Ctrl-C)
#
#  SEE ALSO
#      PageTables/Guest/run.sh    captures the guest page table this consumes
#      host_gpa_translator.c      the module behind /proc/host_gpa_*
#
# ==============================================================================

set -euo pipefail

readonly VERSION="1.0.0"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &> /dev/null && pwd)"
readonly REPO_ROOT
PROG="${SCRIPT_DIR#"${REPO_ROOT}/"}/$(basename "${BASH_SOURCE[0]:-$0}")"
readonly PROG

readonly MODULE_NAME="host_gpa_translator"
readonly AUGMENTOR="${SCRIPT_DIR}/host_pt_augmentor"
readonly PROC_CONFIG="/proc/host_gpa_config"
readonly PROC_INPUT="/proc/host_gpa_input"
readonly PROC_OUTPUT="/proc/host_gpa_output"

# This script may be run on a host that holds only a copy of this directory, so
# the shared presentation layer is optional: fall back to plain output when the
# rest of the artifact is not present.
if [[ -r "${REPO_ROOT}/Lib/ui.sh" ]]; then
  # shellcheck source=../../Lib/ui.sh
  source "${REPO_ROOT}/Lib/ui.sh"
  ui::init
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''
  G_DOT='-'
  ui::banner()  { printf '\n== %s ==\n%s\n\n' "$1" "${2:-}"; }
  ui::step()    { printf '\n-- %s --\n' "$1"; }
  ui::set_steps() { :; }
  ui::ok()      { printf '  [OK] %s\n' "$1"; }
  ui::info()    { printf '  [..] %s\n' "$1"; }
  ui::warn()    { printf '  [!]  %s\n' "$1" >&2; }
  ui::note()    { printf '  ->   %s\n' "$1"; }
  ui::field()   { printf '  %-18s %s\n' "$1" "${2:-}"; }
  ui::command() { printf '      %s\n' "$*"; }
  ui::blank()   { echo; }
  ui::rule()    { printf -- '------------------------------------------------------------\n'; }
  ui::size_of() { du -sh "$1" 2>/dev/null | cut -f1 || printf 'n/a'; }
  ui::number()  { printf '%s' "$1"; }
  ui::duration(){ printf '%ss' "$1"; }
  ui::wait_begin(){ printf '  [..] %s\n' "$1"; }
  ui::wait_tick() { :; }
  ui::wait_end()  { printf '  [OK] %s\n' "$1"; }
  ui::wait_abort(){ :; }
  ui::result_banner() { printf '\n== %s: %s ==\n\n' "${1^^}" "$2"; }
  ui::die()     { printf '\n  [!!] %s\n' "$1" >&2; shift; for h in "$@"; do printf '       %s\n' "$h" >&2; done; echo >&2; exit "${UI_EXIT_CODE:-1}"; }
fi

# ------------------------------------------------------------------------------
# Options
# ------------------------------------------------------------------------------
GUEST_PT=""                       # the guest dump to translate
OUTPUT_FILE=""                    # default: alongside the input, as pt_dump.host
QEMU_PID="${QEMU_PID:-}"          # target QEMU process
FIX_HEADER=1                      # repair the record-count header if needed
KEEP_RAW=0                        # keep the pre-augmentation translation
RECORDS=0

usage() {
  cat <<EOF
${C_BOLD}SagePTE host page-table translation${C_RESET} v${VERSION}

${C_BOLD}USAGE${C_RESET}
  ${PROG} <guest-page-table> [options]

${C_BOLD}OPTIONS${C_RESET}
  -o, --output FILE    where to write the host page table
                       (default: <guest-pt-dir>/pt_dump.host)
  -q, --qemu-pid PID   QEMU process to translate against (default: auto-detect)
      --keep-raw       keep the pre-augmentation translation alongside the result
      --no-header-fix  do not verify/repair the record-count header
      --no-color       disable coloured output
  -h, --help           show this message
  -V, --version        show the version

${C_BOLD}EXAMPLE${C_RESET}
  ${PROG} ~/pt_dump.debug

  Then copy the result back yourself:
  scp ~/pt_dump.host <user>@<guest>:/path/to/Data/debug/pt_dump.host
EOF
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

#######################################
# Find the QEMU process that owns the running guest.
#
# Matches only the emulator binaries (qemu-system-*, qemu-kvm); a bare "qemu"
# match also picks up qemu-img, qemu-nbd and the grep itself, which is how an
# earlier version could translate against entirely the wrong process.
# Outputs:
#   The PID on stdout, or nothing if none is running.
#######################################
detect_qemu_pid() {
  # "|| true": pgrep exits 1 when nothing matches, and this runs inside a
  # command substitution — under `set -e` that status would abort the script
  # before the caller could report the much more useful "no guest is running".
  pgrep -f -- '(qemu-system-[a-z0-9_]+|qemu-kvm)' 2>/dev/null | head -1 || true
}

#######################################
# Ensure the translator module is built and freshly loaded.
# Globals:
#   Reads SCRIPT_DIR, MODULE_NAME.
# Returns:
#   0 on success; exits 2 if it cannot be built or inserted.
#######################################
load_module() {
  if [[ ! -f "${SCRIPT_DIR}/${MODULE_NAME}.ko" ]]; then
    ui::info "building the translator module"
    if ! make -C "${SCRIPT_DIR}" module > "${SCRIPT_DIR}/build.log" 2>&1; then
      UI_EXIT_CODE=2 ui::die "the translator module failed to build" \
        "$(tail -n 3 "${SCRIPT_DIR}/build.log" 2>/dev/null || true)" \
        "" \
        "full log: ${SCRIPT_DIR}/build.log" \
        "this module needs Linux >= 6.1 and matching kernel headers."
    fi
    ui::ok "module built"
  fi

  # Reload unconditionally: a module left over from a previous run still holds
  # that run's translation table, which would be served as this run's output.
  sudo rmmod "${MODULE_NAME}" 2>/dev/null || true
  if ! sudo insmod "${SCRIPT_DIR}/${MODULE_NAME}.ko" 2>/dev/null; then
    UI_EXIT_CODE=2 ui::die "could not insert ${MODULE_NAME}.ko" \
      "check 'dmesg | tail' — a kernel/module version mismatch is the usual cause"
  fi

  local node
  for node in "${PROC_CONFIG}" "${PROC_INPUT}" "${PROC_OUTPUT}"; do
    [[ -e "${node}" ]] ||
      UI_EXIT_CODE=2 ui::die "${node} did not appear after loading the module"
  done
  ui::ok "module loaded  ${PROC_CONFIG%/*}/host_gpa_{config,input,output}"
}

#######################################
# Verify — and if necessary repair — the record-count header.
#
# The simulator reads the first line with fscanf("%d\n", &n) and then reads
# exactly n records, so a header that is not the true count silently truncates
# the table with no error reported. The module emits the count itself, but an
# older module emitted the guest PID instead; this check makes the output
# correct either way.
# Arguments:
#   $1 — path to the host page table.
# Globals:
#   Sets RECORDS.
#######################################
verify_header() {
  local file="$1" header lines
  header="$(head -1 "${file}" | tr -d '[:space:]')"
  lines="$(wc -l < "${file}")"
  RECORDS=$(( lines - 1 ))

  (( RECORDS > 0 )) ||
    UI_EXIT_CODE=3 ui::die "the translation produced no records" \
      "check that the QEMU pid is the guest this dump came from"

  if [[ "${header}" == "${RECORDS}" ]]; then
    ui::ok "header verified  $(ui::number "${RECORDS}") records"
    return 0
  fi

  if (( ! FIX_HEADER )); then
    ui::warn "header is '${header}' but the file holds $(ui::number "${RECORDS}") records"
    ui::warn "the simulator will read only '${header}' of them (--no-header-fix given)"
    return 0
  fi

  ui::warn "header is '${header}', not the record count — repairing"
  { printf '%d\n' "${RECORDS}"; tail -n +2 "${file}"; } > "${file}.fixed"
  mv -f "${file}.fixed" "${file}"
  ui::ok "header repaired  $(ui::number "${RECORDS}") records"
}

on_interrupt() {
  ui::wait_abort
  ui::warn "interrupted — any partial output should be discarded"
  exit 130
}

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)       usage; exit 0 ;;
    -V|--version)    echo "run.sh ${VERSION}"; exit 0 ;;
    --no-color)      command -v ui::set_color >/dev/null 2>&1 && ui::set_color off; shift ;;
    -o|--output)     OUTPUT_FILE="${2:?--output requires a path}"; shift 2 ;;
    -q|--qemu-pid)   QEMU_PID="${2:?--qemu-pid requires a pid}"; shift 2 ;;
    --keep-raw)      KEEP_RAW=1; shift ;;
    --no-header-fix) FIX_HEADER=0; shift ;;
    -*)              UI_EXIT_CODE=1 ui::die "unknown option: $1" "try '${PROG} --help'" ;;
    *)
      [[ -z "${GUEST_PT}" ]] ||
        UI_EXIT_CODE=1 ui::die "only one guest page table may be given" \
          "got '${GUEST_PT}' and '$1'"
      GUEST_PT="$1"; shift ;;
  esac
done

[[ -n "${GUEST_PT}" ]] || { usage >&2; exit 1; }

trap on_interrupt INT TERM
ui::set_steps 5
ui::banner "SagePTE ${G_DOT} Host Page-Table Translation" "resolve guest-physical to host-physical addresses"

# ------------------------------------------------------------------------------
# 1/5 — Input
# ------------------------------------------------------------------------------

ui::step "Input"

[[ -f "${GUEST_PT}" ]] ||
  UI_EXIT_CODE=1 ui::die "no such guest page table: ${GUEST_PT}" \
    "copy it up from the guest first, e.g." \
    "    scp <guest>:.../Data/<workload>/pt_dump.guest  ~/pt_dump.<workload>"
[[ -s "${GUEST_PT}" ]] ||
  UI_EXIT_CODE=1 ui::die "the guest page table is empty: ${GUEST_PT}"

# A guest dump is a header line followed by "VA,PE1,PE2,PE3,PE4,PA" records.
# Checking one line now turns a silently empty translation into a clear error.
if ! sed -n 2p "${GUEST_PT}" | grep -qE '^[0-9a-fA-F]+(,[0-9a-fA-F]+){5}$'; then
  UI_EXIT_CODE=1 ui::die "this does not look like a guest page-table dump" \
    "expected line 2 to be VA,PE1,PE2,PE3,PE4,PA in hexadecimal" \
    "got: $(sed -n 2p "${GUEST_PT}" | cut -c1-60)"
fi

OUTPUT_FILE="${OUTPUT_FILE:-$(dirname "${GUEST_PT}")/pt_dump.host}"
RAW_OUTPUT="${OUTPUT_FILE}.raw"      # pre-augmentation translation
readonly RAW_OUTPUT

ui::field "Guest table" "${GUEST_PT}"
ui::field "Size" "$(ui::size_of "${GUEST_PT}")"
ui::field "Output" "${OUTPUT_FILE}"

# ------------------------------------------------------------------------------
# 2/5 — Environment
# ------------------------------------------------------------------------------

ui::step "Environment"

if [[ -z "${QEMU_PID}" ]]; then
  QEMU_PID="$(detect_qemu_pid)"
  [[ -n "${QEMU_PID}" ]] ||
    UI_EXIT_CODE=2 ui::die "no running qemu-system/qemu-kvm process found" \
      "the guest must be running: its memory is what we translate against." \
      "if it is running under another name, pass --qemu-pid <pid>."
fi
kill -0 "${QEMU_PID}" 2>/dev/null ||
  UI_EXIT_CODE=2 ui::die "process ${QEMU_PID} is not running"

ui::ok "qemu  pid ${QEMU_PID}  ${C_DIM}($(ps -p "${QEMU_PID}" -o comm= 2>/dev/null))${C_RESET}"

# More than one VM means the auto-detected process may be the wrong one, and the
# resulting translation would be wrong rather than absent — worth saying.
if [[ "$(pgrep -fc -- '(qemu-system-[a-z0-9_]+|qemu-kvm)' 2>/dev/null || echo 1)" -gt 1 ]]; then
  ui::warn "several qemu processes are running; using ${QEMU_PID}"
  ui::warn "pass --qemu-pid if this is not the guest the dump came from"
fi

load_module

printf '%s\n' "${QEMU_PID}" | sudo tee "${PROC_CONFIG}" > /dev/null
ui::ok "target configured"

# ------------------------------------------------------------------------------
# 3/5 — Translation
# ------------------------------------------------------------------------------

ui::step "Translation"

# Feeding the dump in is what performs the work; it can take minutes for a
# multi-million-line table.
feed_status=0
sudo tee "${PROC_INPUT}" < "${GUEST_PT}" > /dev/null &
feeder=$!
ui::wait_begin "translating guest-physical addresses"
while kill -0 "${feeder}" 2>/dev/null; do
  sleep 2
  ui::wait_tick
done
wait "${feeder}" || feed_status=$?
(( feed_status == 0 )) ||
  { ui::wait_abort; UI_EXIT_CODE=3 ui::die "feeding ${PROC_INPUT} failed (exit ${feed_status})" \
      "check 'dmesg | tail' for the module's own diagnosis"; }
ui::wait_end "translation complete"

read_status=0
sudo cat "${PROC_OUTPUT}" > "${RAW_OUTPUT}" &
reader=$!
ui::wait_begin "writing the raw translation"
while kill -0 "${reader}" 2>/dev/null; do
  sleep 2
  ui::wait_tick
done
wait "${reader}" || read_status=$?

if (( read_status != 0 )) || [[ ! -s "${RAW_OUTPUT}" ]]; then
  ui::wait_abort
  rm -f "${RAW_OUTPUT}"
  UI_EXIT_CODE=3 ui::die "no host page table was produced" \
    "the module translated nothing — the usual cause is that pid ${QEMU_PID}" \
    "is not the QEMU process hosting the guest this dump came from."
fi
ui::wait_end "raw translation written, $(ui::size_of "${RAW_OUTPUT}")"

# ------------------------------------------------------------------------------
# 4/5 — Augmentation
# ------------------------------------------------------------------------------
#
# The raw translation is not loadable as it stands: it marks absent page-table
# levels with "NAN", which the simulator's %llx parser cannot read. The
# augmentor replaces each with a unique PFN taken from the gaps between the
# PFNs actually in use — a value no real mapping owns, so the walk step is
# modelled as a distinct reference that cannot alias a real page — and writes
# the true record count as the header. See host_pt_augmentor.c.

ui::step "Augmentation"

nan_count="$(grep -c 'NAN' "${RAW_OUTPUT}" || true)"
ui::info "raw translation contains $(ui::number "${nan_count:-0}") lines with absent levels"

if [[ ! -x "${AUGMENTOR}" ]]; then
  ui::info "building the augmentor"
  if ! make -C "${SCRIPT_DIR}" augmentor > "${SCRIPT_DIR}/build.log" 2>&1; then
    UI_EXIT_CODE=2 ui::die "the augmentor failed to build" \
      "$(tail -n 3 "${SCRIPT_DIR}/build.log" 2>/dev/null || true)" \
      "" \
      "full log: ${SCRIPT_DIR}/build.log"
  fi
  ui::ok "augmentor built"
fi

aug_status=0
"${AUGMENTOR}" "${RAW_OUTPUT}" "${OUTPUT_FILE}" > "${SCRIPT_DIR}/augment.log" 2>&1 &
augmenter=$!
ui::wait_begin "filling absent levels and writing the record count"
while kill -0 "${augmenter}" 2>/dev/null; do
  sleep 2
  ui::wait_tick
done
wait "${augmenter}" || aug_status=$?

if (( aug_status != 0 )) || [[ ! -s "${OUTPUT_FILE}" ]]; then
  ui::wait_abort
  rm -f "${OUTPUT_FILE}"
  UI_EXIT_CODE=3 ui::die "augmentation failed (exit ${aug_status})" \
    "$(tail -n 3 "${SCRIPT_DIR}/augment.log" 2>/dev/null || true)" \
    "" \
    "full log: ${SCRIPT_DIR}/augment.log"
fi
ui::wait_end "augmented, $(ui::size_of "${OUTPUT_FILE}")"

# Nothing downstream can cope with a leftover NAN, so this is checked, not assumed.
if grep -q 'NAN' "${OUTPUT_FILE}"; then
  UI_EXIT_CODE=3 ui::die "the augmented table still contains NAN fields" \
    "the simulator cannot parse them; see ${SCRIPT_DIR}/augment.log" \
    "(the usual cause is too few unallocated PFNs to draw replacements from)"
fi
ui::ok "no absent levels remain"

if (( KEEP_RAW )); then
  ui::field "Raw kept at" "${RAW_OUTPUT}"
else
  rm -f "${RAW_OUTPUT}"
fi

# ------------------------------------------------------------------------------
# 5/5 — Verification and delivery
# ------------------------------------------------------------------------------

ui::step "Verification"

verify_header "${OUTPUT_FILE}"

trap - INT TERM

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

ui::result_banner ok "HOST PAGE TABLE READY"

ui::field "Host table" "${OUTPUT_FILE}"
ui::field "Records" "$(ui::number "${RECORDS}")"
ui::field "Size" "$(ui::size_of "${OUTPUT_FILE}")"
ui::field "Translated for" "qemu pid ${QEMU_PID}"

ui::blank
ui::rule
ui::blank
ui::note "copy it into the guest's data directory, then simulate:"
ui::command "scp ${OUTPUT_FILE}  <user>@<guest>:.../Data/<workload>/pt_dump.host"
ui::command "cd Simulator && ./run_arm.sh ../Data/<workload>"
ui::blank
