from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]


def is_tty() -> bool:
    try:
        return sys.stdout.isatty()
    except Exception:
        return False


class Ansi:
    def __init__(self, enabled: bool):
        self.enabled = enabled
        self.reset = "\033[0m" if enabled else ""
        self.bold = "\033[1m" if enabled else ""
        self.dim = "\033[2m" if enabled else ""
        self.red = "\033[31m" if enabled else ""
        self.green = "\033[32m" if enabled else ""
        self.yellow = "\033[33m" if enabled else ""
        self.cyan = "\033[36m" if enabled else ""

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


def now_ms() -> int:
    return int(time.time() * 1000)


def fmt_duration(ms: int) -> str:
    if ms <= 0:
        return "0ms"
    if ms < 1000:
        return f"{ms}ms"
    s = ms / 1000.0
    if s < 60:
        return f"{s:.3f}s"
    m = int(s // 60)
    rs = s - m * 60
    return f"{m}m{rs:05.2f}s"


def which(exe: str, env: dict[str, str]) -> str | None:
    path = env.get("PATH", os.environ.get("PATH", ""))
    for p in path.split(":"):
        candidate = Path(p) / exe
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


@dataclass(frozen=True)
class CommandResult:
    rc: int
    out: str
    err: str
    dur_ms: int


def run_cmd(
    env: dict[str, str],
    cmd: list[str],
    timeout_s: int | None,
    logf,
) -> CommandResult:
    start = now_ms()
    proc = subprocess.Popen(
        cmd,
        cwd=str(REPO_ROOT),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        out, err = proc.communicate(timeout=timeout_s)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
        rc = 124
    dur_ms = now_ms() - start

    if logf is not None:
        logf.write(f"$ {shlex.join(cmd)}\n")
        if out:
            logf.write(out)
            if not out.endswith("\n"):
                logf.write("\n")
        if err:
            logf.write(err)
            if not err.endswith("\n"):
                logf.write("\n")
        logf.write("\n")
        logf.flush()

    return CommandResult(rc=rc, out=out, err=err, dur_ms=dur_ms)


def parse_select(s: str) -> list[int]:
    s = (s or "").strip()
    if not s:
        return []
    s = s.replace(",", " ")
    out = []
    for part in s.split():
        if part.isdigit():
            out.append(int(part))
    return out


def extract_gflops(text: str) -> float | None:
    m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*,\s*[0-9]+(?:\.[0-9]+)?\s*$", text.strip(), re.M)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def ensure_dir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)


def human_bytes(n: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    f = float(n)
    for u in units:
        if f < 1024.0 or u == units[-1]:
            if u == "B":
                return f"{int(f)}{u}"
            return f"{f:.2f}{u}"
        f /= 1024.0
    return f"{n}B"


def confirm(prompt: str, default_yes: bool = True) -> bool:
    if not is_tty():
        return default_yes
    yn = "Y/n" if default_yes else "y/N"
    while True:
        resp = input(f"{prompt} [{yn}] ").strip().lower()
        if not resp:
            return default_yes
        if resp in {"y", "yes"}:
            return True
        if resp in {"n", "no"}:
            return False


def any_missing(exes: Iterable[str], env: dict[str, str]) -> list[str]:
    missing = []
    for e in exes:
        if which(e, env) is None:
            missing.append(e)
    return missing

