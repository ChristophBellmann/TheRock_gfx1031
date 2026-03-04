#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
UNIT="${UNIT:-onnxruntime-rocm-bootstrap.service}"
WORK_ROOT="${WORK_ROOT:-${ROOT}/validation/workspace/builds/onnxruntime_rocm}"
LOG_FILE="${LOG_FILE:-${WORK_ROOT}/build_start.log}"
INTERVAL_SEC="${INTERVAL_SEC:-30}"

UNIT="${UNIT}" LOG_FILE="${LOG_FILE}" INTERVAL_SEC="${INTERVAL_SEC}" \
  "${ROOT}/monitor_gfx1031.sh" "$@"
