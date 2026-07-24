#!/usr/bin/env bash
#
# ==============================================================================
#  SagePTE Artifact — Builder
# ==============================================================================
#
#  SYNOPSIS
#      build.sh [options]
#      build.sh --only simulator
#      build.sh --list
#
#  DESCRIPTION
#      Takes a fresh clone to a state where every run script in this artifact
#      will start: it installs the toolchain, then compiles the tracer, the
#      simulator, the benchmarks and the two page-table kernel modules, in that
#      order. It subsumes install_deps.sh — packages are installed from here,
#      and only when something is actually missing.
#
#      Each component is built by its own script or Makefile, so this file
#      never becomes a second, diverging definition of how to build anything.
#      What it adds is order, a uniform report, per-component logs and the
#      repair table described below.
#
#  COMPONENTS
#      deps        Ubuntu packages and the gcc-7 toolchain
#      tracer      DynamoRIO + on-demand drmemtrace  -> Tracer/build/bin64/drrun
#      simulator   DynamoRIO + nested-walk drcachesim
#                                                    -> Simulator/build/bin64/drrun
#      workloads   the benchmark binaries            -> Workloads/bin/
#      guest-pt    /proc/page_tables module          -> PageTables/Guest/*.ko
#      host-pt     GPA->HPA module and augmentor     -> PageTables/Host/
#
#  WHAT IS OPTIONAL
#      The kernel modules are built only where they can be. guest-pt needs
#      headers for the running kernel; host-pt additionally needs Linux >= 6.1
#      (it uses the maple-tree VMA iterators) and only ever runs on the KVM
#      host. Neither is needed to replay an existing dataset, so a machine that
#      cannot build them still ends up with a working simulator: the step says
#      why it was skipped instead of failing the run.
#
#  AUTOMATIC REPAIR
#      Every step writes a log. When one fails, that log is matched against a
#      table of known failures and, where a remedy exists, the remedy is
#      applied and the step retried once:
#
#          missing package or header      install it
#          missing kernel headers         install linux-headers-$(uname -r)
#          missing core/ or libelftc      restore from git
#          make's built-in %.sh rule      re-run with implicit rules disabled
#          stale CMake cache              wipe the build directory
#          out of memory while compiling  retry serially
#
#      Nothing is repaired silently: each fix prints what it did and why.
#      An unrecognised failure stops the build and prints the tail of the log
#      together with the path to all of it. --no-repair disables the table.
#
#  OUTPUT
#      Logs/build/<component>.log     full output of each step
#
#  EXIT CODES
#      0    everything selected was built
#      1    usage error
#      2    environment error (no compiler, or no way to install packages)
#      3    a component failed to build and could not be repaired
#      130  interrupted (Ctrl-C)
#
#  SEE ALSO
#      Tracer/run.sh              capture a trace once this has run
#      Simulator/run_x86.sh       replay one
#      PageTables/Guest/run.sh    snapshot a guest page table
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
readonly REPO_ROOT="${SCRIPT_DIR}"
PROG="$(basename "${BASH_SOURCE[0]:-$0}")"
readonly PROG
readonly LOG_DIR="${REPO_ROOT}/Logs/build"

# shellcheck source=Lib/ui.sh
source "${REPO_ROOT}/Lib/ui.sh"

# ------------------------------------------------------------------------------
# Tunables. Each is overridable from the command line; see usage().
# ------------------------------------------------------------------------------
JOBS="$(nproc 2> /dev/null || echo 4)"   # -j for every sub-make
DO_CLEAN=0            # 1 = discard previous build output first
FORCE_DEPS=0          # 1 = run apt even when the sentinels are all present
REPAIR=1              # 1 = consult the repair table on failure
ONLY=()               # when non-empty, build only these components
SKIP=()               # never build these components

# The component list, in dependency order. Selection preserves this order.
readonly ALL_COMPONENTS=(deps tracer simulator workloads guest-pt host-pt)

# Populated as the run progresses; read by the summary and the trap handler.
declare -A RESULT=()          # component -> ok | skipped | failed
declare -A DETAIL=()          # component -> one-line explanation
CURRENT_COMPONENT=""
CHILD_PID=""
RUN_START=0
KERNEL_CC=""          # "CC=gcc-N" for the module builds; see kernel_cc()

# ==============================================================================
#  Package sets — merged from the former install_deps.sh
# ==============================================================================
#
# Kept as the original four groups so the provenance stays legible. These are
# installed as a set only when SENTINELS below shows something is missing.

readonly PKGS_COMMON=(
  apt-transport-https bash curl git man perl perl-doc sudo wget screen vim nano
  software-properties-common zip unzip tar rsync
  python3 python3-dev python3-pip python3-venv python-is-python3
)
readonly PKGS_KERNEL=(
  build-essential linux-tools-common linux-tools-generic liblz4-tool dwarves
  binutils elfutils gdb flex bison libncurses-dev libssl-dev libelf-dev
  cmake gcc g++ make libiberty-dev autoconf zstd libboost-all-dev
  arch-install-scripts
  libdw-dev systemtap-sdt-dev libunwind-dev libslang2-dev libperl-dev
  liblzma-dev libzstd-dev libcap-dev libnuma-dev libbabeltrace-ctf-dev libbfd-dev
  clang clang-format clang-tools llvm
)
readonly PKGS_WORKLOADS=(libreadline-dev)
readonly PKGS_TOOLCHAIN=(gcc-7 g++-7)

# One cheap probe per thing the build actually consumes. If every probe passes,
# the apt run is skipped entirely -- it takes minutes and almost always has
# nothing to do. --force-deps runs it regardless.
readonly SENTINELS=(
  'cmd:gcc' 'cmd:g++' 'cmd:make' 'cmd:cmake' 'cmd:git' 'cmd:python3'
  'cmd:gcc-7' 'cmd:g++-7'
  'file:/usr/include/numa.h'
  'file:/usr/include/readline/readline.h'
  'file:/usr/include/libelf.h'
  'file:/usr/include/openssl/ssl.h'
)

# Header -> package, consulted when a compile dies on a missing include.
declare -rA PKG_FOR_HEADER=(
  [numa.h]=libnuma-dev
  [readline/readline.h]=libreadline-dev
  [libelf.h]=libelf-dev
  [gelf.h]=libelf-dev
  [openssl/ssl.h]=libssl-dev
  [zlib.h]=zlib1g-dev
  [event.h]=libevent-dev
  [ncurses.h]=libncurses-dev
  [dwarf.h]=libdw-dev
)

# Command -> package, consulted when a step dies on "command not found".
declare -rA PKG_FOR_CMD=(
  [cmake]=cmake [gcc]=gcc [g++]=g++ [make]=make
  [gcc-7]=gcc-7 [g++-7]=g++-7 [flex]=flex [bison]=bison [perl]=perl
)

# ==============================================================================
#  Usage
# ==============================================================================

#######################################
# Print the help text.
# Outputs:
#   Usage information on stdout.
#######################################
usage() {
  cat << EOF
${C_BOLD}SagePTE artifact builder${C_RESET} v${VERSION}

${C_BOLD}USAGE${C_RESET}
  ./${PROG} [options]

${C_BOLD}OPTIONS${C_RESET}
  -j, --jobs N           parallel compile jobs        (default: ${JOBS})
      --only LIST        build only these components  (comma-separated)
      --skip LIST        never build these components
      --clean            discard previous build output first
      --force-deps       run apt even if the toolchain looks complete
      --no-repair        do not attempt automatic repair on failure
  -l, --list             list the components and exit
      --no-color         disable coloured output
  -h, --help             show this message
  -V, --version          show the version

${C_BOLD}COMPONENTS${C_RESET}
  ${ALL_COMPONENTS[*]}

${C_BOLD}EXAMPLES${C_RESET}
  ./${PROG}                          build everything
  ./${PROG} --only simulator         just the simulator (enough to replay data)
  ./${PROG} --skip deps              toolchain already installed
  ./${PROG} --only workloads --clean rebuild the benchmarks from scratch

${C_BOLD}NOTE${C_RESET}
  --clean runs each component's own clean target. In Workloads/ that deletes
  the .o-omp/.o-mt object files, which are tracked in git, so 'git status'
  will show them as deleted until the build regenerates them.
EOF
}

#######################################
# List the components and what each one produces.
# Outputs:
#   A labelled list on stdout.
#######################################
list_components() {
  ui::banner "Build components" "in dependency order; select with --only / --skip"
  ui::field "deps"      "Ubuntu packages and the gcc-7 toolchain"
  ui::field "tracer"    "Tracer/build/bin64/drrun"
  ui::field "simulator" "Simulator/build/bin64/drrun"
  ui::field "workloads" "Workloads/bin/bench_*"
  ui::field "guest-pt"  "PageTables/Guest/dump_pagetables.ko   (needs kernel headers)"
  ui::field "host-pt"   "PageTables/Host/host_pt_augmentor     (module needs Linux >= 6.1)"
  ui::blank
}

# ==============================================================================
#  Small helpers
# ==============================================================================

#######################################
# Test whether a command exists.
# Arguments:
#   $1 — command name.
#######################################
have() { command -v "$1" > /dev/null 2>&1; }

#######################################
# The compiler the running kernel was built with, expressed as a make override,
# but only when it differs from the default and is actually installed.
#
# kbuild warns when a module is compiled by a different gcc than the kernel
# was, and the two rarely agree here: the toolchain step registers gcc-7 as the
# default alternative because that is what DynamoRIO needs, while distribution
# kernels are built with something much newer. The DynamoRIO builds keep gcc-7;
# only the two kernel modules are steered back to the kernel's own compiler.
#
# Note that kbuild's warning compares the two version strings verbatim, so it
# still appears even once the versions agree: "gcc-9 (Ubuntu 9.4.0…) 9.4.0" is
# not textually "gcc (Ubuntu 9.4.0…) 9.4.0". Read the version, not the warning.
# Outputs:
#   "CC=gcc-N" on stdout, or nothing when the default is already correct.
#######################################
kernel_cc() {
  local want have_major
  want="$(grep -oE 'gcc \([^)]*\) [0-9]+' /proc/version 2> /dev/null |
    grep -oE '[0-9]+$' | head -1)"
  [[ -n "${want}" ]] || return 0
  have "gcc-${want}" || return 0
  have_major="$(gcc -dumpversion 2> /dev/null | cut -d. -f1)"
  [[ "${have_major}" == "${want}" ]] && return 0
  printf 'CC=gcc-%s' "${want}"
}

#######################################
# Decide whether a component should be built, honouring --only and --skip.
# Arguments:
#   $1 — component name.
# Returns:
#   0 when it should be built, 1 otherwise.
#######################################
selected() {
  local c="$1"
  if (( ${#ONLY[@]} > 0 )); then
    [[ " ${ONLY[*]} " == *" ${c} "* ]] || return 1
  fi
  [[ " ${SKIP[*]:-} " == *" ${c} "* ]] && return 1
  return 0
}

#######################################
# Record the outcome of a component so the closing summary can report it.
# Arguments:
#   $1 — component; $2 — ok|skipped|failed; $3 — one-line detail.
#######################################
record() {
  RESULT["$1"]="$2"
  DETAIL["$1"]="${3:-}"
}

#######################################
# Path of the log for one component.
# Arguments:
#   $1 — component name.
# Outputs:
#   The log path on stdout.
#######################################
log_for() { printf '%s/%s.log' "${LOG_DIR}" "$1"; }

#######################################
# Print the tail of a failed step's log, indented so it reads as evidence
# rather than as this script's own output.
# Arguments:
#   $1 — log path; $2 — number of lines (default 12).
#######################################
show_log_tail() {
  local log="$1" lines="${2:-12}"
  [[ -s "${log}" ]] || return 0
  ui::blank
  ui::note "last ${lines} lines of $(ui::relpath "${log}" "${REPO_ROOT}"):"
  while IFS= read -r line; do
    printf '      %s%s%s\n' "${C_DIM}" "${line}" "${C_RESET}"
  done < <(tail -n "${lines}" "${log}")
  ui::blank
}

#######################################
# Run a command with its output captured to a log, showing a live progress
# line. The command is run in the background so the spinner can advance; on a
# non-TTY ui::wait_tick degrades to a periodic note instead.
# Arguments:
#   $1 — progress label; $2 — log path; $3… — the command and its arguments.
# Returns:
#   The command's exit status.
#######################################
run_logged() {
  local label="$1" log="$2"
  shift 2
  local rc=0

  ui::wait_begin "${label}"
  "$@" >> "${log}" 2>&1 &
  CHILD_PID=$!
  while kill -0 "${CHILD_PID}" 2> /dev/null; do
    ui::wait_tick "${label}"
    sleep 0.4
  done
  wait "${CHILD_PID}" || rc=$?
  CHILD_PID=""

  if (( rc == 0 )); then
    ui::wait_end "${label}"
  else
    ui::wait_abort
  fi
  return "${rc}"
}

# ==============================================================================
#  Package installation
# ==============================================================================

#######################################
# Work out how to gain root for apt, if at all.
# Globals:
#   Sets SUDO to "" (already root), "sudo", or leaves it unset when neither
#   is possible.
# Returns:
#   0 when packages can be installed, 1 when they cannot.
#######################################
resolve_privilege() {
  if (( EUID == 0 )); then
    SUDO=""
    return 0
  fi
  if have sudo; then
    SUDO="sudo"
    return 0
  fi
  return 1
}

#######################################
# Install packages, quietly and idempotently. apt is asked once per call, not
# once per package, because its startup dominates the cost.
# Arguments:
#   $@ — package names.
# Returns:
#   apt-get's exit status, or 1 when packages cannot be installed at all.
#######################################
apt_install() {
  (( $# > 0 )) || return 0
  resolve_privilege || return 1
  DEBIAN_FRONTEND=noninteractive ${SUDO:-} apt-get install -y "$@"
}

#######################################
# Check the sentinel probes.
# Outputs:
#   The names of the probes that failed, one per line.
#######################################
missing_sentinels() {
  local s kind value
  for s in "${SENTINELS[@]}"; do
    kind="${s%%:*}"
    value="${s#*:}"
    case "${kind}" in
      cmd)  have "${value}"     || printf '%s\n' "${value}" ;;
      file) [[ -e "${value}" ]] || printf '%s\n' "${value}" ;;
    esac
  done
}

# ==============================================================================
#  The repair table
# ==============================================================================
#
# Each entry inspects a failed step's log and, when it recognises the failure,
# fixes it and returns 0 so the caller retries once. The order matters: the
# most specific diagnoses come first, because a missing header and a missing
# package can both surface as a compiler error.

#######################################
# Restore a directory that git tracks but that is absent from the working
# tree. This is the failure mode a stale .gitignore produces: the build stops
# on a file that the repository does have.
# Arguments:
#   $1 — repo-relative path.
# Returns:
#   0 when the path was restored, 1 otherwise.
#######################################
restore_from_git() {
  local path="$1"
  [[ -d "${REPO_ROOT}/.git" ]] || return 1
  have git || return 1
  [[ -n "$(git -C "${REPO_ROOT}" ls-files -- "${path}" 2> /dev/null | head -1)" ]] || return 1
  git -C "${REPO_ROOT}" checkout -- "${path}" 2> /dev/null || return 1
  ui::ok "repaired: restored ${path} from git"
  return 0
}

#######################################
# Inspect a failed step and apply a known remedy.
# Arguments:
#   $1 — component name; $2 — log path.
# Globals:
#   May set RETRY_MAKE_FLAGS or RETRY_JOBS, consulted by the component builders.
# Returns:
#   0 when something was repaired and the step is worth retrying, 1 otherwise.
#######################################
attempt_repair() {
  local component="$1" log="$2"
  [[ -s "${log}" ]] || return 1

  # --- a source tree the repository has, but the checkout does not ------------
  if grep -qE 'add_subdirectory given source "core"|core/lib/dr_api\.h' "${log}"; then
    local tree="Tracer/core"
    [[ "${component}" == simulator ]] && tree="Simulator/core"
    ui::warn "${component}: the DynamoRIO core/ tree is missing"
    restore_from_git "${tree}" && return 0
    UI_EXIT_CODE=3 ui::die "${component}: ${tree} is missing and git cannot restore it" \
      "this is what a bare 'core' pattern in .gitignore does: it matches a path" \
      "component at any depth and excludes the whole DynamoRIO core tree" \
      "re-clone the artifact, or recover ${tree} from a complete copy"
  fi

  if grep -qE 'No rule to make target.*libelftc.*(libdwarf|libelf|libelftc)\.a' "${log}"; then
    ui::warn "${component}: the prebuilt libelftc archives are missing"
    local tree="Tracer/ext/drsyms/libelftc/lib64"
    [[ "${component}" == simulator ]] && tree="Simulator/ext/drsyms/libelftc/lib64"
    restore_from_git "${tree}" && return 0
    return 1
  fi

  # --- make fell back to a built-in rule ---------------------------------------
  # A recipe-less target whose name collides with <name>.sh makes GNU make
  # supply `cat <name>.sh > <name>`. Disabling implicit rules sidesteps it even
  # if the Makefile's .PHONY is ever lost again.
  if grep -qE 'Is a directory|\[<builtin>:' "${log}"; then
    ui::warn "${component}: make used a built-in rule for a phony target"
    ui::ok "repaired: retrying with implicit rules disabled (make -r)"
    RETRY_MAKE_FLAGS="-r"
    return 0
  fi

  # --- kernel headers ----------------------------------------------------------
  if grep -qE '/lib/modules/.*/build|Cannot find kernel headers|No such file or directory.*modules' "${log}"; then
    local headers="linux-headers-$(uname -r)"
    ui::warn "${component}: headers for the running kernel are missing"
    if apt_install "${headers}" > /dev/null 2>&1 && [[ -d "/lib/modules/$(uname -r)/build" ]]; then
      ui::ok "repaired: installed ${headers}"
      return 0
    fi
    return 1
  fi

  # --- a missing include -------------------------------------------------------
  local header pkg
  header="$(grep -oE 'fatal error: [^:]+\.h: No such file' "${log}" | head -1 |
    sed -E 's/^fatal error: //; s/: No such file$//')"
  if [[ -n "${header}" ]]; then
    pkg="${PKG_FOR_HEADER[${header}]:-}"
    if [[ -n "${pkg}" ]]; then
      ui::warn "${component}: missing header ${header}"
      if apt_install "${pkg}" > /dev/null 2>&1; then
        ui::ok "repaired: installed ${pkg}"
        return 0
      fi
    fi
    return 1
  fi

  # --- a missing command -------------------------------------------------------
  local cmd
  cmd="$(grep -oE '[A-Za-z0-9_.+-]+: command not found' "${log}" | head -1 | cut -d: -f1)"
  if [[ -n "${cmd}" ]]; then
    pkg="${PKG_FOR_CMD[${cmd}]:-}"
    if [[ -n "${pkg}" ]]; then
      ui::warn "${component}: ${cmd} is not installed"
      if apt_install "${pkg}" > /dev/null 2>&1 && have "${cmd}"; then
        ui::ok "repaired: installed ${pkg}"
        return 0
      fi
    fi
    return 1
  fi

  # --- a CMake cache from somewhere else ---------------------------------------
  if grep -qE 'CMakeCache\.txt|does not match the source directory|is different than the directory' "${log}"; then
    local build_dir=""
    case "${component}" in
      tracer)    build_dir="${REPO_ROOT}/Tracer/build" ;;
      simulator) build_dir="${REPO_ROOT}/Simulator/build" ;;
    esac
    if [[ -n "${build_dir}" && -d "${build_dir}" ]]; then
      ui::warn "${component}: the CMake cache does not match this source tree"
      rm -rf "${build_dir}"
      ui::ok "repaired: removed $(ui::relpath "${build_dir}" "${REPO_ROOT}")"
      return 0
    fi
    return 1
  fi

  # --- the compiler was killed --------------------------------------------------
  if grep -qE 'virtual memory exhausted|internal compiler error: Killed|signal terminated program|Killed process' "${log}"; then
    if (( JOBS > 1 )); then
      ui::warn "${component}: the compiler ran out of memory at -j${JOBS}"
      ui::ok "repaired: retrying serially (-j1)"
      RETRY_JOBS=1
      return 0
    fi
    return 1
  fi

  return 1
}

# ==============================================================================
#  Component builders
#
#  Each is a plain command with no UI of its own: run_logged captures whatever
#  they print. They read RETRY_MAKE_FLAGS/RETRY_JOBS so a repaired retry can
#  change how they are invoked.
# ==============================================================================

build_tracer()    { "${REPO_ROOT}/Tracer/build.sh"; }
build_simulator() { "${REPO_ROOT}/Simulator/install.sh"; }

build_workloads() {
  # shellcheck disable=SC2086 # RETRY_MAKE_FLAGS is deliberately word-split
  make -C "${REPO_ROOT}/Workloads" ${RETRY_MAKE_FLAGS:-} -j"${RETRY_JOBS:-${JOBS}}"
}

build_guest_pt() {
  # KERNEL_CC is a make command-line override, so it reaches kbuild's own
  # sub-make too. Unquoted on purpose: empty means "use the default".
  # shellcheck disable=SC2086
  make -C "${REPO_ROOT}/PageTables/Guest" ${RETRY_MAKE_FLAGS:-} ${KERNEL_CC:-}
}

build_host_pt() {
  # The augmentor is plain userspace C and always builds; the module needs a
  # 6.1+ kernel, so it is requested separately by the caller.
  # shellcheck disable=SC2086
  make -C "${REPO_ROOT}/PageTables/Host" ${RETRY_MAKE_FLAGS:-} augmentor
}

build_host_pt_module() {
  # The augmentor uses AUG_CC, so overriding CC here reaches kbuild only.
  # shellcheck disable=SC2086
  make -C "${REPO_ROOT}/PageTables/Host" ${RETRY_MAKE_FLAGS:-} ${KERNEL_CC:-} module
}

#######################################
# Build one component: run it, and on failure consult the repair table once.
# Arguments:
#   $1 — component name; $2 — progress label; $3… — the build command.
# Returns:
#   0 on success, 1 when the component could not be built.
#######################################
build_with_repair() {
  local component="$1" label="$2"
  shift 2
  local log
  log="$(log_for "${component}")"
  : > "${log}"

  RETRY_MAKE_FLAGS=""
  RETRY_JOBS=""

  if run_logged "${label}" "${log}" "$@"; then
    return 0
  fi

  if (( ! REPAIR )); then
    ui::fail "${component}: build failed (automatic repair is disabled)"
    show_log_tail "${log}"
    return 1
  fi

  if ! attempt_repair "${component}" "${log}"; then
    ui::fail "${component}: build failed, and the failure is not one this script knows how to repair"
    show_log_tail "${log}"
    ui::note "full log: $(ui::relpath "${log}" "${REPO_ROOT}")"
    return 1
  fi

  if run_logged "${label} (retry)" "${log}" "$@"; then
    return 0
  fi

  ui::fail "${component}: still failing after the repair above"
  show_log_tail "${log}"
  ui::note "full log: $(ui::relpath "${log}" "${REPO_ROOT}")"
  return 1
}

# ==============================================================================
#  Steps
# ==============================================================================

#######################################
# Report the machine and confirm a compiler exists. Nothing is built here; the
# point is that a run's log begins with the facts needed to interpret it.
#######################################
step_preflight() {
  ui::step "Environment"

  # Parsed rather than sourced: /etc/os-release defines VERSION, which is
  # readonly here, and sourcing it would abort the step.
  local distro="unknown"
  if [[ -r /etc/os-release ]]; then
    distro="$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -1)"
    distro="${distro:-unknown}"
  fi

  ui::field "artifact" "${REPO_ROOT}"
  ui::field "system"   "${distro}"
  ui::field "kernel"   "$(uname -r)  ($(uname -m))"
  ui::field "cpus"     "$(nproc 2> /dev/null || echo '?')  (building with -j${JOBS})"
  if have free; then
    ui::field "memory" "$(free -h 2> /dev/null | awk '/^Mem:/ {print $2 " total, " $7 " available"}')"
  fi
  ui::field "disk"     "$(df -h --output=avail "${REPO_ROOT}" 2> /dev/null | tail -1 | tr -d ' ') available"

  if have gcc-7; then
    ui::field "compiler" "$(gcc-7 --version | head -1)"
  elif have gcc; then
    ui::field "compiler" "$(gcc --version | head -1)"
  else
    ui::field "compiler" "${C_YELLOW}none yet${C_RESET}"
  fi

  # Steer only the kernel modules at the kernel's own compiler; see kernel_cc.
  KERNEL_CC="$(kernel_cc)"
  if [[ -n "${KERNEL_CC}" ]]; then
    ui::field "kernel cc" "${KERNEL_CC#CC=}  (the kernel's own; modules only)"
  fi

  if resolve_privilege; then
    ui::ok "packages can be installed$( ((EUID == 0)) && printf ' (running as root)' || printf ' via sudo')"
  else
    ui::warn "no root and no sudo: package installation will be skipped"
  fi

  # A missing core/ tree is the one failure worth naming before anything runs,
  # because it makes both DynamoRIO builds fail several minutes in.
  local tree
  for tree in Tracer/core Simulator/core; do
    if [[ ! -d "${REPO_ROOT}/${tree}" ]]; then
      ui::warn "${tree} is missing — the build will try to restore it from git"
    fi
  done
}

#######################################
# Install the toolchain, skipping the apt run when every sentinel already
# passes. Never fatal on its own: a machine with the compiler already present
# but no way to run apt still builds fine.
#######################################
step_deps() {
  ui::step "Dependencies"

  local missing
  mapfile -t missing < <(missing_sentinels)

  if (( ${#missing[@]} == 0 )) && (( ! FORCE_DEPS )); then
    ui::ok "toolchain already complete — skipping the package install"
    ui::note "run with --force-deps to install the full set anyway"
    record deps skipped "already present"
    return 0
  fi

  if (( ${#missing[@]} > 0 )); then
    ui::info "missing: ${missing[*]}"
  fi

  if ! resolve_privilege; then
    ui::warn "cannot install packages: not root, and sudo is unavailable"
    ui::note "install these yourself, then re-run with --skip deps"
    record deps skipped "no privilege to install"
    return 0
  fi

  local log
  log="$(log_for deps)"
  : > "${log}"

  if ! run_logged "updating the package index" "${log}" \
    env DEBIAN_FRONTEND=noninteractive ${SUDO:-} apt-get update; then
    ui::warn "apt-get update failed; continuing with the current index"
  fi

  local group ok=1
  for group in COMMON KERNEL WORKLOADS TOOLCHAIN; do
    local -n pkgs="PKGS_${group}"
    if ! run_logged "installing ${group,,} packages (${#pkgs[@]})" "${log}" \
      apt_install "${pkgs[@]}"; then
      ui::warn "some ${group,,} packages did not install; see the log"
      ok=0
    fi
  done

  # gcc-7 is the compiler the artifact was evaluated with. Register it as an
  # alternative when it is present, exactly as the old install_deps.sh did.
  if have gcc-7 && have update-alternatives; then
    ${SUDO:-} update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-7 10 >> "${log}" 2>&1 || true
    ${SUDO:-} update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-7 10 >> "${log}" 2>&1 || true
    ui::ok "gcc-7 registered as an alternative"
  elif ! have gcc-7; then
    ui::warn "gcc-7 is unavailable on this release; the builds will use the system compiler"
  fi

  if (( ok )); then
    record deps ok "installed"
  else
    record deps ok "installed with warnings"
  fi
}

#######################################
# Build the tracer.
#######################################
step_tracer() {
  ui::step "Tracer"
  local out="${REPO_ROOT}/Tracer/build/bin64/drrun"

  (( DO_CLEAN )) && rm -rf "${REPO_ROOT}/Tracer/build"

  if build_with_repair tracer "compiling DynamoRIO and the drmemtrace client" build_tracer; then
    if [[ -x "${out}" ]]; then
      ui::ok "drrun  $(ui::relpath "${out}" "${REPO_ROOT}")"
      record tracer ok "$(ui::relpath "${out}" "${REPO_ROOT}")"
      return 0
    fi
    ui::fail "the build reported success but ${out} is missing"
  fi
  record tracer failed "see $(ui::relpath "$(log_for tracer)" "${REPO_ROOT}")"
  return 1
}

#######################################
# Build the simulator.
#######################################
step_simulator() {
  ui::step "Simulator"
  local out="${REPO_ROOT}/Simulator/build/bin64/drrun"

  (( DO_CLEAN )) && rm -rf "${REPO_ROOT}/Simulator/build"

  if build_with_repair simulator "compiling the nested-page-walk drcachesim" build_simulator; then
    if [[ -x "${out}" ]]; then
      ui::ok "drrun  $(ui::relpath "${out}" "${REPO_ROOT}")"
      record simulator ok "$(ui::relpath "${out}" "${REPO_ROOT}")"
      return 0
    fi
    ui::fail "the build reported success but ${out} is missing"
  fi
  record simulator failed "see $(ui::relpath "$(log_for simulator)" "${REPO_ROOT}")"
  return 1
}

#######################################
# Build the benchmark binaries.
#######################################
step_workloads() {
  ui::step "Workloads"
  local bin_dir="${REPO_ROOT}/Workloads/bin"

  if (( DO_CLEAN )); then
    make -C "${REPO_ROOT}/Workloads" clean > /dev/null 2>&1 || true
  fi

  if build_with_repair workloads "compiling the benchmarks" build_workloads; then
    local count
    count="$(find "${bin_dir}" -maxdepth 1 -type f -name 'bench_*' 2> /dev/null | wc -l)"
    if (( count > 0 )); then
      ui::ok "${count} benchmark binaries in $(ui::relpath "${bin_dir}" "${REPO_ROOT}")"
      record workloads ok "${count} binaries"
      return 0
    fi
    ui::fail "the build reported success but no bench_* binaries were produced"
  fi
  record workloads failed "see $(ui::relpath "$(log_for workloads)" "${REPO_ROOT}")"
  return 1
}

#######################################
# Build the guest page-table module. Optional: it needs headers for the
# running kernel, and only ever loads inside the traced VM.
#######################################
step_guest_pt() {
  ui::step "Guest page tables"
  local dir="${REPO_ROOT}/PageTables/Guest"
  local ko="${dir}/dump_pagetables.ko"

  if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
    ui::warn "no build tree for kernel $(uname -r)"
    ui::note "install linux-headers-$(uname -r) to build the module"
    ui::note "this is only needed inside the guest VM being traced"
    record guest-pt skipped "no kernel headers"
    return 0
  fi

  (( DO_CLEAN )) && { make -C "${dir}" clean > /dev/null 2>&1 || true; }

  if build_with_repair guest-pt "compiling dump_pagetables.ko" build_guest_pt; then
    if [[ -f "${ko}" ]]; then
      ui::ok "module  $(ui::relpath "${ko}" "${REPO_ROOT}")"
      ui::note "load it with: sudo insmod $(ui::relpath "${ko}" "${REPO_ROOT}")"
      record guest-pt ok "$(ui::relpath "${ko}" "${REPO_ROOT}")"
      return 0
    fi
  fi
  record guest-pt failed "see $(ui::relpath "$(log_for guest-pt)" "${REPO_ROOT}")"
  return 1
}

#######################################
# Build the host page-table tooling. The augmentor is portable userspace code;
# the module needs Linux >= 6.1 for the maple-tree VMA iterators and is skipped
# with an explanation anywhere older.
#######################################
step_host_pt() {
  ui::step "Host page tables"
  local dir="${REPO_ROOT}/PageTables/Host"
  local aug="${dir}/host_pt_augmentor"
  local ko="${dir}/host_gpa_translator.ko"

  (( DO_CLEAN )) && { make -C "${dir}" clean > /dev/null 2>&1 || true; }

  if ! build_with_repair host-pt "compiling host_pt_augmentor" build_host_pt; then
    record host-pt failed "see $(ui::relpath "$(log_for host-pt)" "${REPO_ROOT}")"
    return 1
  fi
  ui::ok "augmentor  $(ui::relpath "${aug}" "${REPO_ROOT}")"

  # The module half, only where it can work.
  local kver major minor
  kver="$(uname -r)"
  major="${kver%%.*}"
  minor="${kver#*.}"
  minor="${minor%%.*}"
  minor="${minor%%-*}"

  if [[ ! -d "/lib/modules/${kver}/build" ]]; then
    ui::warn "host module skipped: no build tree for kernel ${kver}"
    record host-pt ok "augmentor only (no kernel headers)"
    return 0
  fi
  if (( major < 6 || (major == 6 && minor < 1) )); then
    ui::warn "host module skipped: needs Linux >= 6.1, this is ${kver}"
    ui::note "it uses the maple-tree VMA iterators (VMA_ITERATOR, for_each_vma)"
    ui::note "it is only ever loaded on the KVM host, not in the guest"
    record host-pt ok "augmentor only (kernel ${kver} < 6.1)"
    return 0
  fi

  if build_with_repair host-pt "compiling host_gpa_translator.ko" build_host_pt_module &&
    [[ -f "${ko}" ]]; then
    ui::ok "module  $(ui::relpath "${ko}" "${REPO_ROOT}")"
    record host-pt ok "augmentor and module"
    return 0
  fi
  ui::warn "the augmentor built, but the module did not"
  record host-pt ok "augmentor only (module failed)"
  return 0
}

#######################################
# Print the closing report: one line per component, then what to run next.
# Returns:
#   0 when nothing failed, 3 otherwise.
#######################################
step_summary() {
  ui::step "Summary"

  local c state detail mark colour failures=0
  for c in "${ALL_COMPONENTS[@]}"; do
    state="${RESULT[${c}]:-not selected}"
    detail="${DETAIL[${c}]:-}"
    case "${state}" in
      ok)      mark="${G_OK}";   colour="${C_GREEN}" ;;
      skipped) mark="${G_WARN}"; colour="${C_YELLOW}" ;;
      failed)  mark="${G_FAIL}"; colour="${C_RED}"; failures=$(( failures + 1 )) ;;
      *)       mark="${G_DOT}";  colour="${C_GREY}" ;;
    esac
    printf '  %s%s%s %-11s %s%s%s\n' \
      "${colour}" "${mark}" "${C_RESET}" "${c}" \
      "${C_DIM}" "${detail:-${state}}" "${C_RESET}"
  done

  ui::blank
  ui::field "elapsed" "$(ui::duration $(( SECONDS - RUN_START )))"
  ui::field "logs"    "$(ui::relpath "${LOG_DIR}" "${REPO_ROOT}")/"

  if (( failures > 0 )); then
    ui::result_banner fail "BUILD FAILED"
    return 3
  fi

  # Only suggest what this run actually made runnable.
  local -a next=()
  if [[ "${RESULT[simulator]:-}" == ok ]]; then
    next+=("cd Simulator && ./run_x86.sh example")
  fi
  if [[ "${RESULT[tracer]:-}" == ok && "${RESULT[workloads]:-}" == ok ]]; then
    next+=("./Tracer/run.sh debug")
  fi
  if (( ${#next[@]} > 0 )); then
    ui::blank
    ui::note "next:"
    local cmd
    for cmd in "${next[@]}"; do
      ui::command "${cmd}"
    done
  fi

  ui::result_banner ok "BUILD COMPLETE"
  return 0
}

# ==============================================================================
#  Signal handling
# ==============================================================================

#######################################
# Stop the in-flight compile and report an interrupted run.
# Returns:
#   Never; exits 130.
#######################################
on_interrupt() {
  trap - INT TERM
  ui::wait_abort
  [[ -n "${CHILD_PID}" ]] && kill "${CHILD_PID}" 2> /dev/null || true
  ui::blank
  ui::fail "interrupted while building ${CURRENT_COMPONENT:-the artifact}"
  ui::result_banner fail "BUILD INTERRUPTED"
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
    -l | --list)    list_components; exit 0 ;;
    --no-color)     ui::set_color off; shift ;;
    -j | --jobs)    JOBS="${2:?--jobs requires a number}"; shift 2 ;;
    --only)         IFS=', ' read -r -a ONLY <<< "${2:?--only requires a component list}"; shift 2 ;;
    --skip)         IFS=', ' read -r -a SKIP <<< "${2:?--skip requires a component list}"; shift 2 ;;
    --clean)        DO_CLEAN=1; shift ;;
    --force-deps)   FORCE_DEPS=1; shift ;;
    --no-repair)    REPAIR=0; shift ;;
    -*)             UI_EXIT_CODE=1 ui::die "unknown option: $1" "try './${PROG} --help'" ;;
    *)              UI_EXIT_CODE=1 ui::die "unexpected argument: $1" \
                      "this script takes options only; try './${PROG} --help'" ;;
  esac
done

[[ "${JOBS}" =~ ^[0-9]+$ ]] && (( JOBS > 0 )) ||
  UI_EXIT_CODE=1 ui::die "--jobs must be a positive integer (got '${JOBS}')"

# Reject unknown component names rather than silently building nothing.
for _c in ${ONLY[*]:-} ${SKIP[*]:-}; do
  [[ " ${ALL_COMPONENTS[*]} " == *" ${_c} "* ]] ||
    UI_EXIT_CODE=1 ui::die "unknown component: ${_c}" \
      "known components: ${ALL_COMPONENTS[*]}"
done
unset _c

# ==============================================================================
#  Main
# ==============================================================================

trap on_interrupt INT TERM

RUN_START=${SECONDS}
mkdir -p "${LOG_DIR}"

# One step for the environment report, one per selected component, one for the
# summary — so the "n/N" counter matches what the run will actually do.
_steps=2
for _c in "${ALL_COMPONENTS[@]}"; do
  selected "${_c}" && _steps=$(( _steps + 1 ))
done
ui::set_steps "${_steps}"
unset _c _steps

ui::banner "SagePTE ${G_DOT} Builder" "tracer, simulator, benchmarks and page-table modules"

step_preflight

STATUS=0
for component in "${ALL_COMPONENTS[@]}"; do
  if ! selected "${component}"; then
    continue
  fi
  CURRENT_COMPONENT="${component}"
  case "${component}" in
    deps)      step_deps      || STATUS=3 ;;
    tracer)    step_tracer    || STATUS=3 ;;
    simulator) step_simulator || STATUS=3 ;;
    workloads) step_workloads || STATUS=3 ;;
    guest-pt)  step_guest_pt  || STATUS=3 ;;
    host-pt)   step_host_pt   || STATUS=3 ;;
  esac
  CURRENT_COMPONENT=""
done

step_summary || STATUS=3
exit "${STATUS}"
