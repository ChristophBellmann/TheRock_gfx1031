from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from core.context import Context
from core.download import DownloadPolicy
from core.reporting.models import StepResult
from core.runner import fmt_duration, run_cmd


def read_small_text(path: Path, *, max_bytes: int = 64 * 1024) -> str:
    data = path.read_bytes()
    if len(data) > max_bytes:
        raise RuntimeError(f"file too large: {path} ({len(data)} bytes > {max_bytes})")
    try:
        return data.decode("utf-8", errors="replace")
    except Exception:
        return data.decode(errors="replace")


def downloads_enabled(cfg: dict[str, Any]) -> bool:
    run_cfg = cfg.get("run", {})
    return bool(run_cfg.get("downloads_enabled", True))


def dl_policy(cfg: dict[str, Any]) -> DownloadPolicy:
    run_cfg = cfg.get("run", {})
    max_total_gb = float(run_cfg.get("max_download_gb", 8))
    max_single_gb = float(run_cfg.get("max_single_download_gb", 4))
    return DownloadPolicy(
        max_total_bytes=int(max_total_gb * 1024 * 1024 * 1024),
        max_single_bytes=int(max_single_gb * 1024 * 1024 * 1024),
    )


def pip_install(ctx: Context, env: dict[str, str], pkgs: list[str], log: Path | None, timeout_s: int) -> StepResult | None:
    cmd = [sys.executable, "-m", "pip", "install"] + pkgs
    r = run_cmd(ctx.repo_root, env, cmd, timeout_s, log)
    if r.rc != 0:
        return StepResult("<meta>", "pip install", "FAIL", fmt_duration(r.dur_ms), f"rc={r.rc}")
    return None
