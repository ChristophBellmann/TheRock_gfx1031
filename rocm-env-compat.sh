#!/bin/bash
# ROCm environment - COMPATIBILITY mode with gfx1030 override
# Use for pre-built binaries (ollama, lmstudio, etc)

export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export PATH=/opt/rocm/bin:/opt/rocm/lib/llvm/bin:$PATH
export LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:/opt/rocm/lib/llvm/lib:$LD_LIBRARY_PATH

# HIP settings
export HIP_PLATFORM=amd
export HIP_COMPILER=clang
export HIP_DEVICE_LIB_PATH=/opt/rocm/lib/llvm/amdgcn/bitcode

# HSA override for compatibility (gfx1031 -> gfx1030)
export HSA_OVERRIDE_GFX_VERSION=10.3.0
export HSA_XNACK=0
export HSA_ENABLE_SDMA=0

# Performance tuning
export AMD_DIRECT_DISPATCH=0
export GPU_DEVICE_ORDINAL=0
export HIP_VISIBLE_DEVICES=0

echo "ROCm environment configured for COMPATIBILITY mode (gfx1030 override)"
echo "Use this for: ollama, lmstudio, pre-built ROCm binaries"
