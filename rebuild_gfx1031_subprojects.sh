#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${ROOT}/build.log"
MEM_HIGH="${MEM_HIGH:-28G}"
MEM_MAX="${MEM_MAX:-31G}"

CONFIGURE=1
EXPUNGE=1
INCLUDE_UNSUPPORTED=0
TARGETS=()

usage() {
  cat <<'EOF'
Usage: rebuild_gfx1031_subprojects.sh [options] [targets...]

Options:
  --skip-configure   Skip the cmake configure step
  --no-expunge       Skip expunge; only build targets
  --include-unsupported
                    Include default unsupported targets (hipBLASLt hipSPARSELt rocWMMA)
  -h, --help         Show this help

Defaults:
  targets: none (pass targets explicitly)

Environment overrides:
  MEM_HIGH / MEM_MAX set systemd-run memory limits (default 28G/31G)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-configure)
      CONFIGURE=0
      shift
      ;;
    --no-expunge)
      EXPUNGE=0
      shift
      ;;
    --include-unsupported)
      INCLUDE_UNSUPPORTED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  if (( INCLUDE_UNSUPPORTED )); then
    TARGETS=(hipBLASLt hipSPARSELt rocWMMA)
  else
    echo "No targets provided. For gfx1031, hipBLASLt/hipSPARSELt/rocWMMA are excluded" >&2
    echo "and fall back to gfx1100. Pass explicit targets, or use --include-unsupported." >&2
    exit 1
  fi
fi

if [[ ! -f "${ROOT}/.venv/bin/activate" ]]; then
  echo "Missing .venv; run the README venv setup first." >&2
  exit 1
fi
if ! command -v ninja >/dev/null 2>&1; then
  echo "ninja not found; install it before building." >&2
  exit 1
fi

if [[ -f "${LOG_FILE}" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  mv "${LOG_FILE}" "${LOG_FILE}.bak-${ts}"
fi

run_cmd() {
  local cmd="$1"
  systemd-run --user --scope -p "MemoryHigh=${MEM_HIGH}" -p "MemoryMax=${MEM_MAX}" \
    bash -lc "source \"${ROOT}/.venv/bin/activate\" && ${cmd}" 2>&1 | tee -a "${LOG_FILE}"
}

if (( CONFIGURE )); then
  run_cmd "cmake -B build -GNinja . -DTHEROCK_AMDGPU_TARGETS=gfx1031 -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
fi

if (( EXPUNGE )); then
  for t in "${TARGETS[@]}"; do
    run_cmd "ninja -C build ${t}+expunge"
  done
fi

for t in "${TARGETS[@]}"; do
  run_cmd "ninja -C build ${t}"
done
