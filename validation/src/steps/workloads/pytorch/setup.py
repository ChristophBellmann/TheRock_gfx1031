from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from core.context import Context
from core.reporting.models import StepResult
from core.runner import fmt_duration, run_cmd
from steps.shared import downloads_enabled, pip_install


def ensure_pytorch(ctx: Context, cfg: dict[str, Any], env: dict[str, str], log: Path | None) -> StepResult | None:
    """
    Ensure a ROCm-enabled PyTorch is available in the validation venv.

    By default we do NOT auto-install torch because ROCm wheels are large and
    version/index dependent. If you want auto-install, set:
      workloads.pytorch.auto_install: true
    and optionally configure:
      workloads.pytorch.pip_args: [...]
      workloads.pytorch.packages: [...]
    """
    wl = cfg.get("workloads", {}).get("pytorch", {}) or {}
    auto = bool(wl.get("auto_install", False))
    if not auto:
        return None
    force = bool(wl.get("force_reinstall", False))
    expected = str(wl.get("expected_version_substr", "") or "").strip()

    # If torch is already installed in the validation venv, we can proceed even
    # when downloads are disabled.
    probe = run_cmd(ctx.repo_root, env, [sys.executable, "-c", "import torch; print(getattr(torch,'__version__',''))"], 30, log)
    installed_ver = (probe.out or "").strip() if probe.rc == 0 else ""
    if probe.rc == 0 and not force:
        if expected and expected not in installed_ver:
            # Installed torch does not match the requested wheel channel/version tag.
            # If downloads are disabled, proceed but warn (the step may still fail).
            if not downloads_enabled(cfg):
                return StepResult(
                    "<meta>",
                    "PyTorch setup",
                    "OK",
                    "0ms",
                    f"torch already installed but version mismatch: have={installed_ver} expected~={expected} (downloads disabled; proceeding)",
                )
        else:
            return None

    if not downloads_enabled(cfg):
        return StepResult("<meta>", "PyTorch setup", "SKIP", "0ms", "downloads disabled (cannot install torch)")

    t = int(cfg.get("timeouts_s", {}).get("pytorch_install", 1800))
    pip_args = list(wl.get("pip_args", []) or [])
    packages = list(wl.get("packages", []) or [])
    if not packages:
        packages = ["torch", "torchvision"]

    # `pip_install` doesn't support extra args; call pip directly for flexibility.
    cmd = [sys.executable, "-m", "pip", "install"] + pip_args + packages
    r = run_cmd(ctx.repo_root, env, cmd, t, log)
    if r.rc != 0:
        return StepResult("<meta>", "PyTorch setup", "FAIL", fmt_duration(r.dur_ms), f"pip rc={r.rc}")
    return None
