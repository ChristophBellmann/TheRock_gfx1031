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
        prog="llama_cpp_validate.py",
        description="Runs llama.cpp docker validation and prints a compact summary (default: strict GPU inference).",
    )
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument(
        "--smoke",
        action="store_true",
        help="Smoke-only: pull image + run wrapper help (no model download / no inference).",
    )
    mode.add_argument(
        "--best-effort",
        action="store_true",
        help="Best-effort workload mode (uses profile llama_cpp). Inference runs only if a model URL is configured.",
    )
    # Default is strict inference (profile llama_cpp_infer).
    ap.add_argument("--build-dirs", default=None, help="Comma-separated build dirs to validate (default: auto).")
    ap.add_argument("--power", action="store_true", help="Enable GPU power/utilization sampling (default: on).")
    ap.add_argument("--no-power", action="store_true", help="Disable GPU power/utilization sampling.")
    ap.add_argument("--downloads", action="store_true", help="Allow downloads (default: on).")
    ap.add_argument("--no-downloads", action="store_true", help="Disable downloads (docker pull/model download may SKIP).")
    ap.add_argument("--log", action="store_true", help="Write logs under validation/workspace/runs/ (default: off).")
    args = ap.parse_args(argv)

    profile = "llama_cpp_infer"
    if args.smoke:
        profile = "llama_cpp_smoke"
    elif args.best_effort:
        profile = "llama_cpp"

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

    res = find_result(report, name_contains="llama.cpp (docker)")
    if res is None:
        return rc

    status = str(res.get("status", ""))
    metric = str(res.get("metric", "")).strip()
    build_dir = str(res.get("build_dir", ""))

    print("")
    print("==== llama.cpp validation ====")
    print(f"run_dir : {run_dir}")
    print(f"build   : {build_dir}")
    print(f"profile : {profile}")
    print(f"status  : {status}")
    if metric:
        print(f"metric  : {metric}")

    if status != "OK":
        print("")
        print("next steps:")
        print("- Re-run with logs: `python3 validation/scripts/llama_cpp_validate.py --log`")
        print("- Check base ROCm health: `python3 validation/scripts/doctor.py`")
        print("- If docker stays CPU: ensure /dev/kfd + /dev/dri are present and that your user can access them.")
        if profile == "llama_cpp_infer":
            print("- Model config is required for strict inference: `validation/config/defaults.yaml` -> `workloads.llama_cpp.model_url`.")

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
