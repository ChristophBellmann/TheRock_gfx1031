from __future__ import annotations

import sys
import time
import re
from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.runner import run_cmd, fmt_duration
from steps.shared import append_power, baseline_avg_w, with_power_sampler


def step_whisper(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    """
    Whisper smoke test.

    Notes:
    - We *do not* auto-install PyTorch/Whisper here (wheels can be huge and platform-specific).
    - If torch/whisper are available in the validation venv, we run a tiny transcription on a
      bundled sample audio clip when present.
    """
    t = int(cfg.get("timeouts_s", {}).get("whisper", 1800))
    min_bench_s = float(cfg.get("workloads", {}).get("whisper", {}).get("min_bench_s", 5.0) or 5.0)
    audio_cfg = str(cfg.get("workloads", {}).get("whisper", {}).get("audio_file", "")).strip()
    audio_cfg = audio_cfg or "validation/src/assets/samples/audio/Take2_Audio1-1.wav"
    env = dict(env)
    env["ROCM_VALIDATION_WHISPER_AUDIO"] = str(ctx.repo_root / audio_cfg) if not Path(audio_cfg).is_absolute() else audio_cfg
    env["ROCM_VALIDATION_WHISPER_MIN_S"] = str(min_bench_s)
    script = r"""
import os, wave, struct, math, time, sys
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

repo_sample=os.environ.get("ROCM_VALIDATION_WHISPER_AUDIO", "")
if repo_sample and os.path.isfile(repo_sample):
    fname=repo_sample
else:
    # Fallback: generate a tiny 1s tone if the repo sample is not present.
    sr=16000
    dur=1.0
    freq=440.0
    n=int(sr*dur)
    fname=os.path.join("validation","workspace","cache","downloads","whisper_test.wav")
    os.makedirs(os.path.dirname(fname), exist_ok=True)
    with wave.open(fname, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        for i in range(n):
            v=int(0.2*32767*math.sin(2*math.pi*freq*i/sr))
            w.writeframes(struct.pack("<h", v))

min_s=float(os.environ.get("ROCM_VALIDATION_WHISPER_MIN_S","5"))
device="cuda"
model=whisper.load_model("tiny.en", device=device)
# Keep a sustained run to validate GPU acceleration and power draw.
t0=time.time()
runs=0
text_len=0
while (time.time()-t0) < min_s:
    try:
        result=model.transcribe(fname, fp16=True)
    except Exception:
        # Some builds may not support fp16; fall back while still requiring GPU.
        result=model.transcribe(fname, fp16=False)
    runs += 1
    text_len=max(text_len, len(result.get("text","") or ""))
dt=time.time()-t0
torch.cuda.synchronize()
print("GPU_OK")
print("device", device)
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
            return StepResult(build_dir, "Whisper (python) smoke", "SKIP", fmt_duration(r.dur_ms), "missing torch/whisper in venv (install separately)")
        if "GPU_NOT_AVAILABLE" in out:
            return StepResult(build_dir, "Whisper (python) smoke", "FAIL", fmt_duration(r.dur_ms), "torch.cuda.is_available=false (no GPU; ROCm torch required)")
        if "GPU_NOT_ROCM" in out:
            return StepResult(build_dir, "Whisper (python) smoke", "FAIL", fmt_duration(r.dur_ms), "torch.version.hip missing (CPU/CUDA torch; ROCm torch required)")
        return StepResult(build_dir, "Whisper (python) smoke", "FAIL", fmt_duration(r.dur_ms), f"rc={r.rc}")

    metric = f"tiny.en transcribe (audio={Path(audio_cfg).name}) wall={wall_s:.2f}s"
    # Include a tiny signal from script stdout.
    for key in ("runs", "seconds", "text_len"):
        m = re.search(rf"^{key}\\s+(\\S+)$", out, re.MULTILINE)
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
