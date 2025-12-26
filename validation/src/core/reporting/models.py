from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class StepResult:
    build_dir: str
    name: str
    status: str  # OK|FAIL|SKIP
    duration: str
    metric: str = ""

