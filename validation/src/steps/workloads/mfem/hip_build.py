from __future__ import annotations

from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.rocm_env import which
from core.runner import fmt_duration, run_cmd
from steps.workloads.mfem.fetch import ensure_mfem_source


def step_mfem_hip(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    if which("cmake", env) is None or which("ninja", env) is None:
        return StepResult(build_dir, "MFEM (HIP) build+run", "SKIP", "0ms", "missing cmake/ninja (install system packages)")
    if which("hipcc", env) is None:
        return StepResult(build_dir, "MFEM (HIP) build+run", "SKIP", "0ms", "hipcc not in PATH (need Stage-2 dist)")

    src, meta = ensure_mfem_source(ctx, cfg, env, log)
    if meta is not None:
        return StepResult(build_dir, "MFEM (HIP) build+run", meta.status, meta.duration, meta.metric)
    if src is None:
        return StepResult(build_dir, "MFEM (HIP) build+run", "FAIL", "0ms", "MFEM source unavailable")

    t = int(cfg.get("timeouts_s", {}).get("mfem_hip", 3600))
    bld = ctx.builds_dir() / "mfem"
    bld.mkdir(parents=True, exist_ok=True)

    hipcc = which("hipcc", env) or "hipcc"
    clangxx = str(rocm_dist / "llvm" / "bin" / "clang++")
    arch = str(cfg.get("rocm", {}).get("amd_gpu_arch", "gfx1031"))

    cfg_cmd = [
        "cmake",
        "-S",
        str(src),
        "-B",
        str(bld),
        "-G",
        "Ninja",
        "-DMFEM_USE_HIP=YES",
        f"-DHIP_ARCH={arch}",
        f"-DCMAKE_CXX_COMPILER={clangxx}",
        f"-DCMAKE_HIP_COMPILER={hipcc}",
    ]
    r1 = run_cmd(ctx.repo_root, env, cfg_cmd, 600, log)
    if r1.rc != 0:
        return StepResult(build_dir, "MFEM (HIP) build+run", "FAIL", fmt_duration(r1.dur_ms), f"cmake rc={r1.rc}")
    r2 = run_cmd(ctx.repo_root, env, ["ninja", "-C", str(bld), "-j4"], t, log)
    if r2.rc != 0:
        return StepResult(build_dir, "MFEM (HIP) build+run", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms), f"ninja rc={r2.rc}")

    ex1 = bld / "examples" / "ex1"
    if not ex1.exists():
        ex1 = bld / "bin" / "ex1"
    if not ex1.exists():
        return StepResult(build_dir, "MFEM (HIP) build+run", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms), "MFEM ex1 not found after build")
    r3 = run_cmd(ctx.repo_root, env, [str(ex1), "-m", str(src / "data" / "star.mesh")], 60, log)
    return StepResult(
        build_dir,
        "MFEM (HIP) build+run",
        "OK" if r3.rc == 0 else "FAIL",
        fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms),
        "ex1 star.mesh" if r3.rc == 0 else f"run rc={r3.rc}",
    )
