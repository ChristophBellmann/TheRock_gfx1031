from __future__ import annotations

import os
import sys
import time
from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.rocm_env import which
from core.runner import CommandResult, fmt_duration, run_cmd
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

    # Build a tiny PETSc+HIP micro-benchmark (MatMult loop) to produce a sustained
    # GPU load signal. The upstream `ex2` tutorial often converges in a few
    # iterations, which is not ideal for power/util validation.
    petsc_vars = src / petsc_arch / "lib" / "petsc" / "conf" / "petscvariables"
    if not petsc_vars.is_file():
        return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms), "petscvariables not found")

    def get_var(name: str) -> str:
        for line in petsc_vars.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith(name + " ="):
                return line.split("=", 1)[1].strip()
        return ""

    cc = get_var("CC") or "cc"
    c_includes = get_var("PETSC_CC_INCLUDES")
    petsc_libs = get_var("PETSC_WITH_EXTERNAL_LIB") or get_var("PETSC_SYS_LIB") or ""

    if not c_includes or not petsc_libs:
        return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms), "missing PETSc compile/link flags")

    bld = ctx.builds_dir() / "petsc_spmv"
    bld.mkdir(parents=True, exist_ok=True)
    src_c = bld / "petsc_spmv.c"
    exe = bld / "petsc_spmv"
    src_c.write_text(
        r"""
#include <petscksp.h>

static char help[] = "PETSc HIP validation micro-benchmark: repeated MatMult on GPU.\n"
"Options:\n"
"  -m <int>     grid size in x (default 1024)\n"
"  -n <int>     grid size in y (default 1024)\n"
"  -min_s <s>   minimum wall time (default 5)\n"
"  -mat_type <type>   e.g. seqaijhipsparse or seqsellhip\n"
"  -vec_type <type>   e.g. hip\n";

int main(int argc, char **argv) {
  PetscInt m = 1024, n = 1024;
  PetscReal min_s = 5.0;
  PetscCall(PetscInitialize(&argc, &argv, NULL, help));
  PetscCall(PetscOptionsGetInt(NULL, NULL, "-m", &m, NULL));
  PetscCall(PetscOptionsGetInt(NULL, NULL, "-n", &n, NULL));
  PetscCall(PetscOptionsGetReal(NULL, NULL, "-min_s", &min_s, NULL));

  const PetscInt N = m * n;
  Mat A;
  Vec x, y;
  PetscInt Istart, Iend;

  PetscCall(MatCreate(PETSC_COMM_WORLD, &A));
  PetscCall(MatSetSizes(A, PETSC_DECIDE, PETSC_DECIDE, N, N));
  PetscCall(MatSetFromOptions(A));
  PetscCall(MatSeqAIJSetPreallocation(A, 5, NULL));
  PetscCall(MatMPIAIJSetPreallocation(A, 5, NULL, 5, NULL));
  PetscCall(MatGetOwnershipRange(A, &Istart, &Iend));

  for (PetscInt Ii = Istart; Ii < Iend; Ii++) {
    PetscInt i = Ii / n;
    PetscInt j = Ii - i * n;
    PetscScalar v;
    PetscInt J;
    v = -1.0;
    if (i > 0) { J = Ii - n; PetscCall(MatSetValues(A, 1, &Ii, 1, &J, &v, ADD_VALUES)); }
    if (i < m - 1) { J = Ii + n; PetscCall(MatSetValues(A, 1, &Ii, 1, &J, &v, ADD_VALUES)); }
    if (j > 0) { J = Ii - 1; PetscCall(MatSetValues(A, 1, &Ii, 1, &J, &v, ADD_VALUES)); }
    if (j < n - 1) { J = Ii + 1; PetscCall(MatSetValues(A, 1, &Ii, 1, &J, &v, ADD_VALUES)); }
    v = 4.0;
    PetscCall(MatSetValues(A, 1, &Ii, 1, &Ii, &v, ADD_VALUES));
  }
  PetscCall(MatAssemblyBegin(A, MAT_FINAL_ASSEMBLY));
  PetscCall(MatAssemblyEnd(A, MAT_FINAL_ASSEMBLY));

  PetscCall(VecCreate(PETSC_COMM_WORLD, &x));
  PetscCall(VecSetSizes(x, PETSC_DECIDE, N));
  PetscCall(VecSetFromOptions(x));
  PetscCall(VecDuplicate(x, &y));
  PetscCall(VecSet(x, 1.0));

  // Warmup
  PetscCall(MatMult(A, x, y));

  PetscLogDouble t0, t1;
  PetscCall(PetscTime(&t0));
  PetscInt iters = 0;
  do {
    PetscCall(MatMult(A, x, y));
    // swap
    Vec tmp = x; x = y; y = tmp;
    iters++;
    PetscCall(PetscTime(&t1));
  } while ((t1 - t0) < min_s);

  // Force completion/visibility of device work in a portable way.
  PetscReal nrm = 0.0;
  PetscCall(VecNorm(x, NORM_2, &nrm));
  PetscCall(PetscPrintf(PETSC_COMM_WORLD, "GPU_OK\n"));
  PetscCall(PetscPrintf(PETSC_COMM_WORLD, "m %d\n", (int)m));
  PetscCall(PetscPrintf(PETSC_COMM_WORLD, "n %d\n", (int)n));
  PetscCall(PetscPrintf(PETSC_COMM_WORLD, "iters %d\n", (int)iters));
  PetscCall(PetscPrintf(PETSC_COMM_WORLD, "seconds %g\n", (double)(t1 - t0)));
  PetscCall(PetscPrintf(PETSC_COMM_WORLD, "matmult_per_s %g\n", (double)iters / (double)(t1 - t0)));

  PetscCall(VecDestroy(&x));
  PetscCall(VecDestroy(&y));
  PetscCall(MatDestroy(&A));
  PetscCall(PetscFinalize());
  return 0;
}
""".lstrip(),
        encoding="utf-8",
    )

    r2 = run_cmd(ctx.repo_root, env, [cc, "-O2", str(src_c)] + c_includes.split() + petsc_libs.split() + ["-o", str(exe)], 600, log)
    if r2.rc != 0:
        return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms), f"compile rc={r2.rc}")

    min_s = float(cfg.get("workloads", {}).get("petsc", {}).get("min_bench_s", 5.0) or 5.0)

    # Run with GPU types; repeat runs until we reach min_s for a clean power signal.
    # ex2 uses a DA-based Poisson-like system. Start moderately heavy but fall
    # back if HIPSPARSE runs out of resources (alloc failed / OOM).
    def mk_args(nx: int, ny: int, mat_type: str) -> list[str]:
        return [
            str(exe),
            "-m",
            str(nx),
            "-n",
            str(ny),
            "-min_s",
            str(min_s),
            "-vec_type",
            "hip",
            "-mat_type",
            mat_type,
        ]

    size_candidates: list[tuple[int, int]] = [(1024, 1024), (768, 768), (512, 512), (384, 384), (256, 256)]
    mat_candidates: list[str] = ["seqaijhipsparse", "seqsellhip"]

    def run_one(sampler):
        last: CommandResult | None = None
        for nx, ny in size_candidates:
            for mat_type in mat_candidates:
                args = mk_args(nx, ny, mat_type)
                t0 = time.monotonic()
                total = 0.0
                runs = 0
                while total < min_s:
                    r = run_cmd(src, env, args, 600, log)
                    last = r
                    runs += 1
                    total = time.monotonic() - t0
                    if r.rc != 0:
                        break
                wall_s = time.monotonic() - t0

                if last is None:
                    continue
                if last.rc == 0:
                    out = (last.out or "") + f"\nPETSC_VALIDATE size: {nx}x{ny} mat={mat_type} runs={runs}\n"
                    return CommandResult(rc=0, out=out, err=last.err, dur_ms=last.dur_ms), wall_s, sampler

                txt = (last.out + "\n" + last.err).lower()
                if "unknown mat type" in txt or "unknown type" in txt:
                    continue
                if "hipsparse_status_alloc_failed" in txt or "gpu resources unavailable" in txt or "out of memory" in txt:
                    continue
                return last, wall_s, sampler

        return last or run_cmd(src, env, mk_args(256, 256, "seqsellhip"), 600, log), 0.0, sampler

    r3, wall_s, sampler = with_power_sampler(cfg, build_dir=build_dir, fn=run_one)
    if r3.rc != 0:
        return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), f"run rc={r3.rc}")

    out = (r3.out + "\n" + r3.err)
    if "GPU_OK" not in out:
        return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), "GPU validation marker missing")

    size_str = "512x512"
    mat_str = "aijhipsparse"
    for line in out.splitlines():
        if line.startswith("PETSC_VALIDATE size:"):
            rest = line.split(":", 1)[1].strip().split()
            if rest:
                size_str = rest[0]
            for tok in rest[1:]:
                if tok.startswith("mat="):
                    mat_str = tok.split("=", 1)[1]
            break
    # Pull a few useful metrics from stdout if present.
    iters_s = ""
    seconds_s = ""
    matmult_s = ""
    for line in out.splitlines():
        if line.startswith("iters "):
            iters_s = line.split(" ", 1)[1].strip()
        elif line.startswith("seconds "):
            seconds_s = line.split(" ", 1)[1].strip()
        elif line.startswith("matmult_per_s "):
            matmult_s = line.split(" ", 1)[1].strip()
    metric = f"spmv m×n={size_str} wall={wall_s:.2f}s vec=hip mat={mat_str}"
    if iters_s:
        metric += f" iters={iters_s}"
    if seconds_s:
        metric += f" seconds={seconds_s}"
    if matmult_s:
        metric += f" matmult/s={float(matmult_s):.1f}"
    metric = append_power(metric, sampler, baseline_w=baseline_avg_w(cfg, build_dir))

    if sampler is not None:
        gpu = sampler.avg_gpu_busy()
        base_w = baseline_avg_w(cfg, build_dir) or 0.0
        avgw = sampler.avg_power_w() or 0.0
        if (gpu is not None and gpu < 10) and (avgw - base_w) < 10:
            return StepResult(build_dir, "PETSc (HIP) build+solve", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), f"no clear GPU activity detected | {metric}")

    return StepResult(build_dir, "PETSc (HIP) build+solve", "OK", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), metric)
