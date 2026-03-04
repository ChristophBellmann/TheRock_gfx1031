#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
UNIT="${UNIT:-tensorflow-rocm-wheel-build.service}"
WORK_ROOT="${WORK_ROOT:-${ROOT}/validation/workspace/builds/tensorflow_rocm}"
LOG_FILE="${LOG_FILE:-${WORK_ROOT}/tf_build_live.log}"
INTERVAL_SEC="${INTERVAL_SEC:-30}"

UNIT="${UNIT}" LOG_FILE="${LOG_FILE}" INTERVAL_SEC="${INTERVAL_SEC}" \
  "${ROOT}/monitor_gfx1031.sh" "$@"
