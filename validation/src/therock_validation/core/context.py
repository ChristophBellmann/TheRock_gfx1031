from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Context:
    repo_root: Path
    validation_root: Path
    workspace_root: Path
    run_id: str
    run_root: Path
    logs_dir: Path | None
    cfg: dict[str, Any]

    @staticmethod
    def from_repo(cfg: dict[str, Any], enable_logs: bool) -> "Context":
        validation_root = Path(__file__).resolve().parents[3]
        repo_root = validation_root.parent
        workspace_root = validation_root / "workspace"

        run_id = datetime.now().strftime("%Y-%m-%d_%H%M%S")
        run_root = workspace_root / "runs" / run_id
        logs_dir = run_root / "logs" if enable_logs else None
        if enable_logs:
            logs_dir.mkdir(parents=True, exist_ok=True)
        (run_root / "artifacts").mkdir(parents=True, exist_ok=True)
        return Context(
            repo_root=repo_root,
            validation_root=validation_root,
            workspace_root=workspace_root,
            run_id=run_id,
            run_root=run_root,
            logs_dir=logs_dir,
            cfg=cfg,
        )

    def cache_dir(self) -> Path:
        d = self.workspace_root / "cache"
        d.mkdir(parents=True, exist_ok=True)
        return d

    def downloads_dir(self) -> Path:
        d = self.cache_dir() / "downloads"
        d.mkdir(parents=True, exist_ok=True)
        return d

    def git_cache_dir(self) -> Path:
        d = self.cache_dir() / "git"
        d.mkdir(parents=True, exist_ok=True)
        return d

    def builds_dir(self) -> Path:
        d = self.workspace_root / "builds"
        d.mkdir(parents=True, exist_ok=True)
        return d

    def envs_dir(self) -> Path:
        d = self.workspace_root / "envs"
        d.mkdir(parents=True, exist_ok=True)
        return d

    def env_base(self) -> dict[str, str]:
        env = os.environ.copy()
        return env

