from __future__ import annotations

import os
import sys
import time
from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.rocm_env import which
from core.runner import fmt_duration, run_cmd
from steps.shared import append_power, baseline_avg_w, with_power_sampler
from steps.workloads.petsc.fetch import ensure_petsc_source


def step_petsc_hip(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    """
    Build PETSc with HIP and run a small KSP solve on GPU.

    This is intended as an end-to-end FEM/linear-solver style validation.
    """
    if which("make", env) is None:
        return StepResult(build_dir, "PETSc (HIP) build+solve", "SKIP", "0ms", "missing make (install system packages)")
    if which("git", env) is None:
        return StepResult(build_dir, "PETSc (HIP) build+solve", "SKIP", "0ms", "missing git (install system packages)")

    src, meta = ensure_petsc_source(ctx, cfg, env, log)
    if meta is not None:
        return StepResult(build_dir, "PETSc (HIP) build+solve", meta.status, meta.duration, meta.metric)
    if src is None:
        return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", "0ms", "PETSc source unavailable")

    arch = str(cfg.get("rocm", {}).get("amd_gpu_arch", "gfx1031"))
    petsc_arch = f"arch-hip-{arch}"

    # Configure once (idempotent).
    arch_dir = src / petsc_arch
    cfg_ok = (arch_dir / "lib").is_dir() and (arch_dir / "include").is_dir()
    if not cfg_ok:
        t_cfg = int(cfg.get("timeouts_s", {}).get("petsc_configure", 3600))
        # Keep the configuration minimal and reproducible:
        # - serial build (no MPI)
        # - download a small BLAS/LAPACK to avoid external deps
        # - HIP enabled + arch pinned
        cfg_cmd = [
            sys.executable,
            "configure",
            f"--PETSC_ARCH={petsc_arch}",
            "--with-debugging=0",
            "--with-mpi=0",
            "--download-fblaslapack=1",
            "--with-hip=1",
            f"--with-hip-arch={arch}",
            f"--with-hip-dir={rocm_dist}",
        ]
        r0 = run_cmd(src, env, cfg_cmd, t_cfg, log)
        if r0.rc != 0:
            return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r0.dur_ms), f"configure rc={r0.rc}")

    t_build = int(cfg.get("timeouts_s", {}).get("petsc_build", 7200))
    r1 = run_cmd(src, env, ["make", f"PETSC_DIR={src}", f"PETSC_ARCH={petsc_arch}", "-j4", "all"], t_build, log)
    if r1.rc != 0:
        return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms), f"make all rc={r1.rc}")

    # Build a tutorial KSP example (ex2) and run it using HIP vectors/matrices.
    ex_dir = src / "src" / "ksp" / "ksp" / "tutorials"
    ex_path = ex_dir / "ex2"
    r2 = run_cmd(src, env, ["make", f"PETSC_DIR={src}", f"PETSC_ARCH={petsc_arch}", "-C", str(ex_dir), "ex2"], t_build, log)
    if r2.rc != 0:
        return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms), f"make ex2 rc={r2.rc}")
    if not ex_path.exists():
        return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms), "ex2 not found after build")

    min_s = float(cfg.get("workloads", {}).get("petsc", {}).get("min_bench_s", 5.0) or 5.0)

    # Run with GPU types; repeat runs until we reach min_s for a clean power signal.
    # ex2 uses a DA-based Poisson-like system. Size is chosen to be heavy enough but
    # avoid VRAM pressure on consumer GPUs.
    base_args = [
        str(ex_path),
        "-da_grid_x",
        "512",
        "-da_grid_y",
        "512",
        "-ksp_type",
        "cg",
        "-pc_type",
        "jacobi",
        "-ksp_rtol",
        "1e-8",
        "-vec_type",
        "hip",
        "-mat_type",
        "aijhipsparse",
        "-log_view",
        ":ascii_info",
    ]

    def run_one(sampler):
        t0 = time.monotonic()
        total = 0.0
        runs = 0
        last = None
        while total < min_s:
            r = run_cmd(src, env, base_args, 600, log)
            last = r
            runs += 1
            total = time.monotonic() - t0
            if r.rc != 0:
                break
        wall_s = time.monotonic() - t0
        return last or run_cmd(src, env, base_args, 600, log), wall_s, sampler

    r3, wall_s, sampler = with_power_sampler(cfg, build_dir=build_dir, fn=run_one)
    if r3.rc != 0:
        return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), f"run rc={r3.rc}")

    out = (r3.out + "\n" + r3.err)
    # Heuristic: prove that HIP vectors/matrices were actually selected.
    if "Vec Type: hip" not in out and "aijhipsparse" not in out.lower():
        return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), "cannot confirm HIP vec/mat types from output")

    metric = f"ex2 da=512x512 wall={wall_s:.2f}s vec=hip mat=aijhipsparse"
    metric = append_power(metric, sampler, baseline_w=baseline_avg_w(cfg, build_dir))

    if sampler is not None:
        gpu = sampler.avg_gpu_busy()
        base_w = baseline_avg_w(cfg, build_dir) or 0.0
        avgw = sampler.avg_power_w() or 0.0
        if (gpu is not None and gpu < 10) and (avgw - base_w) < 10:
            return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), f"no clear GPU activity detected | {metric}")

    return StepResult(build_dir, "PETSc (HIP) build+solve", "OK", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), metric)
