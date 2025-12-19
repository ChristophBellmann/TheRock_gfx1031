#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${ROOT}/rocprofiler_build.log"
MEM_HIGH="${MEM_HIGH:-28G}"
MEM_MAX="${MEM_MAX:-31G}"
BUILD_DIR="${ROOT}/build-rocprofiler-gcc"
INSTALL_PREFIX="${ROOT}/install-rocprofiler-gcc"

usage() {
  cat <<'EOF_USAGE'
Usage: configure_build_rocprofiler.sh [options] [-- <extra cmake args>]

Options:
  --clean           Remove build dir before configuring
  --no-build        Only configure
  -h, --help        Show this help

Environment overrides:
  MEM_HIGH / MEM_MAX      systemd-run memory limits (default 28G/31G)
EOF_USAGE
}

DO_CLEAN=0
DO_BUILD=1
EXTRA_CMAKE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      DO_CLEAN=1; shift ;;
    --no-build)
      DO_BUILD=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; EXTRA_CMAKE_ARGS+=("$@" ); break ;;
    *)
      echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -x "${ROOT}/.local/bin/ccache" ]]; then
  PATH="${ROOT}/.local/bin:${PATH}"
fi
if ! command -v gcc >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
  echo "gcc/g++ not found; install build-essential." >&2; exit 1
fi
if ! command -v ninja >/dev/null 2>&1; then
  echo "ninja not found; install it." >&2; exit 1
fi

if (( DO_CLEAN )); then
  rm -rf "${BUILD_DIR}"
fi
mkdir -p "${BUILD_DIR}"

run_cmd() {
  local cmd="$1"
  systemd-run --user --scope -p "MemoryHigh=${MEM_HIGH}" -p "MemoryMax=${MEM_MAX}" \
    bash -lc "${cmd}" 2>&1 | tee -a "${LOG_FILE}"
}

if [[ -f "${LOG_FILE}" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"; mv "${LOG_FILE}" "${LOG_FILE}.bak-${ts}"
fi

autoload_env=""
if [[ -x "${ROOT}/build_tools/setup_ccache.py" ]]; then
  autoload_env="$("${ROOT}/build_tools/setup_ccache.py")"
fi

run_cmd "export PATH=\"${PATH}\"; ${autoload_env}
cd \"${ROOT}\" && cmake -S . -B \"${BUILD_DIR}\" -GNinja \
  -DTHEROCK_ENABLE_ROCPROFSYS=ON \
  -DTHEROCK_DISABLE_GNU_CHECK=ON \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_CXX_COMPILER=g++ \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_INSTALL_PREFIX=\"${INSTALL_PREFIX}\" \
  ${EXTRA_CMAKE_ARGS[@]}"

if (( DO_BUILD )); then
  run_cmd "cd \"${BUILD_DIR}\" && ninja"
  run_cmd "cd \"${BUILD_DIR}\" && ninja install"
fi

echo "rocprofiler-systems build complete (GCC)" | tee -a "${LOG_FILE}"
