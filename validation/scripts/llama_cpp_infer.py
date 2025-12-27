#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from pathlib import Path

from _bootstrap import reexec_in_venv, repo_root, validation_root


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    rc = reexec_in_venv(Path(__file__).resolve(), argv)
    if rc is not None:
        return rc

    # Back-compat wrapper. Prefer `llama_cpp_validate.py` (default strict inference).
    src = validation_root() / "src"
    if str(src) not in sys.path:
        sys.path.insert(0, str(src))
    os.chdir(repo_root())
    print("NOTE: `llama_cpp_infer.py` is deprecated; use `python3 validation/scripts/llama_cpp_validate.py` (default: strict inference).")
    from llama_cpp_validate import main as validate_main  # noqa: E402

    # Preserve previous behavior: always power + logs.
    argv2 = ["--log", "--power"] + list(argv)
    return int(validate_main(argv2))


if __name__ == "__main__":
    raise SystemExit(main())
