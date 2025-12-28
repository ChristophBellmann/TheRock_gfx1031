#!/usr/bin/env bash
set -euo pipefail

echo "NOTE: run_rocm_container.sh is deprecated; use ./test_docker_gfx1031.sh --docker-only" >&2
exec ./test_docker_gfx1031.sh --docker-only "$@"

