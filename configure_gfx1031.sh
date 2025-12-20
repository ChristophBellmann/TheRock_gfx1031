#!/usr/bin/env bash
set -euo pipefail

# This file is intended to be edited: flip the booleans below to select which
# components are configured in the superbuild.
#
# It forwards to: ./build_gfx1031.sh configure ...

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Feature switches (set true/false)
export ENABLE_COMPILER="${ENABLE_COMPILER:-true}"
export ENABLE_CORE_RUNTIME="${ENABLE_CORE_RUNTIME:-true}"
export ENABLE_HIP_RUNTIME="${ENABLE_HIP_RUNTIME:-true}"
export ENABLE_HIPIFY="${ENABLE_HIPIFY:-true}"
export ENABLE_BLAS="${ENABLE_BLAS:-true}"
export ENABLE_PRIM="${ENABLE_PRIM:-true}"
export ENABLE_RAND="${ENABLE_RAND:-true}"
export ENABLE_FFT="${ENABLE_FFT:-true}"
export ENABLE_SPARSE="${ENABLE_SPARSE:-true}"
export ENABLE_SOLVER="${ENABLE_SOLVER:-true}"
export ENABLE_HIPBLASLT="${ENABLE_HIPBLASLT:-false}"
export ENABLE_HIPSPARSELT="${ENABLE_HIPSPARSELT:-false}"
export ENABLE_MIOPEN="${ENABLE_MIOPEN:-true}"
export ENABLE_HIPDNN="${ENABLE_HIPDNN:-true}"
export ENABLE_COMPOSABLE_KERNEL="${ENABLE_COMPOSABLE_KERNEL:-true}"
export ENABLE_RCCL="${ENABLE_RCCL:-true}"
export ENABLE_ROCWMMA="${ENABLE_ROCWMMA:-false}"
export ENABLE_PROFILER="${ENABLE_PROFILER:-true}"
export ENABLE_DC_TOOLS="${ENABLE_DC_TOOLS:-false}"
export ENABLE_BUILD_TESTING="${ENABLE_BUILD_TESTING:-false}"
export ENABLE_ROCPROFSYS="${ENABLE_ROCPROFSYS:-false}"  # Phase 1: OFF; build with GCC separately if desired

exec "${ROOT}/build_gfx1031.sh" configure "$@"

