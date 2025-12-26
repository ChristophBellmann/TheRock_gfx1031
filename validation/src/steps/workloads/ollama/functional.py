from __future__ import annotations

from pathlib import Path
import subprocess
import time
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.runner import fmt_duration, run_cmd
from steps.workloads.ollama.setup import ensure_ollama
from steps.shared import read_small_text


def step_ollama(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    exe, meta = ensure_ollama(ctx, cfg, env)
    if meta is not None:
        return StepResult(build_dir, "Ollama (local binary) smoke", meta.status, meta.duration, meta.metric)
    if exe is None:
        return StepResult(build_dir, "Ollama (local binary) smoke", "SKIP", "0ms", "ollama not available")

    # Always do a quick version check.
    r = run_cmd(ctx.repo_root, env, [exe, "--version"], int(cfg.get("timeouts_s", {}).get("ollama", 120)), log)
    if r.rc != 0:
        return StepResult(build_dir, "Ollama (local binary) smoke", "FAIL", fmt_duration(r.dur_ms), f"ollama --version rc={r.rc}")

    model = str(cfg.get("workloads", {}).get("ollama", {}).get("model", "")).strip()
    if not model:
        return StepResult(build_dir, "Ollama (local binary) smoke", "OK", fmt_duration(r.dur_ms), "ollama --version (set workloads.ollama.model to run a prompt)")

    prompt_file = str(cfg.get("workloads", {}).get("ollama", {}).get("prompt_file", "validation/src/assets/samples/prompts/tiny_prompt.txt"))
    prompt_path = (ctx.repo_root / prompt_file) if not Path(prompt_file).is_absolute() else Path(prompt_file)
    prompt = read_small_text(prompt_path).strip().splitlines()[0:1]
    prompt = prompt[0] if prompt else "Hello"

    # Run an ephemeral local server so we don't depend on a system service.
    ollama_env = dict(env)
    ollama_env.setdefault("OLLAMA_HOST", "127.0.0.1:11434")
    models_dir = ctx.cache_dir() / "ollama" / "models"
    models_dir.mkdir(parents=True, exist_ok=True)
    ollama_env.setdefault("OLLAMA_MODELS", str(models_dir))

    srv = subprocess.Popen(
        [exe, "serve"],
        cwd=str(ctx.repo_root),
        env=ollama_env,
        stdout=subprocess.DEVNULL if log is None else subprocess.PIPE,
        stderr=subprocess.DEVNULL if log is None else subprocess.PIPE,
        text=True,
    )
    try:
        # Give it a moment to bind.
        time.sleep(1.0)

        t = int(cfg.get("timeouts_s", {}).get("ollama", 120))
        tpull = int(cfg.get("timeouts_s", {}).get("ollama_pull", 1800))
        trun = int(cfg.get("timeouts_s", {}).get("ollama_run", 600))

        rp = run_cmd(ctx.repo_root, ollama_env, [exe, "pull", model], tpull, log)
        if rp.rc != 0:
            return StepResult(build_dir, "Ollama (local binary) smoke", "FAIL", fmt_duration(r.dur_ms + rp.dur_ms), f"ollama pull {model} rc={rp.rc}")

        rr = run_cmd(ctx.repo_root, ollama_env, [exe, "run", model, prompt], trun, log)
        status = "OK" if rr.rc == 0 else "FAIL"
        metric = f"model={model} prompt_file={prompt_path.name}"
        if rr.rc != 0:
            metric += f" rc={rr.rc}"
        return StepResult(build_dir, "Ollama (local binary) smoke", status, fmt_duration(r.dur_ms + rp.dur_ms + rr.dur_ms), metric)
    finally:
        try:
            srv.terminate()
        except Exception:
            pass
        try:
            srv.wait(timeout=3.0)
        except Exception:
            try:
                srv.kill()
            except Exception:
                pass
