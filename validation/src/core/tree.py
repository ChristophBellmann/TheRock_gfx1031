from __future__ import annotations

from pathlib import Path


def detect_build_dirs(repo_root: Path) -> list[str]:
    # Legacy: returns all present build dirs in preferred order.
    out: list[str] = []
    for d in ["build-stage2", "build", "build-stage1"]:
        if (repo_root / d / "dist" / "rocm").is_dir():
            out.append(d)
    return out


def detect_default_build_dir(repo_root: Path) -> str:
    for d in ["build-stage2", "build", "build-stage1"]:
        if (repo_root / d / "dist" / "rocm").is_dir():
            return d
    return "build-stage2"


def rocm_dist_for_build(repo_root: Path, build_dir: str) -> Path:
    return repo_root / build_dir / "dist" / "rocm"
