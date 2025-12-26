#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

# Allow running this file directly: ensure repo root is on sys.path so the
# `validation.therock_validation` package can be imported.
REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from validation.therock_validation.cli import main  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(main())
