#!/usr/bin/env bash
set -euo pipefail

export BUILD_DIR="${BUILD_DIR:-build-stage2}"
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_gfx1031.sh" "$@"

