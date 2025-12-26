from __future__ import annotations

from __future__ import annotations

import shutil
import tarfile
from pathlib import Path
from typing import Any

from core.context import Context
from core.download import download
from core.rocm_env import which
from core.reporting.models import StepResult
from core.runner import fmt_duration
from steps.shared import dl_policy, downloads_enabled


def ensure_ollama(ctx: Context, cfg: dict[str, Any], env: dict[str, str]) -> tuple[str | None, StepResult | None]:
    """
    Ensure `ollama` is available. If not on PATH and downloads are enabled,
    download a prebuilt tarball into validation/workspace.
    """
    exe = which("ollama", env)
    if exe is not None:
        return exe, None
    if not downloads_enabled(cfg):
        return None, StepResult("<meta>", "ollama setup", "SKIP", "0ms", "downloads disabled")

    tgz = ctx.downloads_dir() / "ollama" / "ollama-linux-amd64.tgz"
    root = ctx.builds_dir() / "ollama" / "root"
    bin_path = root / "bin" / "ollama"
    if bin_path.exists():
        return str(bin_path), None

    url = str(cfg.get("workloads", {}).get("ollama", {}).get("url", "https://ollama.com/download/ollama-linux-amd64.tgz"))
    try:
        download(ctx, url, tgz, policy=dl_policy(cfg))
        if root.exists():
            shutil.rmtree(root)
        root.mkdir(parents=True, exist_ok=True)
        with tarfile.open(tgz, "r:gz") as tf:
            tf.extractall(path=root)
        if (root / "ollama").is_file() and not bin_path.exists():
            (root / "ollama").rename(bin_path)
        bin_path.chmod(0o755)
        return str(bin_path), None
    except Exception as e:
        return None, StepResult("<meta>", "ollama setup", "FAIL", "0ms", f"download/extract failed: {e}")
