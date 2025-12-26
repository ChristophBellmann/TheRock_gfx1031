from __future__ import annotations

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from core.context import Context
from core.download import download
from core.reporting.models import StepResult
from core.rocm_env import which
from core.runner import fmt_duration, run_cmd
from steps.shared import dl_policy, downloads_enabled, read_small_text


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
    if rr.rc != 0:
        return StepResult(build_dir, "llama.cpp (docker) smoke", "FAIL", fmt_duration(rp.dur_ms + rr.dur_ms), f"docker run --help rc={rr.rc}")

    # Optional inference smoke: only enabled if a model_url is configured.
    wl = cfg.get("workloads", {}).get("llama_cpp", {}) if isinstance(cfg.get("workloads", {}), dict) else {}
    model_url = str(wl.get("model_url", "")).strip()
    if not model_url:
        return StepResult(build_dir, "llama.cpp (docker) smoke", "OK", fmt_duration(rp.dur_ms + rr.dur_ms), f"image={image} (set workloads.llama_cpp.model_url to enable inference)")

    model_sha256 = str(wl.get("model_sha256", "")).strip() or None
    model_file_cfg = str(wl.get("model_file", "")).strip() or "validation/workspace/cache/downloads/llama_cpp/model.gguf"
    model_path = (ctx.repo_root / model_file_cfg) if not Path(model_file_cfg).is_absolute() else Path(model_file_cfg)
    if not model_path.exists():
        try:
            download(ctx, model_url, model_path, expected_sha256=model_sha256, policy=dl_policy(cfg))
        except Exception as e:
            return StepResult(build_dir, "llama.cpp (docker) smoke", "FAIL", fmt_duration(rp.dur_ms + rr.dur_ms), f"model download failed: {e}")

    prompt_file = str(wl.get("prompt_file", "validation/src/assets/samples/prompts/tiny_prompt.txt"))
    prompt_path = (ctx.repo_root / prompt_file) if not Path(prompt_file).is_absolute() else Path(prompt_file)
    prompt = read_small_text(prompt_path).strip().splitlines()[0:1]
    prompt = prompt[0] if prompt else "Hello"

    # Best-effort: try common llama.cpp CLI entrypoints inside the container.
    # Users can override by setting workloads.llama_cpp.docker_cmd.
    docker_cmd = wl.get("docker_cmd")
    if docker_cmd:
        cmd = ["docker", "run", "--rm", "-v", f"{model_path}:/model.gguf:ro", image] + list(docker_cmd)
    else:
        cmd = [
            "docker",
            "run",
            "--rm",
            "-v",
            f"{model_path}:/model.gguf:ro",
            image,
            "bash",
            "-lc",
            # Try llama-cli first, then ./main.
            f'(command -v llama-cli && llama-cli -m /model.gguf -p "{prompt}" -n 32) || '
            f'(test -x ./main && ./main -m /model.gguf -p "{prompt}" -n 32)',
        ]

    ti = int(cfg.get("timeouts_s", {}).get("llama_cpp_infer", 600))
    ri = run_cmd(ctx.repo_root, env, cmd, ti, log)
    status = "OK" if ri.rc == 0 else "FAIL"
    metric = f"image={image} model={model_path.name} prompt_file={prompt_path.name}"
    if ri.rc != 0:
        metric += f" rc={ri.rc}"
    return StepResult(build_dir, "llama.cpp (docker) smoke", status, fmt_duration(rp.dur_ms + rr.dur_ms + ri.dur_ms), metric)
