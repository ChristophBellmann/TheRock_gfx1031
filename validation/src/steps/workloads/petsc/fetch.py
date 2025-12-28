from __future__ import annotations

from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.runner import fmt_duration, run_cmd
from steps.shared import downloads_enabled


def ensure_petsc_source(ctx: Context, cfg: dict[str, Any], env: dict[str, str], log: Path | None) -> tuple[Path | None, StepResult | None]:
    if not downloads_enabled(cfg):
        return None, StepResult("<meta>", "PETSc fetch", "SKIP", "0ms", "downloads disabled")

    src = ctx.git_cache_dir() / "petsc"
    if src.exists():
        return src, None

    repo = str(cfg.get("workloads", {}).get("petsc", {}).get("git", "https://gitlab.com/petsc/petsc.git"))
    ref = str(cfg.get("workloads", {}).get("petsc", {}).get("ref", "release"))

    r0 = run_cmd(ctx.repo_root, env, ["git", "clone", "--depth", "1", "--branch", ref, repo, str(src)], 1800, log)
    if r0.rc != 0:
        return None, StepResult("<meta>", "PETSc fetch", "FAIL", fmt_duration(r0.dur_ms), f"git clone rc={r0.rc}")
    return src, None

