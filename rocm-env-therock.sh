#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROCM_PATH="${ROCM_PATH:-$SCRIPT_DIR/build/dist/rocm}"

if [ -f "$SCRIPT_DIR/.venv/bin/activate" ]; then
  if [ -z "${VIRTUAL_ENV:-}" ]; then
    # Activate venv for local cmake/ninja helpers when present.
    source "$SCRIPT_DIR/.venv/bin/activate"
  fi
fi

if [ ! -d "${ROCM_PATH}" ]; then
  echo "ROCM_PATH not found: ${ROCM_PATH}" >&2
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 1
  fi
  exit 1
fi

export ROCM_PATH
export HIP_PATH="${HIP_PATH:-$ROCM_PATH}"
export HSA_PATH="${HSA_PATH:-$ROCM_PATH}"
export THEROCK_BIN_DIR="${THEROCK_BIN_DIR:-$ROCM_PATH/bin}"
if [ -z "${HIP_DEVICE_LIB_PATH:-}" ]; then
  if [ -d "$ROCM_PATH/lib/llvm/amdgcn/bitcode" ]; then
    export HIP_DEVICE_LIB_PATH="$ROCM_PATH/lib/llvm/amdgcn/bitcode"
  else
    export HIP_DEVICE_LIB_PATH="$ROCM_PATH/amdgcn/bitcode"
  fi
fi

export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:${PATH:-}"
export LD_LIBRARY_PATH="$ROCM_PATH/lib:$ROCM_PATH/lib64:$ROCM_PATH/lib/rocm_sysdeps/lib:$ROCM_PATH/llvm/lib:${LD_LIBRARY_PATH:-}"

echo "Activated in-tree ROCm: ${ROCM_PATH}"
