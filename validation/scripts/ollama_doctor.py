#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from _bootstrap import reexec_in_venv, repo_root, validation_root


def _last_run_dir() -> Path | None:
    runs = validation_root() / "workspace" / "runs"
    if not runs.is_dir():
        return None
    dirs = sorted((p for p in runs.iterdir() if p.is_dir()), reverse=True)
    return dirs[0] if dirs else None


def _read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _extract_ollama_result(report: dict) -> dict | None:
    # Try to find the docker bench first, then any Ollama step.
    results = report.get("results") or []
    for r in results:
        if isinstance(r, dict) and "Ollama (docker ROCm) bench" in str(r.get("name", "")):
            return r
    for r in results:
        if isinstance(r, dict) and "Ollama" in str(r.get("name", "")):
            return r
    return None


def _extract_hints_from_log(log_path: Path) -> list[str]:
    if not log_path.is_file():
        return []
    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    needles = (
        "failure during GPU discovery",
        "runner crashed",
        "filtering device",
        "entering low vram mode",
        "total vram",
        "inference compute",
        "runner.vram",
        "llama_kv_cache: layer   0: dev =",
    )
    hits: list[str] = []
    for ln in lines:
        if any(n in ln for n in needles):
            hits.append(ln.strip())
    # Keep the last few most relevant lines.
    return hits[-20:]


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    rc = reexec_in_venv(Path(__file__).resolve(), argv)
    if rc is not None:
        return rc

    ap = argparse.ArgumentParser(
        prog="ollama_doctor.py",
        description="Runs a self-contained Ollama ROCm validation and prints a diagnosis if GPU acceleration is not active.",
    )
    ap.add_argument("--build-dirs", default=None, help="Comma-separated build dirs to validate (default: auto).")
    ap.add_argument("--power", action="store_true", help="Enable GPU power/utilization sampling (default: on).")
    ap.add_argument("--no-power", action="store_true", help="Disable GPU power/utilization sampling.")
    ap.add_argument("--no-log", action="store_true", help="Do not write logs under validation/workspace/runs/ (not recommended).")
    ap.add_argument("--yes", action="store_true", help="Assume 'yes' to prompts (non-interactive).")
    args = ap.parse_args(argv)

    validate_args: list[str] = ["--profile", "ollama"]
    if args.build_dirs:
        validate_args += ["--build-dirs", args.build_dirs]
    if not args.no_power:
        validate_args += ["--power"]
    if not args.no_log:
        validate_args += ["--log"]
    if args.yes or os.environ.get("CI", "") == "1":
        validate_args += ["--yes"]

    src = validation_root() / "src"
    if str(src) not in sys.path:
        sys.path.insert(0, str(src))
    os.chdir(repo_root())
    from cli.main import main as cli_main  # noqa: E402

    rc = cli_main(["validate"] + validate_args)

    last = _last_run_dir()
    if last is None:
        return rc
    report_path = last / "report.json"
    if not report_path.is_file():
        return rc

    report = _read_json(report_path)
    res = _extract_ollama_result(report)
    if res is None:
        return rc

    status = str(res.get("status", ""))
    metric = str(res.get("metric", "")).strip()
    build_dir = str(res.get("build_dir", ""))

    print("")
    print("==== ollama doctor ====")
    print(f"run_dir : {last}")
    print(f"build   : {build_dir}")
    print(f"status  : {status}")
    if metric:
        print(f"metric  : {metric}")

    log_path = last / "logs" / f"{build_dir}.ollama.log"
    hints = _extract_hints_from_log(log_path)
    if hints:
        print("")
        print("diagnosis hints (from logs):")
        for ln in hints:
            print(f"- {ln}")

    if status != "OK":
        print("")
        print("next steps:")
        print(f"- Re-run with full logs: `python3 validation/scripts/ollama_doctor.py --yes`")
        print("- Check base ROCm health: `python3 validation/scripts/doctor.py`")
        print("- Check GPU load works at all: `python3 validation/scripts/validate.py --profile quick --power` (hipcc/rocBLAS/MIOpen should raise avgW/gpu%)")
        print("- If docker stays CPU: look for `failure during GPU discovery` / `total vram=0 B` in the ollama log above and consider host ROCm/driver alignment.")

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
