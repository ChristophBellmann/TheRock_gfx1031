from __future__ import annotations

import os
from pathlib import Path

from .utils import REPO_ROOT


def choose_default_build_dir() -> str:
    for d in ["build-stage2", "build", "build-stage1"]:
        if (REPO_ROOT / d / "dist" / "rocm").is_dir():
            return d
    return "build-stage2"


def activated_env(build_dir: str) -> dict[str, str]:
    rocm = REPO_ROOT / build_dir / "dist" / "rocm"
    env = os.environ.copy()
    env["ROCM_PATH"] = str(rocm)
    env.setdefault("HIP_PATH", str(rocm))
    env.setdefault("HSA_PATH", str(rocm))
    env["PATH"] = f"{rocm}/bin:{rocm}/llvm/bin:{env.get('PATH', '')}"
    env["LD_LIBRARY_PATH"] = (
        f"{rocm}/lib:{rocm}/lib64:{rocm}/lib/host-math/lib:{rocm}/lib/rocm_sysdeps/lib:{rocm}/llvm/lib:"
        f"{env.get('LD_LIBRARY_PATH', '')}"
    )
    if "HIP_DEVICE_LIB_PATH" not in env:
        p1 = rocm / "lib" / "llvm" / "amdgcn" / "bitcode"
        p2 = rocm / "amdgcn" / "bitcode"
        env["HIP_DEVICE_LIB_PATH"] = str(p1 if p1.is_dir() else p2)
    return env

