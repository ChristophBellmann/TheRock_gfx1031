#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${ROOT}/build.log"
MEM_HIGH="${MEM_HIGH:-28G}"
MEM_MAX="${MEM_MAX:-31G}"
CHECK_CLEAN=1
DO_CLEAN=0
EXTRA_CMAKE_ARGS=()

# Feature switches (set true/false)
ENABLE_COMPILER=true
ENABLE_CORE_RUNTIME=true
ENABLE_HIP_RUNTIME=true
ENABLE_HIPIFY=true
ENABLE_BLAS=true
ENABLE_PRIM=true
ENABLE_RAND=true
ENABLE_FFT=true
ENABLE_SPARSE=true
ENABLE_SOLVER=true
ENABLE_HIPBLASLT=false
ENABLE_HIPSPARSELT=false
ENABLE_MIOPEN=true
ENABLE_HIPDNN=true
ENABLE_COMPOSABLE_KERNEL=true
ENABLE_RCCL=true
ENABLE_ROCWMMA=false
ENABLE_PROFILER=true
ENABLE_DC_TOOLS=false
ENABLE_BUILD_TESTING=false

usage() {
  cat <<'EOF_USAGE'
Usage: configure_gfx1031.sh [options] [-- <extra cmake args>]

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

bool_on_off() {
  local v="$1"
  if [[ "$v" == "true" ]]; then
    echo "ON"
  else
    echo "OFF"
  fi
}

if [[ ! -f "${ROOT}/.venv/bin/activate" ]]; then
  echo "Creating .venv (python3 -m venv .venv && pip install -r requirements.txt)..."
  python3 -m venv "${ROOT}/.venv"
  # shellcheck disable=SC1091
  source "${ROOT}/.venv/bin/activate"
  pip install --upgrade pip
  pip install -r "${ROOT}/requirements.txt"
else
  # shellcheck disable=SC1091
  source "${ROOT}/.venv/bin/activate"
fi

if [[ -x "${ROOT}/.local/bin/ccache" ]]; then
  PATH="${ROOT}/.local/bin:${PATH}"
fi
if [[ -x "${ROOT}/build_tools/setup_ccache.py" ]]; then
  eval "$("${ROOT}/build_tools/setup_ccache.py")"
fi
if ! command -v ccache >/dev/null 2>&1; then
  echo "ccache not found; install it or run setup_ccache.py as in README." >&2
  exit 1
fi
if ! command -v clang >/dev/null 2>&1 || ! command -v clang++ >/dev/null 2>&1; then
  if [[ -x "/usr/lib/llvm-18/bin/clang" ]]; then
    PATH="/usr/lib/llvm-18/bin:${PATH}"
  fi
fi
if ! command -v clang >/dev/null 2>&1 || ! command -v clang++ >/dev/null 2>&1; then
  echo "clang/clang++ not found; install clang (host compiler) before configuring." >&2
  exit 1
fi

# Detect hipcc/amdclang++ for HIP builds
HIP_COMPILER=""
if [[ -x "${ROOT}/build/dist/rocm/bin/hipcc" ]]; then
  HIP_COMPILER="${ROOT}/build/dist/rocm/bin/hipcc"
elif command -v hipcc >/dev/null 2>&1; then
  HIP_COMPILER="$(command -v hipcc)"
elif [[ -x "/opt/rocm/bin/hipcc" ]]; then
  HIP_COMPILER="/opt/rocm/bin/hipcc"
elif command -v amdclang++ >/dev/null 2>&1; then
  HIP_COMPILER="$(command -v amdclang++)"
fi
if [[ -z "${HIP_COMPILER}" ]]; then
  echo "Warning: hipcc/amdclang++ not found; HIP projects will rely on default toolchain." >&2
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
  -DTHEROCK_ENABLE_COMPILER=$(bool_on_off "${ENABLE_COMPILER}")
  -DTHEROCK_ENABLE_CORE_RUNTIME=$(bool_on_off "${ENABLE_CORE_RUNTIME}")
  -DTHEROCK_ENABLE_HIP_RUNTIME=$(bool_on_off "${ENABLE_HIP_RUNTIME}")
  -DTHEROCK_ENABLE_HIPIFY=$(bool_on_off "${ENABLE_HIPIFY}")
  -DTHEROCK_ENABLE_BLAS=$(bool_on_off "${ENABLE_BLAS}")
  -DTHEROCK_ENABLE_PRIM=$(bool_on_off "${ENABLE_PRIM}")
  -DTHEROCK_ENABLE_RAND=$(bool_on_off "${ENABLE_RAND}")
  -DTHEROCK_ENABLE_FFT=$(bool_on_off "${ENABLE_FFT}")
  -DTHEROCK_ENABLE_SPARSE=$(bool_on_off "${ENABLE_SPARSE}")
  -DTHEROCK_ENABLE_SOLVER=$(bool_on_off "${ENABLE_SOLVER}")
  -DTHEROCK_ENABLE_HIPBLASLT=$(bool_on_off "${ENABLE_HIPBLASLT}")
  -DTHEROCK_ENABLE_HIPSPARSELT=$(bool_on_off "${ENABLE_HIPSPARSELT}")
  -DTHEROCK_ENABLE_MIOPEN=$(bool_on_off "${ENABLE_MIOPEN}")
  -DTHEROCK_ENABLE_HIPDNN=$(bool_on_off "${ENABLE_HIPDNN}")
  -DTHEROCK_ENABLE_COMPOSABLE_KERNEL=$(bool_on_off "${ENABLE_COMPOSABLE_KERNEL}")
  -DTHEROCK_ENABLE_RCCL=$(bool_on_off "${ENABLE_RCCL}")
  -DTHEROCK_ENABLE_ROCWMMA=$(bool_on_off "${ENABLE_ROCWMMA}")
  -DTHEROCK_ENABLE_PROFILER=$(bool_on_off "${ENABLE_PROFILER}")
  -DTHEROCK_ENABLE_DC_TOOLS=$(bool_on_off "${ENABLE_DC_TOOLS}")
  -DBUILD_TESTING=$(bool_on_off "${ENABLE_BUILD_TESTING}")
  -DCMAKE_C_COMPILER=clang
  -DCMAKE_CXX_COMPILER=clang++
  -DCMAKE_C_COMPILER_LAUNCHER=ccache
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
)
if [[ -n "${HIP_COMPILER}" ]]; then
  cmake_args+=( -DCMAKE_HIP_COMPILER="${HIP_COMPILER}" )
fi

run_cmd_array cmake -B build -GNinja . "${cmake_args[@]}" "${EXTRA_CMAKE_ARGS[@]}"
