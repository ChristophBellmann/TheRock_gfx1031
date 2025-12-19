#!/usr/bin/env bash
set -euo pipefail

# Stage-1: build the in-tree toolchain (amd-llvm + hip-clr) using the system
# clang toolchain. Output goes to BUILD_DIR=build-stage1.
export STAGE=1
export BUILD_DIR="${BUILD_DIR:-build-stage1}"

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/configure_gfx1031.sh" --clean "$@"

