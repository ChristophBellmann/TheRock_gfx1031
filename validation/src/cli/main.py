from __future__ import annotations

import argparse
import os
import sys

from cli.prompts import confirm
from core.config import load_config
from core.context import Context
from core.reporting.summary import print_summary
from steps.plan import build_plan, run_plan


def _cmd_validate(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="validate", description="Repo-local ROCm validation suite.")
    ap.add_argument("--profile", default=None, help="Config profile (full/quick/airgapped). Default: full.")
    ap.add_argument("--build-dirs", default=None, help="Comma-separated build dirs to validate (default: auto).")
    ap.add_argument("--all-build-dirs", action="store_true", help="Validate all detected build dirs (default: only the preferred one).")
    ap.add_argument("--no-downloads", action="store_true", help="Disable network downloads (third-party steps will SKIP).")
    ap.add_argument("--yes", action="store_true", help="Assume 'yes' for prompts (non-interactive).")
    ap.add_argument("--power", action="store_true", help="Sample GPU power/utilization via sysfs during sustained-load tests.")
    ap.add_argument(
        "--summary-multiline",
        action="store_true",
        help="Print metrics under each step (more verbose, easier to read). Default: one line per test.",
    )
    ap.add_argument("--log", action="store_true", help="Write logs to validation/workspace/runs/<id>/logs/ (default: off).")
    args = ap.parse_args(argv)

    cfg = load_config(profile=args.profile)
    if args.build_dirs:
        cfg["run"]["build_dirs"] = [x.strip() for x in args.build_dirs.split(",") if x.strip()]
    if args.all_build_dirs:
        cfg["run"]["all_build_dirs"] = True
    if args.no_downloads or os.environ.get("ROCM_VALIDATION_NO_DOWNLOADS", "") == "1":
        cfg["run"]["downloads_enabled"] = False
        cfg["run"]["ask_before_downloads"] = False
    if args.power or os.environ.get("ROCM_VALIDATION_POWER", "") == "1":
        cfg["run"]["power_monitor"] = True
    if args.summary_multiline:
        cfg["run"]["summary_multiline"] = True

    ctx = Context.from_repo(cfg=cfg, enable_logs=bool(args.log))
    plan = build_plan(cfg)

    downloads_enabled = bool(cfg["run"].get("downloads_enabled", True))
    if downloads_enabled and bool(cfg["run"].get("ask_before_downloads", True)) and not args.yes:
        ok = confirm(
            "Proceed with full validation? This may download/build third-party components (potentially multiple GB).",
            default_yes=True,
        )
        if not ok:
            cfg["run"]["downloads_enabled"] = False

    results = run_plan(ctx, cfg, plan)
    print_summary(ctx, results)
    return 0 if all(r.status != "FAIL" for r in results) else 1


def _cmd_doctor(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="doctor", description="System and in-tree ROCm sanity checks.")
    ap.add_argument(
        "--summary-multiline",
        action="store_true",
        help="Print metrics under each step (more verbose, easier to read). Default: one line per test.",
    )
    ap.add_argument("--log", action="store_true", help="Write logs under validation/workspace (default: off).")
    args = ap.parse_args(argv)
    cfg = load_config(profile="quick")
    if args.summary_multiline:
        cfg["run"]["summary_multiline"] = True
    ctx = Context.from_repo(cfg=cfg, enable_logs=bool(args.log))
    plan = build_plan(cfg, doctor_only=True)
    results = run_plan(ctx, cfg, plan)
    print_summary(ctx, results)
    return 0 if all(r.status != "FAIL" for r in results) else 1


def _cmd_cache_gc(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="cache-gc", description="Remove validation workspace caches.")
    ap.add_argument("--all", action="store_true", help="Also delete downloaded artifacts (not just temp runs).")
    args = ap.parse_args(argv)
    from core.artifacts import cache_gc  # lazy

    ctx = Context.from_repo(cfg=load_config(profile="quick"), enable_logs=False)
    cache_gc(ctx, delete_downloads=bool(args.all))
    return 0


def _cmd_report(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="report", description="Print last validation report location.")
    ap.add_argument("--open", action="store_true", help="Attempt to open the HTML report in a browser.")
    args = ap.parse_args(argv)
    from core.artifacts import open_last_report  # lazy

    ctx = Context.from_repo(cfg=load_config(profile="quick"), enable_logs=False)
    return open_last_report(ctx, open_browser=bool(args.open))


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        argv = ["validate"]
    cmd, *rest = argv
    if cmd == "validate":
        return _cmd_validate(rest)
    if cmd == "doctor":
        return _cmd_doctor(rest)
    if cmd in {"cache-gc", "cache_gc"}:
        return _cmd_cache_gc(rest)
    if cmd in {"report", "report-open"}:
        return _cmd_report(rest)
    print(f"Unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
