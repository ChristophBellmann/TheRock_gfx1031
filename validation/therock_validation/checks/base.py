from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class CheckResult:
    name: str
    status: str  # OK/FAIL/SKIP
    duration: str
    metric: str = ""


class Check(Protocol):
    idx: int
    name: str
    purpose: str
    expected: str
    timeout_s: int

    def run(self, ctx) -> CheckResult: ...

