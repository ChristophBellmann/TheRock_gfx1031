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
        prog="tensorflow_validate.py",
        description="Build TensorFlow ROCm wheel (plus minimal ROCm sanity) and print a compact summary.",
    )
    ap.add_argument("--build-dirs", default=None, help="Comma-separated build dirs to validate (default: auto).")
    ap.add_argument("--no-downloads", action="store_true", help="Disable downloads (TensorFlow build step will SKIP).")
    ap.add_argument("--log", action="store_true", help="Write logs under validation/workspace/runs/ (default: off).")
    args = ap.parse_args(argv)

    validate_args: list[str] = ["--profile", "tensorflow", "--yes", "--no-power"]
    if args.build_dirs:
        validate_args += ["--build-dirs", args.build_dirs]
    if args.no_downloads:
        validate_args += ["--no-downloads"]
    if args.log:
        validate_args += ["--log"]

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

    res = find_result(report, name_contains="TensorFlow (ROCm)")
    if res is None:
        return rc

    status = str(res.get("status", ""))
    metric = str(res.get("metric", "")).strip()
    build_dir = str(res.get("build_dir", ""))

    print("")
    print("==== tensorflow validation ====")
    print(f"run_dir : {run_dir}")
    print(f"build   : {build_dir}")
    print("profile : tensorflow")
    print(f"status  : {status}")
    if metric:
        print(f"metric  : {metric}")

    if status != "OK":
        print("")
        print("next steps:")
        print("- Re-run with logs: `python3 validation/scripts/tensorflow_validate.py --log`")
        print("- Monitor systemd build: `validation/scripts/tensorflow_rocm/monitor_tensorflow_rocm_build.sh --once`")
        print("- Check TensorFlow live log: `tail -n 200 validation/workspace/builds/tensorflow_rocm/tf_build_live.log`")

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
