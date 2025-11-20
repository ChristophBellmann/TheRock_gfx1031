#!/bin/bash
# ROCm environment configuration
# Source this file or add to /etc/profile.d/rocm.sh

export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export PATH=/opt/rocm/bin:/opt/rocm/lib/llvm/bin:$PATH
export LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:/opt/rocm/lib/llvm/lib:$LD_LIBRARY_PATH

# HIP settings
export HIP_PLATFORM=amd
export HIP_COMPILER=clang

# Device library path for hipcc
export HIP_DEVICE_LIB_PATH=/opt/rocm/lib/llvm/amdgcn/bitcode

# HSA settings (adjust as needed for your GPU)
export HSA_OVERRIDE_GFX_VERSION=10.3.0
export HSA_XNACK=0
export HSA_ENABLE_SDMA=0
