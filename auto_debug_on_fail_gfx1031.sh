#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DEFAULT="therock-gfx1031-build.service"
UNIT="${UNIT:-$UNIT_DEFAULT}"
LOG_FILE="${LOG_FILE:-${ROOT}/build.log}"
OUT_FILE="${OUT_FILE:-${ROOT}/build_result.txt}"
DEBUG_LOG="${DEBUG_LOG:-${ROOT}/autodebug.log}"
STATE_DIR="${ROOT}/.autodebug"
STATE_FILE="${STATE_DIR}/state"
MAX_RETRIES="${MAX_RETRIES:-3}"

usage() {
  cat <<'EOF'
Usage: auto_debug_on_fail_gfx1031.sh [options]

Runs after a detached build unit fails, collects diagnostics, applies a small
set of known-safe bootstrapping fixes, and re-starts the build (bounded retries).

Options:
  --unit <name>    systemd user unit to inspect (default: therock-gfx1031-build.service)
  --log <path>     build log path (default: ./build.log)
  --max-retries N  maximum auto-retry attempts (default: 3)
  -h, --help       show help

Environment:
  UNIT / LOG_FILE / OUT_FILE / DEBUG_LOG / MAX_RETRIES
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit) UNIT="${2:-}"; shift 2 ;;
    --log) LOG_FILE="${2:-}"; shift 2 ;;
    --max-retries) MAX_RETRIES="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

mkdir -p "${STATE_DIR}"

ts() { date -Is; }
log() { echo "[$(ts)] $*" | tee -a "${DEBUG_LOG}" >&2; }

get_retry_count() {
  if [[ -f "${STATE_FILE}" ]]; then
    cat "${STATE_FILE}" || echo 0
  else
    echo 0
  fi
}

set_retry_count() {
  echo "$1" > "${STATE_FILE}"
}

unit_state="$(systemctl --user is-active "${UNIT}" 2>/dev/null || true)"
if [[ "${unit_state}" == "active" ]]; then
  log "Unit ${UNIT} is still active; nothing to do."
  exit 0
fi

retry="$(get_retry_count)"
if ! [[ "${retry}" =~ ^[0-9]+$ ]]; then
  retry=0
fi
if (( retry >= MAX_RETRIES )); then
  log "Max retries reached (${retry}/${MAX_RETRIES}); not restarting build."
  exit 0
fi

log "Detected unit ${UNIT} state=${unit_state}; collecting diagnostics (attempt $((retry+1))/${MAX_RETRIES})..."
./collect_build_result_gfx1031.sh --unit "${UNIT}" --log "${LOG_FILE}" --out "${OUT_FILE}" >/dev/null 2>&1 || true

signature=""
if [[ -f "${LOG_FILE}" ]]; then
  if rg -q "OpenBLASConfig\\.cmake|openblas-config\\.cmake|ZLIBConfig\\.cmake|ROCmCMakeBuildTools|ROCMConfig\\.cmake" "${LOG_FILE}"; then
    signature="missing-cmake-configs"
  elif rg -q "librocm_sysdeps_.*\\.so" "${LOG_FILE}"; then
    signature="missing-rocm-sysdeps-so"
  elif rg -q "No space left on device" "${LOG_FILE}"; then
    signature="no-space-left"
  elif rg -q "Killed\\b|Out of memory" "${LOG_FILE}"; then
    signature="oom"
  fi
fi

log "Failure signature: ${signature:-unknown}"

case "${signature}" in
  missing-cmake-configs|missing-rocm-sysdeps-so)
    log "Running bootstrap to refresh stage/dist and sysdeps..."
    ./bootstrap_gfx1031.sh >> "${LOG_FILE}" 2>&1 || true
    ;;
  no-space-left)
    log "No space left on device: no automatic fix."
    set_retry_count "$((retry+1))"
    exit 0
    ;;
  oom)
    log "OOM/killed detected: no automatic fix (limits already set)."
    set_retry_count "$((retry+1))"
    exit 0
    ;;
  *)
    log "Unknown failure: attempting bootstrap once before retry."
    ./bootstrap_gfx1031.sh >> "${LOG_FILE}" 2>&1 || true
    ;;
esac

set_retry_count "$((retry+1))"
log "Restarting build (detached) after auto-fix attempt..."
./build_gfx1031.sh --skip-configure --detach >> "${LOG_FILE}" 2>&1 || true
log "Auto-debug run complete."

