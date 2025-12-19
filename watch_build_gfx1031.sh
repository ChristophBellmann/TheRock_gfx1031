#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="${UNIT:-therock-gfx1031-build.service}"
LOG_FILE="${LOG_FILE:-${ROOT}/build.log}"
INTERVAL_SEC="${INTERVAL_SEC:-10}"
ONCE=0

usage() {
  cat <<'EOF'
Usage: watch_build_gfx1031.sh [options]

Watches the detached build unit (systemd user service) and tail-summarizes build.log.
On failure, prints the last error-ish lines and the unit status.

Options:
  --once          Print one snapshot and exit
  --interval N    Poll interval seconds (default: 10)
  -h, --help      Show help

Environment:
  UNIT            systemd user unit (default: therock-gfx1031-build.service)
  LOG_FILE        path to build.log (default: ./build.log)
  INTERVAL_SEC    poll interval seconds (default: 10)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)
      ONCE=1
      shift
      ;;
    --interval)
      INTERVAL_SEC="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

snapshot() {
  local state
  state="$(systemctl --user is-active "${UNIT}" 2>/dev/null || true)"
  echo "=== $(date -Is)  unit=${UNIT}  state=${state} ==="

  if [[ -f "${LOG_FILE}" ]]; then
    local sz
    sz="$(stat -c %s "${LOG_FILE}" 2>/dev/null || echo 0)"
    echo "log=${LOG_FILE}  size=${sz}"
    tail -n 6 "${LOG_FILE}" || true
  else
    echo "log=${LOG_FILE} (missing)"
  fi

  # If stopped/failed, print extra diagnostics.
  if [[ "${state}" != "active" ]]; then
    echo "--- unit status ---"
    systemctl --user status "${UNIT}" --no-pager -n 20 || true
    echo "--- last errors in build.log ---"
    if [[ -f "${LOG_FILE}" ]]; then
      rg -n "^FAILED:|\\bFAILED\\b|error:|CMake Error" "${LOG_FILE}" | tail -n 80 || true
    fi
  fi
}

if (( ONCE )); then
  snapshot
  exit 0
fi

while true; do
  snapshot
  state="$(systemctl --user is-active "${UNIT}" 2>/dev/null || true)"
  if [[ "${state}" != "active" ]]; then
    exit 0
  fi
  sleep "${INTERVAL_SEC}"
done

