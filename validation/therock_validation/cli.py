from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .env import activated_env, choose_default_build_dir
from .utils import Ansi, REPO_ROOT, confirm, fmt_duration, is_tty, parse_select
from .checks.registry import all_checks
from .checks.rocm_sanity import Context


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Usability validation for in-tree ROCm (TheRock gfx1031).")
    ap.add_argument("--build-dir", default=None, help="Build directory to use (default: auto).")
    ap.add_argument("--select", default=None, help="Select checks by number (e.g. 1,2,3). 0 = all.")
    ap.add_argument("--log", default=None, help="Write full command output to this file.")
    ap.add_argument("--no-color", action="store_true", help="Disable ANSI color output.")
    ap.add_argument("--yes", action="store_true", help="Assume 'yes' for prompts (non-interactive).")
    ap.add_argument("--no-downloads", action="store_true", help="Do not download/build third-party deps (will SKIP).")
    args = ap.parse_args(argv)

    build_dir = args.build_dir or choose_default_build_dir()
    env = activated_env(build_dir)
    rocm = Path(env["ROCM_PATH"])
    if not rocm.is_dir():
        print(f"ERROR: ROCM_PATH not found: {rocm}", file=sys.stderr)
        print(f"Hint: build first (expected: {REPO_ROOT/build_dir/'dist'/'rocm'}).", file=sys.stderr)
        return 2

    ansi = Ansi(enabled=is_tty() and not args.no_color and not bool(args.log))
    logf = open(args.log, "w", encoding="utf-8") if args.log else None
    allow_downloads = (not args.no_downloads)

    checks = all_checks()
    selected = parse_select(args.select or "")
    if 0 in selected:
        selected = [c.idx for c in checks]
    if not selected:
        selected = [c.idx for c in checks]

    if allow_downloads:
        if not args.yes:
            ok = confirm("Run full validation (may download/build extra components)?", default_yes=True)
            if not ok:
                allow_downloads = False

    ctx = Context(env=env, build_dir=build_dir, rocm_path=rocm, logf=logf, allow_downloads=allow_downloads)

    print(f"{ansi.bold}gfx1031 usability validation{ansi.reset}")
    print(f"{ansi.dim}- build dir:{ansi.reset} {build_dir}")
    print(f"{ansi.dim}- ROCm:{ansi.reset} {rocm}")
    print(f"{ansi.dim}- selection:{ansi.reset} {', '.join(str(i) for i in selected)}")
    print(f"{ansi.dim}- downloads:{ansi.reset} {'enabled' if allow_downloads else 'disabled'}")
    print("")

    results = []
    for idx in selected:
        c = next((x for x in checks if x.idx == idx), None)
        if not c:
            continue
        print(f"{ansi.cyan}==>{ansi.reset} {ansi.label(f'{c.idx}) {c.name}')} {ansi.dim}(expected: {c.expected}){ansi.reset}")
        if logf is not None:
            logf.write(f"==> {c.idx}) {c.name}\n")
            logf.write(f"purpose: {c.purpose}\nexpected: {c.expected}\n\n")
            logf.flush()
        r = c.run(ctx)
        results.append(r)

    print("")
    print("==== validation summary ====")
    for i, r in enumerate(results, start=1):
        line = f"- {i:02d}) {ansi.label(r.name):<28} {ansi.status(r.status)} {ansi.dim}({r.duration}){ansi.reset}"
        if r.metric:
            line += f" {r.metric}"
        print(line)

    if args.log:
        print(f"{ansi.dim}Log:{ansi.reset} {args.log}")
        logf.close()
    else:
        print(f"{ansi.dim}Log:{ansi.reset} disabled (use --log file)")

    return 0 if all(r.status != "FAIL" for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())

