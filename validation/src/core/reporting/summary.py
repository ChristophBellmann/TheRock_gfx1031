from __future__ import annotations

import sys
import re

from core.context import Context
from core.reporting.models import StepResult


class Ansi:
    def __init__(self, enabled: bool):
        self.enabled = enabled
        self.reset = "\033[0m" if enabled else ""
        self.bold = "\033[1m" if enabled else ""
        self.dim = "\033[2m" if enabled else ""
        self.red = "\033[31m" if enabled else ""
        self.green = "\033[32m" if enabled else ""
        self.yellow = "\033[33m" if enabled else ""

    def status(self, s: str) -> str:
        if not self.enabled:
            return s
        if s == "OK":
            return f"{self.green}{s}{self.reset}"
        if s == "FAIL":
            return f"{self.red}{s}{self.reset}"
        if s == "SKIP":
            return f"{self.yellow}{s}{self.reset}"
        return s

    def label(self, s: str) -> str:
        return f"{self.bold}{s}{self.reset}" if self.enabled else s


def _split_metric(metric: str) -> tuple[str | None, str | None]:
    """
    Convention used by steps:
    - metrics may contain "params | power" where power starts with "E=".
    - or just a single power blob starting with "E=".
    """
    m = (metric or "").strip()
    if not m:
        return None, None
    if " | " in m:
        left, right = m.split(" | ", 1)
        return (left.strip() or None), (right.strip() or None)
    if m.startswith("E="):
        return None, m
    return m, None


_KV_RE = re.compile(r"([A-Za-z0-9%]+)=\s*([^=]+?)(?=\s+[A-Za-z0-9%]+=|$)")


def _parse_kv_tokens(blob: str) -> list[tuple[str, str]]:
    """
    Parse a "k=v" blob into ordered pairs, allowing aligned values with spaces.

    Example:
      "E=  414Ws avgW= 112.4W dW= +95.4W maxW= 128.0W gpu%= 87 mem%= 38"
    """
    pairs: list[tuple[str, str]] = []
    b = (blob or "").strip()
    if not b:
        return pairs
    for m in _KV_RE.finditer(b):
        k = (m.group(1) or "").strip()
        v = (m.group(2) or "").strip()
        if k:
            pairs.append((k, v))
    return pairs


def _print_power_block(ansi: Ansi, power: str) -> None:
    pairs = _parse_kv_tokens(power)
    if not pairs:
        print(f"  {ansi.dim}power:{ansi.reset} {power}")
        return

    print(f"  {ansi.dim}power:{ansi.reset}")
    key_w = max((len(k) for k, _ in pairs), default=4)
    val_w = max((len(v) for _, v in pairs), default=0)
    key_w = max(key_w, 4)
    val_w = max(val_w, 6)
    for k, v in pairs:
        print(f"    {k:<{key_w}} {v:>{val_w}}")


def print_summary(ctx: Context, results: list[StepResult]) -> None:
    ansi = Ansi(enabled=bool(getattr(sys.stdout, "isatty", lambda: False)()))
    print("")
    print(f"{ansi.bold}==== validation summary ===={ansi.reset}")
    cur = None
    for r in results:
        if r.build_dir != cur:
            cur = r.build_dir
            print(f"{ansi.dim}-- build dir:{ansi.reset} {cur}")
        line = f"- {ansi.label(r.name):<32} {ansi.status(r.status):<4} {ansi.dim}({r.duration:>7}){ansi.reset}"
        print(line)

        params, power = _split_metric(r.metric)
        if params:
            print(f"  {ansi.dim}params:{ansi.reset} {params}")
        if power:
            _print_power_block(ansi, power)
    if ctx.logs_dir is not None:
        print(f"{ansi.dim}Logs:{ansi.reset} {ctx.logs_dir}")
    else:
        print(f"{ansi.dim}Logs:{ansi.reset} disabled (use --log)")
