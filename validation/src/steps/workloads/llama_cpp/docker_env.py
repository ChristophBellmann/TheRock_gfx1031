from __future__ import annotations

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.rocm_env import which
from core.runner import fmt_duration, run_cmd
from steps.shared import downloads_enabled


def step_llama_cpp_docker(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    if not downloads_enabled(cfg):
        return StepResult(build_dir, "llama.cpp (docker) smoke", "SKIP", "0ms", "downloads disabled")
    if which("docker", env) is None:
        return StepResult(build_dir, "llama.cpp (docker) smoke", "SKIP", "0ms", "docker not installed or not in PATH")

    # Allow overriding the image tag for reproducibility.
    cfg_image = str(cfg.get("workloads", {}).get("llama_cpp", {}).get("docker_image", "")).strip()
    image = cfg_image or env.get("ROCM_VALIDATION_LLAMA_CPP_IMAGE", "").strip()
    if not image:
        url = "https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/3rd-party/llama-cpp-install.html"
        r = run_cmd(ctx.repo_root, env, ["bash", "-lc", f"curl -fsSL {url!s}"], 30, log)
        if r.rc != 0:
            return StepResult(build_dir, "llama.cpp (docker) smoke", "FAIL", fmt_duration(r.dur_ms), f"failed to fetch docs rc={r.rc}")
        tags = re.findall(r"rocm/llama\\.cpp:([a-zA-Z0-9._-]+_(?:server|full|light))", r.out)
        if not tags:
            return StepResult(
                build_dir,
                "llama.cpp (docker) smoke",
                "FAIL",
                fmt_duration(r.dur_ms),
                "no rocm/llama.cpp tag found in docs HTML (set ROCM_VALIDATION_LLAMA_CPP_IMAGE or workloads.llama_cpp.docker_image)",
            )
        image = f"rocm/llama.cpp:{tags[0]}"

    rp = run_cmd(ctx.repo_root, env, ["docker", "pull", image], int(cfg.get("timeouts_s", {}).get("llama_cpp_docker", 900)), log)
    if rp.rc != 0:
        return StepResult(build_dir, "llama.cpp (docker) smoke", "FAIL", fmt_duration(rp.dur_ms), f"docker pull rc={rp.rc}")

    rr = run_cmd(ctx.repo_root, env, ["docker", "run", "--rm", image, "--help"], 60, log)
    return StepResult(build_dir, "llama.cpp (docker) smoke", "OK" if rr.rc == 0 else "FAIL", fmt_duration(rp.dur_ms + rr.dur_ms), f"image={image}")
