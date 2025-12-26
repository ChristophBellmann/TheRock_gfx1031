from __future__ import annotations

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.runner import run_cmd, fmt_duration


def step_whisper(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    """
    Whisper smoke test.

    Notes:
    - We *do not* auto-install PyTorch/Whisper here (wheels can be huge and platform-specific).
    - If torch/whisper are available in the validation venv, we run a tiny transcription on a
      bundled sample audio clip when present.
    """
    t = int(cfg.get("timeouts_s", {}).get("whisper", 1800))
    audio_cfg = str(cfg.get("workloads", {}).get("whisper", {}).get("audio_file", "")).strip()
    audio_cfg = audio_cfg or "validation/src/assets/samples/audio/Take2_Audio1-1.wav"
    env = dict(env)
    env["ROCM_VALIDATION_WHISPER_AUDIO"] = str(ctx.repo_root / audio_cfg) if not Path(audio_cfg).is_absolute() else audio_cfg
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

model=whisper.load_model("tiny.en")
t0=time.time()
result=model.transcribe(fname, fp16=False)
dt=time.time()-t0
print("seconds", dt)
print("text_len", len(result.get("text","")))
"""
    r = run_cmd(ctx.repo_root, env, [sys.executable, "-c", script], t, log)
    if r.rc != 0:
        out = (r.out + "\n" + r.err).strip()
        if "IMPORT_ERROR" in out:
            return StepResult(build_dir, "Whisper (python) smoke", "SKIP", fmt_duration(r.dur_ms), "missing torch/whisper in venv (install separately)")
        return StepResult(build_dir, "Whisper (python) smoke", "FAIL", fmt_duration(r.dur_ms), f"rc={r.rc}")

    out = r.out + "\n" + r.err
    metric = f"ran tiny.en transcribe (audio={Path(audio_cfg).name})"
    if "torch.version.hip None" in out and "torch.cuda.is_available False" in out:
        metric += " (CPU torch; ROCm not detected)"
    return StepResult(build_dir, "Whisper (python) smoke", "OK", fmt_duration(r.dur_ms), metric)
