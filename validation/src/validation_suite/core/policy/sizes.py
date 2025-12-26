from __future__ import annotations


def gb(n: float) -> int:
    return int(n * 1024 * 1024 * 1024)


def default_limits() -> dict[str, int]:
    # Conservative defaults; overridden by config/defaults.yaml
    return {"max_total_bytes": gb(8), "max_single_bytes": gb(4)}

