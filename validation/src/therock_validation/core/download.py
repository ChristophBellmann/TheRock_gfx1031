from __future__ import annotations

import hashlib
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from therock_validation.core.context import Context


@dataclass(frozen=True)
class DownloadPolicy:
    max_total_bytes: int
    max_single_bytes: int


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def download(ctx: Context, url: str, dest: Path, *, expected_sha256: str | None = None, policy: DownloadPolicy | None = None) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url) as r:
        total = r.headers.get("Content-Length")
        total_n = int(total) if total and total.isdigit() else None
        if policy is not None and total_n is not None and total_n > policy.max_single_bytes:
            raise RuntimeError(f"Download too large: {total_n} bytes > max_single_bytes={policy.max_single_bytes}")
        with dest.open("wb") as f:
            n = 0
            while True:
                chunk = r.read(1024 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                n += len(chunk)
                if policy is not None and n > policy.max_single_bytes:
                    raise RuntimeError(f"Download exceeded max_single_bytes={policy.max_single_bytes}")
                if policy is not None and n > policy.max_total_bytes:
                    raise RuntimeError(f"Download exceeded max_total_bytes={policy.max_total_bytes}")
    if expected_sha256 is not None:
        got = _sha256(dest)
        if got.lower() != expected_sha256.lower():
            raise RuntimeError(f"sha256 mismatch for {dest.name}: got {got}, expected {expected_sha256}")
