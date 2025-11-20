#!/bin/bash
# ROCm environment - NATIVE gfx1031 (use for building from source)

export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export PATH=/opt/rocm/bin:/opt/rocm/lib/llvm/bin:$PATH
export LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:/opt/rocm/lib/llvm/lib:$LD_LIBRARY_PATH

# HIP settings
export HIP_PLATFORM=amd
export HIP_COMPILER=clang
export HIP_DEVICE_LIB_PATH=/opt/rocm/lib/llvm/amdgcn/bitcode

# Native GPU target (RX 6700 XT)
export AMDGPU_TARGETS=gfx1031
export GPU_ARCHS=gfx1031

# HSA settings for native target
# NO HSA_OVERRIDE - use native gfx1031
unset HSA_OVERRIDE_GFX_VERSION
export HSA_XNACK=0
export HSA_ENABLE_SDMA=0

# Performance tuning
export AMD_DIRECT_DISPATCH=0
export GPU_DEVICE_ORDINAL=0
export HIP_VISIBLE_DEVICES=0

echo "ROCm environment configured for NATIVE gfx1031 (RX 6700 XT)"
echo "Use this for: llama.cpp builds, TheRock builds, custom HIP applications"
