from __future__ import annotations

from pathlib import Path


def write_placeholder_html(path: Path, *, title: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f\"\"\"<!doctype html>
<meta charset="utf-8">
<title>{title}</title>
<pre>HTML reporting is not implemented yet. See report.json next to this file.</pre>
\"\"\",
        encoding="utf-8",
    )

