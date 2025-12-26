from __future__ import annotations

import sys
import re
import shutil

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


def _ellipsize(s: str, max_len: int) -> str:
    if max_len <= 0:
        return ""
    if len(s) <= max_len:
        return s
    if max_len == 1:
        return "…"
    return s[: max_len - 1] + "…"


def print_summary(ctx: Context, results: list[StepResult]) -> None:
    ansi = Ansi(enabled=bool(getattr(sys.stdout, "isatty", lambda: False)()))
    multiline = bool(ctx.cfg.get("run", {}).get("summary_multiline", False))
    print("")
    print(f"{ansi.bold}==== validation summary ===={ansi.reset}")
    cur = None

    term_cols = int(shutil.get_terminal_size(fallback=(160, 20)).columns)
    # Use the max power-blob length to keep a stable column where power starts.
    max_power_len = 0
    for r in results:
        _, power = _split_metric(r.metric)
        if power:
            max_power_len = max(max_power_len, len(power))

    # Visible prefix length (excluding ANSI sequences).
    prefix_plain = f"- {'':<32} {'':<4} ({'':>7}) "
    prefix_len = len(prefix_plain)
    # Params field: align to the longest params observed (for power-bearing tests),
    # but clamp to terminal width so we don't explode horizontal scrolling.
    max_params_len = 0
    for r in results:
        params, power = _split_metric(r.metric)
        if power and params:
            max_params_len = max(max_params_len, len(params))

    # "  |  " separator makes the table easier to read.
    power_sep = "  |  " if max_power_len > 0 else ""
    power_sep_len = len(power_sep)
    params_width_cap = max(0, term_cols - prefix_len - power_sep_len - max_power_len)
    params_width = min(max_params_len, params_width_cap) if max_params_len > 0 else params_width_cap
    for r in results:
        if r.build_dir != cur:
            cur = r.build_dir
            print(f"{ansi.dim}-- build dir:{ansi.reset} {cur}")

        params, power = _split_metric(r.metric)

        if multiline:
            line = f"- {ansi.label(r.name):<32} {ansi.status(r.status):<4} {ansi.dim}({r.duration:>7}){ansi.reset}"
            print(line)
            if params:
                print(f"  {ansi.dim}params:{ansi.reset} {params}")
            if power:
                _print_power_block(ansi, power)
            continue

        # One-line-per-test "table": pad/ellipsize params so power columns align.
        line = f"- {ansi.label(r.name):<32} {ansi.status(r.status):<4} {ansi.dim}({r.duration:>7}){ansi.reset}"
        if power and max_power_len > 0:
            p = _ellipsize(params or "", params_width).ljust(params_width)
            print(f"{line}  {p}{power_sep}{power}")
        elif params:
            # No power: keep line within terminal width (best-effort).
            avail = max(0, term_cols - prefix_len)
            p = _ellipsize(params, avail)
            print(f"{line}  {p}")
        else:
            print(line)
    if ctx.logs_dir is not None:
        print(f"{ansi.dim}Logs:{ansi.reset} {ctx.logs_dir}")
    else:
        print(f"{ansi.dim}Logs:{ansi.reset} disabled (use --log)")
