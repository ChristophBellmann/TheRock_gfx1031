from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from cli.prompts import confirm
from core.config import load_config
from core.context import Context
from core.reporting.summary import print_summary
from core.tree import detect_build_dirs, detect_default_build_dir
from steps.plan import build_plan, run_plan


def _print_download_plan(cfg: dict) -> None:
    prof = str(cfg.get("run", {}).get("profile") or "full")
    repo_root = Path(__file__).resolve().parents[3]
    build_dirs = cfg.get("run", {}).get("build_dirs") or []
    if not build_dirs:
        if bool(cfg.get("run", {}).get("all_build_dirs", False)):
            build_dirs = detect_build_dirs(repo_root)
        else:
            build_dirs = [detect_default_build_dir(repo_root)]

    steps_cfg = cfg.get("steps", {}) or {}
    wl = cfg.get("workloads", {}) or {}

    lines: list[str] = []
    lines.append(f"Validation profile: {prof}")
    lines.append(f"Build dirs: {', '.join(build_dirs)}")
    lines.append("")
    lines.append("May download/build (if enabled):")

    def on(k: str) -> bool:
        return bool(steps_cfg.get(k, True))

    if on("llama_cpp_docker"):
        url = str((wl.get("llama_cpp", {}) or {}).get("model_url", "") or "").strip()
        lines.append(f"- llama.cpp (docker image) + GGUF model: {url or '(model_url not set)'}")
    if on("ollama"):
        model = str((wl.get("ollama", {}) or {}).get("model", "") or "").strip()
        lines.append(f"- Ollama (download or docker) + model: {model or '(model not set)'}")
    if on("open_interpreter"):
        lines.append("- Open Interpreter (pip install)")
    if on("whisper"):
        model = str((wl.get("whisper", {}) or {}).get("model", "") or "").strip()
        tgt = (wl.get("whisper", {}) or {}).get("audio_target_s", 0)
        lines.append(f"- Whisper (pip install) + model: {model or '(default)'} (audio_target_s={tgt})")
    if on("mfem_hip"):
        ref = str((wl.get("mfem", {}) or {}).get("ref", "") or "").strip()
        lines.append(f"- MFEM source clone + HIP build (ref={ref or 'master'})")
    if on("pytorch"):
        pwl = wl.get("pytorch", {}) or {}
        sb = pwl.get("source_build", {}) or {}
        if bool(sb.get("enabled", False)):
            idx = str(sb.get("index_url", "") or "").strip()
            ver = str(sb.get("rocm_sdk_version", "") or "").strip()
            ref = str(sb.get("pytorch_repo_hashtag", "") or "").strip()
            lines.append(f"- PyTorch (source build) + ROCm SDK (pip): index={idx or '(unset)'} rocm_sdk_version={ver or '(unset)'} ref={ref or '(default)'}")
        else:
            pkgs = pwl.get("packages", [])
            lines.append(f"- PyTorch (pip install ROCm wheels): {pkgs or '(packages not set)'}")
    if on("petsc_hip"):
        ref = str((wl.get("petsc", {}) or {}).get("ref", "") or "").strip()
        lines.append(f"- PETSc source clone + HIP build (ref={ref or 'release'})")
    if on("onnxruntime_rocm_wheel"):
        owl = wl.get("onnxruntime", {}) or {}
        repo = str(owl.get("repo_url", "https://github.com/microsoft/onnxruntime.git") or "https://github.com/microsoft/onnxruntime.git")
        ref = str(owl.get("ref", "main") or "main")
        work_root = str(
            owl.get("work_root", "validation/workspace/builds/onnxruntime_rocm")
            or "validation/workspace/builds/onnxruntime_rocm"
        )
        lines.append(f"- ONNX Runtime source clone + ROCm wheel build (repo={repo}, ref={ref}, work_root={work_root})")
    if on("tensorflow_rocm_wheel"):
        twl = wl.get("tensorflow", {}) or {}
        repo = str(twl.get("repo_url", "https://github.com/tensorflow/tensorflow.git") or "https://github.com/tensorflow/tensorflow.git")
        ref = str(twl.get("ref", "v2.20.0") or "v2.20.0")
        work_root = str(
            twl.get("work_root", "validation/workspace/builds/tensorflow_rocm")
            or "validation/workspace/builds/tensorflow_rocm"
        )
        lines.append(f"- TensorFlow source clone + ROCm wheel build (repo={repo}, ref={ref}, work_root={work_root})")

    # Size policy hint.
    max_gb = cfg.get("run", {}).get("max_download_gb", 0)
    max_one = cfg.get("run", {}).get("max_single_download_gb", 0)
    if max_gb or max_one:
        lines.append("")
        lines.append(f"Download limits: max_total={max_gb}GB, max_single={max_one}GB (best-effort)")

    print("\n".join(lines))


def _cmd_validate(argv: list[str]) -> int:
    profiles_dir = Path(__file__).resolve().parents[2] / "config" / "profiles"
    available_profiles = sorted({p.stem for p in profiles_dir.glob("*.yaml")})
    # Default profile is controlled by validation/config/defaults.yaml (run.profile).
    default_profile = load_config(profile=None).get("run", {}).get("profile") or "full"

    ap = argparse.ArgumentParser(prog="validate", description="Repo-local ROCm validation suite.")
    ap.add_argument(
        "--profile",
        default=None,
        help=f"Config profile (default: {default_profile}). Available: {', '.join(available_profiles)}.",
    )
    ap.add_argument("--build-dirs", default=None, help="Comma-separated build dirs to validate (default: auto).")
    ap.add_argument("--all-build-dirs", action="store_true", help="Validate all detected build dirs (default: only the preferred one).")
    ap.add_argument("--no-downloads", action="store_true", help="Disable network downloads (third-party steps will SKIP).")
    ap.add_argument("--yes", action="store_true", help="Assume 'yes' for prompts (non-interactive).")
    ap.add_argument("--power", action="store_true", help="Sample GPU power/utilization via sysfs during sustained-load tests.")
    ap.add_argument("--no-power", action="store_true", help="Disable GPU power/utilization sampling (override config).")
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
    if args.no_power:
        cfg["run"]["power_monitor"] = False
    if args.summary_multiline:
        cfg["run"]["summary_multiline"] = True

    ctx = Context.from_repo(cfg=cfg, enable_logs=bool(args.log))
    plan = build_plan(cfg)

    downloads_enabled = bool(cfg["run"].get("downloads_enabled", True))
    if downloads_enabled and bool(cfg["run"].get("ask_before_downloads", True)) and not args.yes:
        _print_download_plan(cfg)
        ok = confirm(
            "Proceed?",
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
