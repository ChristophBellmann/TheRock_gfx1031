from __future__ import annotations

"""
Compatibility shim.

New code should import:
- `core.tree` (build dir / dist discovery)
- `core.rocm_env` (explicit in-tree ROCm environment)
"""

from .rocm_env import activated_env, which  # noqa: F401
from .tree import detect_build_dirs, rocm_dist_for_build  # noqa: F401
