#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="therock-gfx1031-build.service"
LOG_FILE="${ROOT}/build.log"
OUT_FILE="${ROOT}/build_result.txt"

usage() {
  cat <<'EOF'
Usage: collect_build_result_gfx1031.sh [options]

Collects a concise build summary (unit state + exit status + last errors) into a file.

Options:
  --unit <name>    systemd user unit (default: therock-gfx1031-build.service)
  --log <path>     build log file (default: ./build.log)
  --out <path>     output summary file (default: ./build_result.txt)
  -h, --help       show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit)
      UNIT="${2:-}"; shift 2 ;;
    --log)
      LOG_FILE="${2:-}"; shift 2 ;;
    --out)
      OUT_FILE="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

mkdir -p "$(dirname "${OUT_FILE}")"

{
  echo "=== $(date -Is) ==="
  echo "unit=${UNIT}"
  echo "log=${LOG_FILE}"
  echo

  echo "--- systemd state ---"
  echo "is-active: $(systemctl --user is-active "${UNIT}" 2>/dev/null || true)"
  echo "is-failed: $(systemctl --user is-failed "${UNIT}" 2>/dev/null || true)"
  systemctl --user show "${UNIT}" \
    -p Result -p ExecMainStatus -p ExecMainCode -p ExecMainPID -p ActiveState -p SubState \
    -p MemoryHigh -p MemoryMax -p MemoryCurrent -p TasksCurrent 2>/dev/null || true
  echo

  echo "--- last unit log (journal) ---"
  journalctl --user -u "${UNIT}" -n 20 --no-pager 2>/dev/null || true
  echo

  if [[ -f "${LOG_FILE}" ]]; then
    echo "--- tail build.log ---"
    tail -n 60 "${LOG_FILE}" || true
    echo
    echo "--- errors in build.log ---"
    if command -v rg >/dev/null 2>&1; then
      rg -n "^FAILED:|\\bFAILED\\b|error:|CMake Error" "${LOG_FILE}" | tail -n 200 || true
    else
      grep -nE "^FAILED:|\\bFAILED\\b|error:|CMake Error" "${LOG_FILE}" | tail -n 200 || true
    fi
  else
    echo "build.log missing"
  fi
} > "${OUT_FILE}"

echo "Wrote ${OUT_FILE}"
