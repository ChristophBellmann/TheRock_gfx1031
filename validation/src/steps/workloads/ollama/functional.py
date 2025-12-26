from __future__ import annotations

from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.runner import fmt_duration, run_cmd
from steps.workloads.ollama.setup import ensure_ollama


def step_ollama(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    exe, meta = ensure_ollama(ctx, cfg, env)
    if meta is not None:
        return StepResult(build_dir, "Ollama (local binary) smoke", meta.status, meta.duration, meta.metric)
    if exe is None:
        return StepResult(build_dir, "Ollama (local binary) smoke", "SKIP", "0ms", "ollama not available")
    r = run_cmd(ctx.repo_root, env, [exe, "--version"], int(cfg.get("timeouts_s", {}).get("ollama", 120)), log)
    return StepResult(build_dir, "Ollama (local binary) smoke", "OK" if r.rc == 0 else "FAIL", fmt_duration(r.dur_ms), "ollama --version" if r.rc == 0 else f"rc={r.rc}")
