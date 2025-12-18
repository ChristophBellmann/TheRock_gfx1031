#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${ROOT}/build.log"
MEM_HIGH="${MEM_HIGH:-28G}"
MEM_MAX="${MEM_MAX:-31G}"
CHECK_CLEAN=1
DO_CLEAN=0
EXTRA_CMAKE_ARGS=()

usage() {
  cat <<'EOF_USAGE'
Usage: build_gfx1031.sh [options] [-- <extra cmake args>]

Options:
  --clean           Remove build/ before configuring
  --no-check-clean  Skip clean build directory check
  -h, --help        Show this help

Environment overrides:
  MEM_HIGH / MEM_MAX      systemd-run memory limits (default 28G/31G)
  THEROCK_AMDGPU_TARGETS  override GPU target (default gfx1031)
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      DO_CLEAN=1
      shift
      ;;
    --no-check-clean)
      CHECK_CLEAN=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_CMAKE_ARGS+=("$@")
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "${ROOT}/.venv/bin/activate" ]]; then
  echo "Missing .venv; run the README venv setup first." >&2
  exit 1
fi

if ! command -v ccache >/dev/null 2>&1; then
  echo "ccache not found; install it or run setup_ccache.py as in README." >&2
  exit 1
fi
if ! command -v clang >/dev/null 2>&1 || ! command -v clang++ >/dev/null 2>&1; then
  echo "clang/clang++ not found; install clang (host compiler) before building." >&2
  exit 1
fi

if [[ ! -d "${ROOT}/rocm-libraries" || ! -d "${ROOT}/rocm-systems" ]]; then
  echo "Missing sources; run: python3 ./build_tools/fetch_sources.py" >&2
  exit 1
fi

if (( DO_CLEAN )); then
  rm -rf "${ROOT}/build"
fi

if (( CHECK_CLEAN )); then
  if [[ -d "${ROOT}/build" ]] && [[ -n "$(ls -A "${ROOT}/build" 2>/dev/null)" ]]; then
    echo "build/ is not clean. Use --clean or --no-check-clean." >&2
    exit 1
  fi
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

run_cmd_array() {
  local -a cmd=("$@")
  local escaped
  printf -v escaped '%q ' "${cmd[@]}"
  run_cmd "${escaped}"
}

TARGETS="${THEROCK_AMDGPU_TARGETS:-gfx1031}"

cmake_args=(
  -DTHEROCK_AMDGPU_TARGETS="${TARGETS}"
  -DTHEROCK_ENABLE_ALL=OFF
  -DTHEROCK_ENABLE_COMPILER=ON
  -DTHEROCK_ENABLE_CORE_RUNTIME=ON
  -DTHEROCK_ENABLE_HIP_RUNTIME=ON
  -DTHEROCK_ENABLE_HIPIFY=ON
  -DTHEROCK_ENABLE_BLAS=ON
  -DTHEROCK_ENABLE_PRIM=ON
  -DTHEROCK_ENABLE_RAND=ON
  -DTHEROCK_ENABLE_FFT=ON
  -DTHEROCK_ENABLE_SPARSE=ON
  -DTHEROCK_ENABLE_SOLVER=ON
  -DTHEROCK_ENABLE_HIPBLASLT=OFF
  -DTHEROCK_ENABLE_HIPSPARSELT=OFF
  -DTHEROCK_ENABLE_MIOPEN=ON
  -DTHEROCK_ENABLE_HIPDNN=ON
  -DTHEROCK_ENABLE_COMPOSABLE_KERNEL=ON
  -DTHEROCK_ENABLE_RCCL=ON
  -DTHEROCK_ENABLE_ROCWMMA=OFF
  -DTHEROCK_ENABLE_PROFILER=ON
  -DTHEROCK_ENABLE_DC_TOOLS=OFF
  -DBUILD_TESTING=ON
  -DCMAKE_C_COMPILER=clang
  -DCMAKE_CXX_COMPILER=clang++
  -DCMAKE_C_COMPILER_LAUNCHER=ccache
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
)

run_cmd_array cmake -B build -GNinja . "${cmake_args[@]}" "${EXTRA_CMAKE_ARGS[@]}"
run_cmd_array cmake --build build
