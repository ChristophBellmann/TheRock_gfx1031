from __future__ import annotations

from pathlib import Path


def notices_path() -> Path:
    return Path(__file__).resolve().parents[2] / "assets" / "notices" / "THIRD_PARTY_NOTICES.md"

