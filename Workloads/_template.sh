#!/usr/bin/env bash
#
# SagePTE artifact — workload definition template.
#
# Copy this file to Workloads/<name>.sh and it becomes runnable as
#
#     Tracer/run.sh <name>
#
# The file is *sourced* by the tracer, so it only declares variables and
# optional hooks; it must not run the workload itself.
#
# Variables provided to you:
#   REPO_ROOT     the SAGEPTE-AE root directory
#   WORKLOAD_DIR  Workloads/
#   BIN_DIR       Workloads/bin/
#   OUTPUT_DIR    is NOT yet set here (hooks run later and may use it)
#
# ---------------------------------------------------------------------------
# Required
# ---------------------------------------------------------------------------

# One-line summary, shown by `run.sh --list`.
DESCRIPTION="short description of the workload"

# Executable.  A bare name is looked up in Workloads/bin; an absolute path is
# used as given (for system binaries).
BINARY="bench_example_st"

# Arguments.  Use ARGS for the common case; if an argument contains spaces,
# set the ARGV array instead (it takes precedence):
#   ARGV=(-d "/path/with spaces" -n 4)
ARGS=""

# ---------------------------------------------------------------------------
# Optional
# ---------------------------------------------------------------------------

# File the workload writes once its initialisation is finished (dataset loaded,
# heap fully touched, ...).  Recording starts only after this file becomes
# non-empty, so the trace covers the steady-state phase and the page table is
# fully populated when it is dumped.
# Leave empty if the workload has no such signal — then READY_DELAY is used.
READY_FILE=""

# Seconds to wait instead, when READY_FILE is empty.
READY_DELAY=3

# Space-separated paths that must exist before the run (datasets, helper
# binaries).  The tracer aborts with a clear message if one is missing.
REQUIRES=""

# ---------------------------------------------------------------------------
# Hooks (all optional)
# ---------------------------------------------------------------------------

# Runs before the workload is started: kill stale instances, delete state left
# over from a previous run, ...
pre_run() {
    :
}

# Runs immediately after the workload has been started, while recording is
# still off.  This is the slot for an external load generator that a
# server-style workload needs in order to reach its steady state.
post_start() {
    :
}

# Runs after the workload has exited.
post_run() {
    :
}
