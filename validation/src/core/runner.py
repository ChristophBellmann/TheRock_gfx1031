from __future__ import annotations

import shlex
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CommandResult:
    rc: int
    out: str
    err: str
    dur_ms: int


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


def run_cmd(
    cwd: Path,
    env: dict[str, str],
    cmd: list[str],
    timeout_s: int | None,
    log_path: Path | None,
) -> CommandResult:
    start = now_ms()
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError as e:
        dur_ms = now_ms() - start
        err = f"{e}"
        if log_path is not None:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with log_path.open("a", encoding="utf-8") as f:
                f.write(f"$ {shlex.join(cmd)}\n{err}\n\n")
        return CommandResult(rc=127, out="", err=err, dur_ms=dur_ms)
    try:
        out, err = proc.communicate(timeout=timeout_s)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
        rc = 124
    dur_ms = now_ms() - start

    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8") as f:
            f.write(f"$ {shlex.join(cmd)}\n")
            if out:
                f.write(out)
                if not out.endswith("\n"):
                    f.write("\n")
            if err:
                f.write(err)
                if not err.endswith("\n"):
                    f.write("\n")
            f.write("\n")

    return CommandResult(rc=rc, out=out, err=err, dur_ms=dur_ms)
