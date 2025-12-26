from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml


def _validation_root() -> Path:
    # .../validation/src/core/config.py -> validation/
    return Path(__file__).resolve().parents[2]


def _deep_merge(a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
    out = dict(a)
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)  # type: ignore[arg-type]
        else:
            out[k] = v
    return out


def load_config(profile: str | None = None) -> dict[str, Any]:
    vr = _validation_root()
    defaults = vr / "config" / "defaults.yaml"
    cfg: dict[str, Any] = yaml.safe_load(defaults.read_text(encoding="utf-8"))

    p = (profile or cfg.get("run", {}).get("profile") or "full").strip()
    prof = vr / "config" / "profiles" / f"{p}.yaml"
    if prof.is_file():
        overlay: dict[str, Any] = yaml.safe_load(prof.read_text(encoding="utf-8"))
        cfg = _deep_merge(cfg, overlay)
    return cfg
