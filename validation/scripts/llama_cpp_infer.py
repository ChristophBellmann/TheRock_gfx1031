#!/usr/bin/env python3
from __future__ import annotations

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

    # Non-interactive, GPU-required inference: fails if no model is configured.
    validate_args = ["--profile", "llama_cpp_infer", "--yes", "--power", "--log"]

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
    print("==== llama.cpp inference ====")
    print(f"run_dir : {run_dir}")
    print(f"build   : {build_dir}")
    print(f"status  : {status}")
    if metric:
        print(f"metric  : {metric}")

    if status != "OK":
        print("")
        print("notes:")
        print("- This mode requires `workloads.llama_cpp.model_url` (GGUF) in `validation/config/defaults.yaml` (or profile overlay).")
        print("- GPU is mandatory: CPU fallback is treated as FAIL (see the per-step log for details).")
        print("")
        print("logs:")
        print(f"- {run_dir / 'logs' / f'{build_dir}.llama_cpp_docker.log'}")

    return rc


if __name__ == "__main__":
    raise SystemExit(main())

