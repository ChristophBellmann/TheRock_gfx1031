#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from _bootstrap import reexec_in_venv, repo_root, validation_root
from _doctor_utils import find_result, last_run_dir, read_report_json


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    rc = reexec_in_venv(Path(__file__).resolve(), argv)
    if rc is not None:
        return rc

    ap = argparse.ArgumentParser(
        prog="ollama_validate.py",
        description="Runs Ollama validation and prints a compact summary (default: strict GPU inference via docker ROCm bench when needed).",
    )
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument(
        "--smoke",
        action="store_true",
        help="Smoke-only: setup + `ollama --version` (no model pull / no inference).",
    )
    ap.add_argument("--build-dirs", default=None, help="Comma-separated build dirs to validate (default: auto).")
    ap.add_argument("--power", action="store_true", help="Enable GPU power/utilization sampling (default: on).")
    ap.add_argument("--no-power", action="store_true", help="Disable GPU power/utilization sampling.")
    ap.add_argument("--downloads", action="store_true", help="Allow downloads (default: on).")
    ap.add_argument("--no-downloads", action="store_true", help="Disable downloads (ollama download/model pull may SKIP).")
    ap.add_argument("--log", action="store_true", help="Write logs under validation/workspace/runs/ (default: off).")
    args = ap.parse_args(argv)

    profile = "ollama_smoke" if args.smoke else "ollama"
    validate_args: list[str] = ["--profile", profile]
    if args.build_dirs:
        validate_args += ["--build-dirs", args.build_dirs]
    if args.no_downloads and not args.downloads:
        validate_args += ["--no-downloads"]
    if args.no_power:
        validate_args += ["--no-power"]
    else:
        validate_args += ["--power"]
    if args.log:
        validate_args += ["--log"]
    validate_args += ["--yes"]  # always non-interactive by default

    src = validation_root() / "src"
    if str(src) not in sys.path:
        sys.path.insert(0, str(src))
    os.chdir(repo_root())
    from cli.main import main as cli_main  # noqa: E402

    rc = cli_main(["validate"] + validate_args)

    run_dir = last_run_dir()
    if run_dir is None:
        return rc
    report = read_report_json(run_dir)
    if report is None:
        return rc

    res = find_result(report, name_contains="Ollama")
    if res is None:
        return rc

    status = str(res.get("status", ""))
    metric = str(res.get("metric", "")).strip()
    build_dir = str(res.get("build_dir", ""))

    print("")
    print("==== ollama validation ====")
    print(f"run_dir : {run_dir}")
    print(f"build   : {build_dir}")
    print(f"profile : {profile}")
    print(f"status  : {status}")
    if metric:
        print(f"metric  : {metric}")

    if status != "OK":
        print("")
        print("next steps:")
        print("- Re-run with logs: `python3 validation/scripts/ollama_validate.py --log`")
        print("- Or run doctor (includes extra hints): `python3 validation/scripts/ollama_doctor.py --yes`")
        print("- Check base ROCm health: `python3 validation/scripts/doctor.py`")

    return rc


if __name__ == "__main__":
    raise SystemExit(main())

