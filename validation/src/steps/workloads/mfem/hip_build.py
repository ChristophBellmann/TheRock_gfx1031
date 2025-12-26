from __future__ import annotations

import time
from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.rocm_env import which
from core.runner import fmt_duration, run_cmd
from steps.workloads.mfem.fetch import ensure_mfem_source
from steps.shared import append_power, baseline_avg_w, with_power_sampler


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

    mesh = src / "data" / "star.mesh"
    # Detect runtime flags from help, so we can request HIP device when supported.
    h = run_cmd(ctx.repo_root, env, [str(ex1), "-h"], 20, log)
    help_txt = (h.out + "\n" + h.err)
    have_device_flag = ("-d " in help_txt) or ("--device" in help_txt)
    have_refine_flag = ("-r " in help_txt) or ("--refine" in help_txt)
    have_order_flag = ("-o " in help_txt) or ("--order" in help_txt)

    run_args: list[str] = [str(ex1), "-m", str(mesh)]
    # Try to make it compute-heavy enough to sustain ~5s on a consumer GPU.
    if have_refine_flag:
        run_args += ["-r", "4"]
    if have_order_flag:
        run_args += ["-o", "3"]
    if have_device_flag:
        run_args += ["-d", "hip"]

    min_run_s = float(cfg.get("workloads", {}).get("mfem", {}).get("min_bench_s", 5.0) or 5.0)

    def run_one(sampler):
        t0 = time.monotonic()
        r = run_cmd(ctx.repo_root, env, run_args, 600, log)
        wall_s = time.monotonic() - t0
        return r, wall_s, sampler

    r3, wall_s, sampler = with_power_sampler(cfg, build_dir=build_dir, fn=run_one)
    metric = f"ex1 mesh={mesh.name} wall={wall_s:.2f}s"
    if have_device_flag:
        metric += " device=hip"
    else:
        metric += " device=(flag-missing)"
    metric = append_power(metric, sampler, baseline_w=baseline_avg_w(cfg, build_dir))

    if r3.rc != 0:
        return StepResult(build_dir, "MFEM (HIP) build+run", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), f"run rc={r3.rc} | {metric}")

    if not have_device_flag:
        return StepResult(build_dir, "MFEM (HIP) build+run", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), f"cannot force HIP device (unknown CLI flags) | {metric}")

    if wall_s < min_run_s:
        metric += f" (short<{min_run_s:.0f}s; increase mfem run size)"

    if sampler is not None:
        gpu = sampler.avg_gpu_busy()
        base_w = baseline_avg_w(cfg, build_dir) or 0.0
        avgw = sampler.avg_power_w() or 0.0
        if (gpu is not None and gpu < 5) and (avgw - base_w) < 5:
            return StepResult(build_dir, "MFEM (HIP) build+run", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), f"no GPU activity detected | {metric}")

    return StepResult(build_dir, "MFEM (HIP) build+run", "OK", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), metric)
