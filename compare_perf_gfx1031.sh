#!/usr/bin/env bash
set -euo pipefail

echo "NOTE: compare_perf_gfx1031.sh is deprecated; use ./test_docker_gfx1031.sh" >&2
exec ./test_docker_gfx1031.sh "$@"

