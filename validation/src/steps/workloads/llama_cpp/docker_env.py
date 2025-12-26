from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Any

from core.context import Context
from core.download import download
from core.reporting.models import StepResult
from core.rocm_env import which
from core.runner import fmt_duration, run_cmd
from steps.shared import append_power, baseline_avg_w, dl_policy, downloads_enabled, read_small_text, with_power_sampler


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
        # Docs HTML contains concrete tags like:
        #   rocm/llama.cpp:llama.cpp-..._ubuntu22.04_full
        tags = re.findall(r"rocm/llama\.cpp:([a-zA-Z0-9._-]+_(?:server|full|light))", r.out)
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

    # Some prebuilt ROCm binaries include HIP code objects for gfx1030 but not gfx1031.
    # When running those images on gfx1031, spoofing can avoid GPU discovery failures.
    arch = str(cfg.get("rocm", {}).get("amd_gpu_arch", "")).strip()
    hsa_override = "10.3.0" if arch == "gfx1031" else ""

    # Inference knobs (aim for a sustained run so power sampling is meaningful).
    num_predict = int(cfg.get("workloads", {}).get("llama_cpp", {}).get("num_predict", 512) or 512)
    min_bench_s = float(cfg.get("workloads", {}).get("llama_cpp", {}).get("min_bench_s", 5.0) or 5.0)

    # Best-effort: try common llama.cpp CLI entrypoints inside the container.
    # Users can override by setting workloads.llama_cpp.docker_cmd.
    docker_cmd = wl.get("docker_cmd")
    if docker_cmd:
        cmd = [
            "docker",
            "run",
            "--rm",
            "--device=/dev/kfd",
            "--device=/dev/dri",
            "--group-add",
            "video",
            *([] if not hsa_override else ["-e", f"HSA_OVERRIDE_GFX_VERSION={hsa_override}"]),
            "-v",
            f"{model_path}:/model.gguf:ro",
            image,
        ] + list(docker_cmd)
    else:
        # Prefer offload flags when supported; fall back if options are unknown.
        # We avoid assuming a specific entrypoint; the image should include llama-cli or ./main.
        prompt_escaped = prompt.replace('"', '\\"')
        cmd = [
            "docker",
            "run",
            "--rm",
            "--device=/dev/kfd",
            "--device=/dev/dri",
            "--group-add",
            "video",
            *([] if not hsa_override else ["-e", f"HSA_OVERRIDE_GFX_VERSION={hsa_override}"]),
            "-v",
            f"{model_path}:/model.gguf:ro",
            image,
            "bash",
            "-lc",
            # Try llama-cli first, then ./main.
            "("
            f'command -v llama-cli && (llama-cli -m /model.gguf -p "{prompt_escaped}" -n {num_predict} -ngl 999 || '
            f'llama-cli -m /model.gguf -p "{prompt_escaped}" -n {num_predict})'
            ") || ("
            f'test -x ./main && (./main -m /model.gguf -p "{prompt_escaped}" -n {num_predict} -ngl 999 || '
            f'./main -m /model.gguf -p "{prompt_escaped}" -n {num_predict})'
            ")",
        ]

    ti = int(cfg.get("timeouts_s", {}).get("llama_cpp_infer", 600))

    def run_one(sampler):
        t0 = time.monotonic()
        r = run_cmd(ctx.repo_root, env, cmd, ti, log)
        wall_s = time.monotonic() - t0
        return r, wall_s, sampler

    ri, wall_s, sampler = with_power_sampler(cfg, build_dir=build_dir, fn=run_one)
    status = "OK" if ri.rc == 0 else "FAIL"
    metric = f"image={image} model={model_path.name} out={num_predict} wall={wall_s:.2f}s prompt_file={prompt_path.name}"
    if wall_s < min_bench_s:
        metric += f" (short<{min_bench_s:.0f}s; increase workloads.llama_cpp.num_predict)"

    # Best-effort: parse tokens/s when the binary prints timings.
    m = re.search(r"tokens per second\\s*[:=]\\s*([0-9.]+)", ri.out + "\n" + ri.err, re.IGNORECASE)
    if m:
        metric += f" tok/s={float(m.group(1)):.2f}"

    metric = append_power(metric, sampler, baseline_w=baseline_avg_w(cfg, build_dir))

    if ri.rc != 0:
        metric += f" rc={ri.rc}"
        return StepResult(build_dir, "llama.cpp (docker) smoke", "FAIL", fmt_duration(rp.dur_ms + rr.dur_ms + ri.dur_ms), metric)

    # Hard requirement: must show *some* GPU activity for a GPU-enabled docker image.
    if sampler is not None:
        gpu = sampler.avg_gpu_busy()
        base_w = baseline_avg_w(cfg, build_dir) or 0.0
        avgw = sampler.avg_power_w() or 0.0
        if (gpu is not None and gpu < 5) and (avgw - base_w) < 5:
            return StepResult(build_dir, "llama.cpp (docker) smoke", "FAIL", fmt_duration(rp.dur_ms + rr.dur_ms + ri.dur_ms), f"no GPU activity detected | {metric}")

    return StepResult(build_dir, "llama.cpp (docker) smoke", status, fmt_duration(rp.dur_ms + rr.dur_ms + ri.dur_ms), metric)
