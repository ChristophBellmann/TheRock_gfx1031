from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

from rocm_validation.core.context import Context


def write_report_json(ctx: Context, data: dict) -> Path:
    p = ctx.run_root / "report.json"
    p.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
    return p


def cache_gc(ctx: Context, *, delete_downloads: bool) -> None:
    runs = ctx.workspace_root / "runs"
    if runs.is_dir():
        shutil.rmtree(runs)
        runs.mkdir(parents=True, exist_ok=True)
    if delete_downloads:
        cache = ctx.workspace_root / "cache"
        if cache.is_dir():
            shutil.rmtree(cache)


def _last_run_dir(ctx: Context) -> Path | None:
    runs = ctx.workspace_root / "runs"
    if not runs.is_dir():
        return None
    dirs = sorted((p for p in runs.iterdir() if p.is_dir()), reverse=True)
    return dirs[0] if dirs else None


def open_last_report(ctx: Context, *, open_browser: bool) -> int:
    last = _last_run_dir(ctx)
    if last is None:
        print("No runs found under validation/workspace/runs")
        return 2
    report = last / "report.json"
    print(str(report))
    if open_browser:
        html = last / "report.html"
        if html.exists():
            try:
                subprocess.check_call(["xdg-open", str(html)])
            except Exception:
                return 1
        else:
            print("No report.html present for last run")
            return 2
    return 0

