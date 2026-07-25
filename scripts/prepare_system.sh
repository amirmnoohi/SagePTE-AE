#!/usr/bin/env bash
#
# ==============================================================================
#  SagePTE Artifact — System preparation
# ==============================================================================
#
#  SYNOPSIS
#      scripts/prepare_system.sh [--check]
#
#  DESCRIPTION
#      Puts the machine into the state the measurements assume. Run it on both
#      machines: inside the guest before tracing, and on the KVM host before
#      translating. --check reports without changing anything and exits
#      non-zero if the machine is not prepared.
#
#  WHY EACH SETTING MATTERS
#      Transparent huge pages change the thing being measured. On the host they
#      decide how deep the terminal Stage-2 walk is: with THP the guest's RAM
#      is backed by 2 MB pages, the walk stops a level early, and the h-final
#      phase the paper attributes 42 to 47% of walk latency to becomes cheaper
#      than it should be. Worse, khugepaged collapses pages while the guest
#      runs, so how much of the guest is on huge pages depends on how long the
#      VM has been up, and a capture taken an hour later measures a different
#      machine. In the guest they do the same to the workload's own tables.
#
#      Dropping the page cache starts every run from the same cold state, so
#      one workload does not inherit whatever the last one left resident.
#
#  NOTE
#      Setting THP to never stops further collapses but does not split pages
#      already collapsed. A guest whose memory is already backed by huge pages
#      keeps them until it restarts, so prepare the host before booting the VM
#      that will be traced.
#
#  EXIT CODES
#      0    prepared, or --check found it prepared
#      1    --check found it unprepared
#      2    not root, or the knobs are missing
#
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
readonly REPO_ROOT

# shellcheck source=../Lib/ui.sh
source "${REPO_ROOT}/Lib/ui.sh"

readonly THP_ENABLED="/sys/kernel/mm/transparent_hugepage/enabled"
readonly THP_DEFRAG="/sys/kernel/mm/transparent_hugepage/defrag"

CHECK_ONLY=0

#######################################
# The bracketed value of a THP knob, which is the active one.
# Arguments:
#   $1 — path to the knob.
# Outputs:
#   The active setting, or "missing".
#######################################
thp_mode() {
  [[ -r "$1" ]] || { printf 'missing'; return 0; }
  sed -n 's/.*\[\([a-z+]*\)\].*/\1/p' "$1"
}

ui::init
while (( $# > 0 )); do
  case "$1" in
    --check)    CHECK_ONLY=1; shift ;;
    --no-color) ui::set_color off; shift ;;
    -h | --help)
      sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'
      exit 0 ;;
    *) UI_EXIT_CODE=2 ui::die "unknown option: $1" ;;
  esac
done

[[ -r "${THP_ENABLED}" ]] ||
  UI_EXIT_CODE=2 ui::die "${THP_ENABLED} is missing" \
    "this kernel has no transparent huge page support to disable"

if (( CHECK_ONLY )); then
  status=0
  for knob in "${THP_ENABLED}" "${THP_DEFRAG}"; do
    mode="$(thp_mode "${knob}")"
    if [[ "${mode}" == never ]]; then
      ui::ok "$(basename "${knob}")  ${mode}"
    else
      ui::warn "$(basename "${knob}")  ${mode}  (expected never)"
      status=1
    fi
  done
  exit "${status}"
fi

(( EUID == 0 )) ||
  UI_EXIT_CODE=2 ui::die "this must run as root" "it writes to /sys and /proc"

# Disable transparent huge pages.
for knob in "${THP_ENABLED}" "${THP_DEFRAG}"; do
  [[ -w "${knob}" ]] || continue
  echo never > "${knob}"
  ui::ok "$(basename "${knob}")  $(thp_mode "${knob}")"
done

# Drop the page cache so every run starts from the same state.
sync
echo 3 > /proc/sys/vm/drop_caches
ui::ok "page cache dropped  $(awk '/^MemAvailable:/ {printf "%.0f GB available", $2/1048576}' /proc/meminfo)"

# Report what is still on huge pages. Setting never does not split what has
# already been collapsed, which is why this is worth saying out loud.
resident="$(awk '/^AnonHugePages:/ {print $2}' /proc/meminfo)"
if (( resident > 0 )); then
  ui::warn "$(ui::bytes $(( resident * 1024 ))) is still on huge pages collapsed earlier"
  ui::note "processes keep those until they exit; restart the VM before capturing"
fi
