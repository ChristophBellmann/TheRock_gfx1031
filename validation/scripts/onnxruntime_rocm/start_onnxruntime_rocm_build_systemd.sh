#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK_ROOT="${WORK_ROOT:-${ROOT}/validation/workspace/builds/onnxruntime_rocm}"
UNIT="${UNIT:-onnxruntime-rocm-bootstrap.service}"
LOG_FILE="${LOG_FILE:-${WORK_ROOT}/build_start.log}"

mkdir -p "$(dirname "${LOG_FILE}")"

CMD="cd '${ROOT}' && bash '${ROOT}/validation/scripts/onnxruntime_rocm/build_onnxruntime_rocm_wheel.sh' >> '${LOG_FILE}' 2>&1"

systemd-run --user --unit "${UNIT}" --collect /usr/bin/bash -lc "${CMD}"

echo "Started unit: ${UNIT}"
echo "Log file: ${LOG_FILE}"
echo "Check: systemctl --user status ${UNIT} --no-pager"
