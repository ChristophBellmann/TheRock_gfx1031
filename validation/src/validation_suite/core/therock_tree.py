from __future__ import annotations

from pathlib import Path


def detect_build_dirs(repo_root: Path) -> list[str]:
    out: list[str] = []
    for d in ["build-stage2", "build", "build-stage1"]:
        if (repo_root / d / "dist" / "rocm").is_dir():
            out.append(d)
    return out or ["build-stage2"]


def rocm_dist_for_build(repo_root: Path, build_dir: str) -> Path:
    return repo_root / build_dir / "dist" / "rocm"

