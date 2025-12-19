#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="${UNIT:-therock-gfx1031-build.service}"
LOG_FILE="${LOG_FILE:-${ROOT}/build.log}"
INTERVAL_SEC="${INTERVAL_SEC:-30}"
DURATION_SEC="${DURATION_SEC:-0}" # 0 = infinite
ONCE=0

usage() {
  cat <<'EOF'
Usage: monitor_gfx1031.sh [options]

Shows build status (systemd unit + tail of build.log) and can loop while this
chat session is active.

Options:
  --once             Print one snapshot and exit
  --interval <sec>   Poll interval seconds (default: 30)
  --duration <sec>   Stop after N seconds (default: 0 = infinite)
  -h, --help         Show help

Environment:
  UNIT           systemd user unit (default: therock-gfx1031-build.service)
  LOG_FILE       build log file (default: ./build.log)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --interval) INTERVAL_SEC="${2:-}"; shift 2 ;;
    --duration) DURATION_SEC="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

snapshot() {
  local state
  state="$(systemctl --user is-active "${UNIT}" 2>/dev/null || true)"
  echo "=== $(date -Is) unit=${UNIT} state=${state} ==="
  systemctl --user show "${UNIT}" -p MemoryHigh -p MemoryMax -p MemoryCurrent -p TasksCurrent -p ExecMainStatus -p Result 2>/dev/null || true
  if [[ -f "${LOG_FILE}" ]]; then
    echo "log=${LOG_FILE} size=$(stat -c %s "${LOG_FILE}" 2>/dev/null || echo 0)"
    tail -n 8 "${LOG_FILE}" || true
  else
    echo "log=${LOG_FILE} (missing)"
  fi
  if [[ "${state}" != "active" ]]; then
    echo "--- last errors in log ---"
    if [[ -f "${LOG_FILE}" ]]; then
      if command -v rg >/dev/null 2>&1; then
        rg -n "^FAILED:|\\bFAILED\\b|error:|CMake Error" "${LOG_FILE}" | tail -n 120 || true
      else
        grep -nE "^FAILED:|\\bFAILED\\b|error:|CMake Error" "${LOG_FILE}" | tail -n 120 || true
      fi
    fi
    echo "--- unit status ---"
    systemctl --user status "${UNIT}" --no-pager -n 20 || true
  fi
}

if (( ONCE )); then
  snapshot
  exit 0
fi

start_ts=$(date +%s)
while true; do
  snapshot
  state="$(systemctl --user is-active "${UNIT}" 2>/dev/null || true)"
  [[ "${state}" != "active" ]] && exit 0
  if (( DURATION_SEC > 0 )); then
    now_ts=$(date +%s)
    if (( now_ts - start_ts >= DURATION_SEC )); then
      exit 0
    fi
  fi
  sleep "${INTERVAL_SEC}"
done
