#!/usr/bin/env bash
set -euo pipefail

# Stage-2: new build dir, but point the top-level compilers to the Stage-1
# in-tree LLVM toolchain so no subproject can fall back to system clang.
export STAGE=2
export BUILD_DIR="${BUILD_DIR:-build-stage2}"
export STAGE1_BUILD_DIR="${STAGE1_BUILD_DIR:-build-stage1}"

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/configure_gfx1031.sh" --clean "$@"

