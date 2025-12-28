from __future__ import annotations

import os
import shutil
import sys
import time
import re
from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.rocm_env import deactivated_env
from core.runner import fmt_duration, run_cmd
from steps.shared import append_power, baseline_avg_w, downloads_enabled, with_power_sampler


def _ffprobe_duration_s(env: dict[str, str], path: Path) -> float | None:
    ffprobe = shutil.which("ffprobe", path=env.get("PATH"))
    if not ffprobe:
        return None
    try:
        import subprocess

        r = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
        if r.returncode != 0:
            return None
        v = (r.stdout or "").strip()
        if not v:
            return None
        return float(v)
    except Exception:
        return None


def _ffmpeg_repeat_to_target(ctx: Context, env: dict[str, str], src: Path, *, out: Path, target_s: float, log: Path | None) -> tuple[Path, int]:
    """
    Create `out` by looping `src` to exactly `target_s` using ffmpeg.

    We use ffmpeg because the bundled sample may be a float WAV (format tag 3),
    which Python's `wave` module cannot read. Whisper already depends on ffmpeg
    for audio decoding, so this keeps the suite lightweight.
    """
    ffmpeg = shutil.which("ffmpeg", path=env.get("PATH"))
    if not ffmpeg:
        return src, 1
    out.parent.mkdir(parents=True, exist_ok=True)
    # Re-encode to PCM 16-bit mono 16kHz for deterministic size/compatibility.
    cmd = [
        ffmpeg,
        "-v",
        "error",
        "-y",
        "-stream_loop",
        "-1",
        "-i",
        str(src),
        "-t",
        str(int(target_s)),
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "pcm_s16le",
        str(out),
    ]
    r = run_cmd(ctx.repo_root, env, cmd, max(60, int(target_s)), log)
    if r.rc != 0 or not out.is_file():
        return src, 1
    dur = _ffprobe_duration_s(env, src)
    if dur and dur > 0:
        repeats = max(1, int((target_s + dur - 1e-9) // dur) + 1)
        return out, repeats
    return out, 2


def ensure_whisper(ctx: Context, cfg: dict[str, Any], env: dict[str, str], log: Path | None) -> StepResult | None:
    """
    Ensure the `whisper` Python package is available in the validation venv.

    Whisper depends on PyTorch; GPU validation still requires a ROCm-enabled torch.

    Auto-install is disabled by default because wheels can be large and platform-specific.
    Enable it via config:
      workloads.whisper.auto_install: true
      workloads.whisper.pip_args: [...]
      workloads.whisper.packages: ["openai-whisper"]
    """
    wl = cfg.get("workloads", {}).get("whisper", {}) or {}
    auto = bool(wl.get("auto_install", False))
    if not auto:
        return None

    # If whisper is already installed, proceed even when downloads are disabled.
    probe = run_cmd(ctx.repo_root, env, [sys.executable, "-c", "import whisper; print('ok')"], 30, log)
    if probe.rc == 0:
        return None
    if not downloads_enabled(cfg):
        return StepResult("<meta>", "Whisper setup", "SKIP", "0ms", "downloads disabled (cannot install whisper)")

    t = int(cfg.get("timeouts_s", {}).get("whisper", 1800))
    pip_args = list(wl.get("pip_args", []) or [])
    packages = list(wl.get("packages", []) or [])
    if not packages:
        packages = ["openai-whisper"]

    cmd = [sys.executable, "-m", "pip", "install"] + pip_args + packages
    r = run_cmd(ctx.repo_root, env, cmd, t, log)
    if r.rc != 0:
        return StepResult("<meta>", "Whisper setup", "FAIL", fmt_duration(r.dur_ms), f"pip rc={r.rc}")
    return None


def step_whisper(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    """
    Whisper smoke test (GPU required).

    - Optionally installs the Python `whisper` package if enabled via config
      (`workloads.whisper.auto_install: true`).
    - Requires ROCm-enabled PyTorch (torch.cuda.is_available == True and torch.version.hip present).
    - Runs a sustained transcription loop (~min_bench_s) on a small audio sample to make
      GPU acceleration visible in power/utilization metrics.
    """
    wl = cfg.get("workloads", {}).get("whisper", {}) or {}
    use_in_tree = bool(wl.get("use_in_tree_rocm", False))
    run_env = env if use_in_tree else deactivated_env(env, rocm_dist)

    meta = ensure_whisper(ctx, cfg, run_env, log)
    if meta is not None:
        return StepResult(build_dir, "Whisper (python) smoke", meta.status, meta.duration, meta.metric)

    t = int(cfg.get("timeouts_s", {}).get("whisper", 1800))
    min_bench_s = float(cfg.get("workloads", {}).get("whisper", {}).get("min_bench_s", 5.0) or 5.0)
    model_name = str(wl.get("model", "") or "").strip() or "tiny.en"
    beam_size = int(wl.get("beam_size", 5) or 5)
    best_of = int(wl.get("best_of", 5) or 5)
    audio_cfg = str(cfg.get("workloads", {}).get("whisper", {}).get("audio_file", "")).strip()
    audio_cfg = audio_cfg or "validation/src/assets/samples/audio/Take2_Audio1-1.wav"
    # Optional: build a longer audio sample by repeating the bundled WAV.
    # Allow env override for ad-hoc testing without editing YAML.
    audio_target_s = float(os.environ.get("ROCM_VALIDATION_WHISPER_AUDIO_TARGET_S", str(wl.get("audio_target_s", 0) or 0)) or 0)
    env = dict(run_env)

    audio_path = (Path(audio_cfg) if Path(audio_cfg).is_absolute() else (ctx.repo_root / audio_cfg)).resolve()
    repeats = 1
    if audio_target_s and audio_target_s > 0:
        out = ctx.builds_dir() / "whisper" / f"audio_repeat_{int(audio_target_s)}s.wav"
        try:
            audio_path, repeats = _ffmpeg_repeat_to_target(ctx, env, audio_path, out=out, target_s=audio_target_s, log=log)
            # Ensure we don't timeout trivially for very long targets.
            t = max(t, int(audio_target_s * 4))
        except Exception:
            # If anything goes wrong, fall back to the bundled sample.
            repeats = 1

    env["ROCM_VALIDATION_WHISPER_AUDIO"] = str(audio_path)
    env["ROCM_VALIDATION_WHISPER_MIN_S"] = str(min_bench_s)
    env["ROCM_VALIDATION_WHISPER_MODEL"] = model_name
    env["ROCM_VALIDATION_WHISPER_BEAM_SIZE"] = str(max(1, beam_size))
    env["ROCM_VALIDATION_WHISPER_BEST_OF"] = str(max(1, best_of))
    # Match PyTorch wheels that often ship gfx1030 but not gfx1031 code objects.
    if str(cfg.get("rocm", {}).get("amd_gpu_arch", "gfx1031")) == "gfx1031" and "HSA_OVERRIDE_GFX_VERSION" not in env:
        env["HSA_OVERRIDE_GFX_VERSION"] = "10.3.0"

    script = r"""
import os, time, sys
try:
    import torch
    import whisper
except Exception as e:
    print("IMPORT_ERROR", repr(e))
    raise

print("torch", getattr(torch, "__version__", ""))
print("torch.cuda.is_available", torch.cuda.is_available())
print("torch.version.hip", getattr(getattr(torch, "version", None), "hip", None))
if not torch.cuda.is_available():
    print("GPU_NOT_AVAILABLE")
    raise SystemExit(2)
if getattr(getattr(torch, "version", None), "hip", None) in (None, "", "None"):
    print("GPU_NOT_ROCM")
    raise SystemExit(3)

fname=os.environ.get("ROCM_VALIDATION_WHISPER_AUDIO", "")
if not (fname and os.path.isfile(fname)):
    print("AUDIO_MISSING")
    raise SystemExit(4)

min_s=float(os.environ.get("ROCM_VALIDATION_WHISPER_MIN_S","5"))
device="cuda"
model_name=os.environ.get("ROCM_VALIDATION_WHISPER_MODEL","tiny.en")
beam_size=int(os.environ.get("ROCM_VALIDATION_WHISPER_BEAM_SIZE","5"))
best_of=int(os.environ.get("ROCM_VALIDATION_WHISPER_BEST_OF","5"))
model=whisper.load_model(model_name, device=device)
t0=time.time()
runs=0
text_len=0
while (time.time()-t0) < min_s:
    try:
        result=model.transcribe(fname, fp16=True, beam_size=beam_size, best_of=best_of, language="en", task="transcribe", condition_on_previous_text=False)
    except Exception:
        result=model.transcribe(fname, fp16=False, beam_size=beam_size, best_of=best_of, language="en", task="transcribe", condition_on_previous_text=False)
    runs += 1
    text_len=max(text_len, len(result.get("text","") or ""))
dt=time.time()-t0
torch.cuda.synchronize()
print("GPU_OK")
print("device", device)
print("model", model_name)
print("beam_size", beam_size)
print("best_of", best_of)
print("runs", runs)
print("seconds", dt)
print("text_len", text_len)
"""

    def run_one(sampler):
        t0 = time.monotonic()
        r = run_cmd(ctx.repo_root, env, [sys.executable, "-c", script], t, log)
        wall_s = time.monotonic() - t0
        return r, wall_s, sampler

    r, wall_s, sampler = with_power_sampler(cfg, build_dir=build_dir, fn=run_one)
    out = (r.out + "\n" + r.err).strip()

    if r.rc != 0:
        if "IMPORT_ERROR" in out:
            return StepResult(build_dir, "Whisper (python) smoke", "SKIP", fmt_duration(r.dur_ms), "missing torch/whisper in venv")
        if "GPU_NOT_AVAILABLE" in out:
            return StepResult(build_dir, "Whisper (python) smoke", "FAIL", fmt_duration(r.dur_ms), "torch.cuda.is_available=false (GPU required)")
        if "GPU_NOT_ROCM" in out:
            return StepResult(build_dir, "Whisper (python) smoke", "FAIL", fmt_duration(r.dur_ms), "torch.version.hip missing (ROCm torch required)")
        if "AUDIO_MISSING" in out:
            # Keep behavior deterministic: require the bundled sample.
            return StepResult(build_dir, "Whisper (python) smoke", "FAIL", fmt_duration(r.dur_ms), f"missing audio sample: {Path(audio_cfg).name}")
        return StepResult(build_dir, "Whisper (python) smoke", "FAIL", fmt_duration(r.dur_ms), f"rc={r.rc}")

    metric = f"{model_name} transcribe (audio={audio_path.name}) rocm_env={'in-tree' if use_in_tree else 'system'} wall={wall_s:.2f}s"
    if repeats > 1 and audio_target_s and audio_target_s > 0:
        metric += f" audio_target_s={int(audio_target_s)} repeats={repeats}"
    for key in ("model", "beam_size", "best_of", "runs", "seconds", "text_len"):
        m = re.search(rf"^{key}\s+(\S+)$", out, re.MULTILINE)
        if m:
            metric += f" {key}={m.group(1)}"

    metric = append_power(metric, sampler, baseline_w=baseline_avg_w(cfg, build_dir))

    if "GPU_OK" not in out:
        return StepResult(build_dir, "Whisper (python) smoke", "FAIL", fmt_duration(r.dur_ms), f"GPU validation missing | {metric}")

    if sampler is not None:
        gpu = sampler.avg_gpu_busy()
        base_w = baseline_avg_w(cfg, build_dir) or 0.0
        avgw = sampler.avg_power_w() or 0.0
        if (gpu is not None and gpu < 5) and (avgw - base_w) < 5:
            return StepResult(build_dir, "Whisper (python) smoke", "FAIL", fmt_duration(r.dur_ms), f"no GPU activity detected | {metric}")

    return StepResult(build_dir, "Whisper (python) smoke", "OK", fmt_duration(r.dur_ms), metric)
