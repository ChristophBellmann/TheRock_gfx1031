from __future__ import annotations

from __future__ import annotations

from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.runner import fmt_duration, run_cmd
from steps.shared import downloads_enabled


def ensure_mfem_source(ctx: Context, cfg: dict[str, Any], env: dict[str, str], log: Path | None) -> tuple[Path | None, StepResult | None]:
    if not downloads_enabled(cfg):
        return None, StepResult("<meta>", "MFEM fetch", "SKIP", "0ms", "downloads disabled")

    src = ctx.git_cache_dir() / "mfem"
    if src.exists():
        return src, None

    repo = str(cfg.get("workloads", {}).get("mfem", {}).get("git", "https://github.com/mfem/mfem.git"))
    ref = str(cfg.get("workloads", {}).get("mfem", {}).get("ref", "master"))

    r0 = run_cmd(ctx.repo_root, env, ["git", "clone", "--depth", "1", "--branch", ref, repo, str(src)], 900, log)
    if r0.rc != 0:
        return None, StepResult("<meta>", "MFEM fetch", "FAIL", fmt_duration(r0.dur_ms), f"git clone rc={r0.rc}")
    return src, None
