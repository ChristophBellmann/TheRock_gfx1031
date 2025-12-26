from __future__ import annotations

from __future__ import annotations

from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from steps.shared import downloads_enabled, pip_install


def ensure_open_interpreter(ctx: Context, cfg: dict[str, Any], env: dict[str, str], log: Path | None) -> StepResult | None:
    if not downloads_enabled(cfg):
        return StepResult("<meta>", "open-interpreter setup", "SKIP", "0ms", "downloads disabled")
    t = int(cfg.get("timeouts_s", {}).get("open_interpreter", 900))
    rpi = pip_install(ctx, env, ["open-interpreter"], log, t)
    if rpi is not None:
        return rpi
    return None
