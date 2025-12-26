from __future__ import annotations

import os
from pathlib import Path


def activated_env(base_env: dict[str, str], rocm_dist: Path) -> dict[str, str]:
    env = dict(base_env)
    env["ROCM_PATH"] = str(rocm_dist)
    env.setdefault("HIP_PATH", str(rocm_dist))
    env.setdefault("HSA_PATH", str(rocm_dist))
    env["PATH"] = f"{rocm_dist}/bin:{rocm_dist}/llvm/bin:{env.get('PATH', '')}"
    env["LD_LIBRARY_PATH"] = (
        f"{rocm_dist}/lib:{rocm_dist}/lib64:{rocm_dist}/lib/host-math/lib:{rocm_dist}/lib/rocm_sysdeps/lib:{rocm_dist}/llvm/lib:"
        f"{env.get('LD_LIBRARY_PATH', '')}"
    )
    if "HIP_DEVICE_LIB_PATH" not in env:
        p1 = rocm_dist / "lib" / "llvm" / "amdgcn" / "bitcode"
        p2 = rocm_dist / "amdgcn" / "bitcode"
        env["HIP_DEVICE_LIB_PATH"] = str(p1 if p1.is_dir() else p2)
    return env


def which(exe: str, env: dict[str, str]) -> str | None:
    path = env.get("PATH", os.environ.get("PATH", ""))
    for p in path.split(":"):
        candidate = Path(p) / exe
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None

