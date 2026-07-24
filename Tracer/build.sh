#!/usr/bin/env bash

set -euo pipefail

mkdir -p build
cd build

CC=gcc-7 CXX=g++-7 cmake ..
make -j
