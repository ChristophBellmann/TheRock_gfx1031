from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.rocm_env import which
from core.runner import fmt_duration, run_cmd
from steps.workloads.open_interpreter.setup import ensure_open_interpreter


def step_open_interpreter(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    meta = ensure_open_interpreter(ctx, cfg, env, log)
    if meta is not None and meta.status != "OK":
        return StepResult(build_dir, "Open Interpreter (pip) smoke", meta.status, meta.duration, meta.metric)

    # Prefer PATH lookup, but fall back to the current venv bin dir.
    # Do NOT call `.resolve()` on sys.executable: in a venv it's commonly a symlink
    # to the system python, which would drop us out of the venv and break lookup.
    interp = which("interpreter", env) or str(Path(sys.executable).parent / "interpreter")
    r = run_cmd(ctx.repo_root, env, [interp, "--help"], 20, log)
    return StepResult(build_dir, "Open Interpreter (pip) smoke", "OK" if r.rc == 0 else "FAIL", fmt_duration(r.dur_ms), "interpreter --help" if r.rc == 0 else f"rc={r.rc}")
