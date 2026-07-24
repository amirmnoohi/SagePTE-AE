#!/usr/bin/env bash
# SagePTE artifact
# Build the SagePTE nested-page-walk simulator (DynamoRIO + modified drcachesim).
# Produces build/bin64/drrun and the drcachesim client.

set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath -e "${BASH_SOURCE[0]:-$0}")")
cd "$SCRIPT_DIR"

# The artifact was developed and evaluated with gcc/g++ 7 (Ubuntu 20.04).
# Fall back to the system compiler if gcc-7 is not installed.
if command -v gcc-7 >/dev/null 2>&1; then
    export CC=gcc-7
    export CXX=g++-7
fi

mkdir -p build
cd build

CFLAGS=-g CXXFLAGS=-g cmake -DDEBUG=ON ..
make -j"$(nproc)"

echo
echo "-----------------------------------------------------------------------"
echo "Success - simulator built at $SCRIPT_DIR/build/bin64/drrun"
