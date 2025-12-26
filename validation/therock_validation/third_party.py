from __future__ import annotations

import os
import shutil
import subprocess
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from .utils import REPO_ROOT, ensure_dir, human_bytes, run_cmd


VALIDATION_DIR = REPO_ROOT / "validation"
CACHE_DIR = VALIDATION_DIR / "_cache"
BUILD_DIR = VALIDATION_DIR / "_build"
LOGS_DIR = VALIDATION_DIR / "_logs"


def download(url: str, dest: Path) -> int:
    ensure_dir(dest.parent)
    req = urllib.request.Request(url, headers={"User-Agent": "therock-validation"})
    with urllib.request.urlopen(req) as resp:
        total = int(resp.headers.get("Content-Length") or 0)
        with open(dest, "wb") as f:
            shutil.copyfileobj(resp, f)
    return total


def ensure_venv(python: str = "python3") -> Path:
    venv_dir = VALIDATION_DIR / ".venv"
    vpython = venv_dir / "bin" / "python"
    if vpython.exists():
        return vpython
    ensure_dir(venv_dir.parent)
    subprocess.check_call([python, "-m", "venv", str(venv_dir)], cwd=str(REPO_ROOT))
    subprocess.check_call([str(vpython), "-m", "pip", "install", "--upgrade", "pip"], cwd=str(REPO_ROOT))
    return vpython


def pip_install(vpython: Path, pkgs: list[str]) -> None:
    subprocess.check_call([str(vpython), "-m", "pip", "install", *pkgs], cwd=str(REPO_ROOT))


def venv_bin(vpython: Path, exe: str) -> Path:
    return vpython.parent / exe


@dataclass(frozen=True)
class DownloadItem:
    name: str
    note: str
    approx_bytes: int | None

    def approx_str(self) -> str:
        if self.approx_bytes is None:
            return "unknown"
        return human_bytes(self.approx_bytes)

