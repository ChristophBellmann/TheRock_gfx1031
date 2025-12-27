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

    # Note: rocm/llama.cpp images are typically "wrapper" images where the entrypoint expects commands like
    # `--run` / `--bench`. We don't treat `--help` output as authoritative (it may print "Unknown command").
    rr = run_cmd(ctx.repo_root, env, ["docker", "run", "--rm", image, "--help"], 60, log)
    if rr.rc != 0:
        return StepResult(build_dir, "llama.cpp (docker) smoke", "FAIL", fmt_duration(rp.dur_ms + rr.dur_ms), f"docker run --help rc={rr.rc}")

    # Optional inference smoke: enabled if a model_url is configured.
    wl = cfg.get("workloads", {}).get("llama_cpp", {}) if isinstance(cfg.get("workloads", {}), dict) else {}
    model_url = str(wl.get("model_url", "")).strip()
    if not model_url:
        require = bool(wl.get("require_inference", False))
        status = "FAIL" if require else "OK"
        hint = "missing workloads.llama_cpp.model_url (GGUF) [required]" if require else "set workloads.llama_cpp.model_url to enable inference"
        return StepResult(build_dir, "llama.cpp (docker) smoke", status, fmt_duration(rp.dur_ms + rr.dur_ms), f"image={image} ({hint})")

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
    # For llama-bench we don't need a concrete prompt string, but we keep the file in the metric
    # so users can quickly discover which prompt/config was used.
    _ = read_small_text(prompt_path)

    # Some prebuilt ROCm binaries include HIP code objects for gfx1030 but not gfx1031.
    # When running those images on gfx1031, spoofing can avoid GPU discovery failures.
    arch = str(cfg.get("rocm", {}).get("amd_gpu_arch", "")).strip()
    hsa_override = "10.3.0" if arch == "gfx1031" else ""

    # Inference knobs (aim for a sustained run so power sampling is meaningful).
    num_predict = int(cfg.get("workloads", {}).get("llama_cpp", {}).get("num_predict", 512) or 512)
    min_bench_s = float(cfg.get("workloads", {}).get("llama_cpp", {}).get("min_bench_s", 5.0) or 5.0)
    # Prefer llama-bench because some wrapper images enable interactive mode for `--run` by default,
    # which can terminate early in non-tty contexts. llama-bench prints stable performance numbers.
    bench_repetitions = int(wl.get("bench_repetitions", 5) or 5)
    if bench_repetitions < 1:
        bench_repetitions = 1

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
        cmd = [
            "docker",
            "run",
            "--rm",
            "--device=/dev/kfd",
            "--device=/dev/dri",
            "--group-add",
            "video",
            "--group-add",
            "render",
            *([] if not hsa_override else ["-e", f"HSA_OVERRIDE_GFX_VERSION={hsa_override}"]),
            "-v",
            f"{model_path}:/model.gguf:ro",
            image,
            "--bench",
            "-m",
            "/model.gguf",
            "-o",
            "json",
            "-r",
            str(bench_repetitions),
            "-p",
            "512",
            "-n",
            str(num_predict),
            "-ngl",
            "99",
        ]

    ti = int(cfg.get("timeouts_s", {}).get("llama_cpp_infer", 600))

    def run_one(sampler):
        t0 = time.monotonic()
        r = run_cmd(ctx.repo_root, env, cmd, ti, log)
        wall_s = time.monotonic() - t0
        return r, wall_s, sampler

    ri, wall_s, sampler = with_power_sampler(cfg, build_dir=build_dir, fn=run_one)
    status = "OK" if ri.rc == 0 else "FAIL"
    metric = f"image={image} model={model_path.name} bench=pp512+tg{num_predict} r={bench_repetitions} wall={wall_s:.2f}s prompt_file={prompt_path.name}"
    if wall_s < min_bench_s:
        metric += f" (short<{min_bench_s:.0f}s; increase workloads.llama_cpp.num_predict)"

    # Parse llama-bench JSON output for prompt-processing and generation speeds.
    # We keep it regex-based to avoid adding dependencies.
    out = (ri.out or "") + "\n" + (ri.err or "")
    out_parse = out
    if (('"avg_ts"' not in out_parse) or ('"backends"' not in out_parse)) and log is not None and log.exists():
        try:
            out_parse = out_parse + "\n" + log.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            pass

    m_pp = re.search(r'"n_prompt"\s*:\s*512\s*,[\s\S]*?"avg_ts"\s*:\s*([0-9.]+)', out_parse)
    m_tg = re.search(r'"n_gen"\s*:\s*' + re.escape(str(num_predict)) + r'\s*,[\s\S]*?"avg_ts"\s*:\s*([0-9.]+)', out_parse)
    if m_pp:
        metric += f" pp_tok/s={float(m_pp.group(1)):.2f}"
    if m_tg:
        metric += f" tg_tok/s={float(m_tg.group(1)):.2f}"
    m_backend = re.search(r'"backends"\s*:\s*"([^"]+)"', out_parse)
    if m_backend and "ROCm" not in m_backend.group(1):
        status = "FAIL"
        metric = f"CPU fallback (backends={m_backend.group(1)}) | {metric}"

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
