#!/usr/bin/env bash
# SagePTE artifact
# Dependency installation now lives in build.sh, which installs this same
# package set — and then goes on to build everything that needs it. This
# forwarder is kept so existing instructions and links keep working.
#
#   ./build.sh                 install what is missing, then build everything
#   ./build.sh --only deps     just the toolchain, skipping the install when
#                              it is already complete
#
# --force-deps below reproduces the original behaviour of this script: install
# the full package set unconditionally.

set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath -e "${BASH_SOURCE[0]:-$0}")")
exec "${SCRIPT_DIR}/build.sh" --only deps --force-deps "$@"
