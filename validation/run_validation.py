#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

"""
Backward-compatible entrypoint.

Prefer running `validation/scripts/validate.py`, which bootstraps a repo-local venv
and uses the `validation/src/therock_validation` package.
"""

REPO_ROOT = Path(__file__).resolve().parents[1]
VALIDATION_ROOT = Path(__file__).resolve().parent
SCRIPTS = VALIDATION_ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from _bootstrap import run_cli  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(run_cli("validate", sys.argv[1:], Path(__file__).resolve()))
