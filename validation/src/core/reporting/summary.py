from __future__ import annotations

import sys

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


def print_summary(ctx: Context, results: list[StepResult]) -> None:
    ansi = Ansi(enabled=bool(getattr(sys.stdout, "isatty", lambda: False)()))
    print("")
    print(f"{ansi.bold}==== validation summary ===={ansi.reset}")
    cur = None
    for r in results:
        if r.build_dir != cur:
            cur = r.build_dir
            print(f"{ansi.dim}-- build dir:{ansi.reset} {cur}")
        line = f"- {ansi.label(r.name):<32} {ansi.status(r.status)} {ansi.dim}({r.duration}){ansi.reset}"
        if r.metric:
            line += f" {r.metric}"
        print(line)
    if ctx.logs_dir is not None:
        print(f"{ansi.dim}Logs:{ansi.reset} {ctx.logs_dir}")
    else:
        print(f"{ansi.dim}Logs:{ansi.reset} disabled (use --log)")
