from __future__ import annotations

import json
from pathlib import Path

from _bootstrap import validation_root


def last_run_dir() -> Path | None:
    runs = validation_root() / "workspace" / "runs"
    if not runs.is_dir():
        return None
    dirs = sorted((p for p in runs.iterdir() if p.is_dir()), reverse=True)
    return dirs[0] if dirs else None


def read_report_json(run_dir: Path) -> dict | None:
    p = run_dir / "report.json"
    if not p.is_file():
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def find_result(report: dict, *, name_contains: str) -> dict | None:
    results = report.get("results") or []
    for r in results:
        if isinstance(r, dict) and name_contains in str(r.get("name", "")):
            return r
    return None

