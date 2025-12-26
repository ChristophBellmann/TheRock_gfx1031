#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def _repo_root() -> Path:
    # .../validation/scripts/validate.py -> repo root is 2 parents up from `validation/`
    return Path(__file__).resolve().parents[2]


def _validation_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _in_venv() -> bool:
    return getattr(sys, "base_prefix", sys.prefix) != sys.prefix


def _ensure_venv() -> Path:
    venv_dir = _validation_root() / "workspace" / "envs" / "py"
    py = venv_dir / "bin" / "python"
    if py.exists():
        return py

    venv_dir.parent.mkdir(parents=True, exist_ok=True)
    subprocess.check_call([sys.executable, "-m", "venv", str(venv_dir)])
    subprocess.check_call([str(py), "-m", "pip", "install", "--upgrade", "pip"])
    lock = _validation_root() / "requirements-lock.txt"
    subprocess.check_call([str(py), "-m", "pip", "install", "-r", str(lock)])
    return py


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)

    # Bootstrap into repo-local venv (keeps validation reproducible after clone).
    if not _in_venv() and os.environ.get("ROCM_VALIDATION_NO_BOOTSTRAP", "") != "1":
        py = _ensure_venv()
        env = os.environ.copy()
        env["ROCM_VALIDATION_BOOTSTRAPPED"] = "1"
        return subprocess.call([str(py), str(Path(__file__).resolve())] + argv, env=env)

    repo_root = _repo_root()
    src = _validation_root() / "src"
    if str(src) not in sys.path:
        sys.path.insert(0, str(src))
    os.chdir(repo_root)

    from rocm_validation.cli.main import main as cli_main  # noqa: E402

    return cli_main(["validate"] + argv)


if __name__ == "__main__":
    raise SystemExit(main())

