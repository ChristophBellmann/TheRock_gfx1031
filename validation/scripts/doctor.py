#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

from _bootstrap import run_cli


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    return run_cli("doctor", argv, Path(__file__).resolve())


if __name__ == "__main__":
    raise SystemExit(main())

