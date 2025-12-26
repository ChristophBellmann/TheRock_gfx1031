#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

"""
Backward-compatible entrypoint.

Prefer running `validation/scripts/validate.py`, which bootstraps a repo-local venv
and uses the `validation/src/rocm_validation` package.
"""

REPO_ROOT = Path(__file__).resolve().parents[1]
VALIDATION_ROOT = Path(__file__).resolve().parent
SRC = VALIDATION_ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from rocm_validation.cli.main import main  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(main(["validate"] + sys.argv[1:]))
