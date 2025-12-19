#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${ROOT}/build.log"
BUILD_DIR="${BUILD_DIR:-build}"
STAGE="${STAGE:-1}"
STAGE1_BUILD_DIR="${STAGE1_BUILD_DIR:-build-stage1}"
MEM_HIGH="${MEM_HIGH:-28G}"
MEM_MAX="${MEM_MAX:-31G}"
CHECK_CLEAN=1
DO_CLEAN=1
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
ENABLE_ROCPROFSYS=false  # Phase 1: build ROCm stack without rocprofiler-systems; separate GCC build later

usage() {
  cat <<'EOF_USAGE'
Usage: configure_gfx1031.sh [options] [-- <extra cmake args>]

Options:
  --clean           Remove build/ before configuring (default)
  --no-clean        Do not remove build/ before configuring
  --no-check-clean  Skip clean build directory check
  -h, --help        Show this help

Environment overrides:
  MEM_HIGH / MEM_MAX      systemd-run memory limits (default 28G/31G)
  THEROCK_AMDGPU_TARGETS  override GPU target (default gfx1031)
  BUILD_DIR              build directory name (default build)
  STAGE                  bootstrapping stage: 1 (system clang) or 2 (use Stage-1 TheRock clang) (default 1)
  STAGE1_BUILD_DIR       Stage-1 build dir used by STAGE=2 (default build-stage1)
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      DO_CLEAN=1
      shift
      ;;
    --no-clean)
      DO_CLEAN=0
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
  eval "$(python3 "${ROOT}/build_tools/setup_ccache.py" --init)"
fi
if ! command -v ccache >/dev/null 2>&1; then
  echo "ccache not found; install it or run setup_ccache.py as in README." >&2
  exit 1
fi
export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-include_file_ctime}"
if ! command -v clang >/dev/null 2>&1 || ! command -v clang++ >/dev/null 2>&1; then
  if [[ -x "/usr/lib/llvm-18/bin/clang" ]]; then
    PATH="/usr/lib/llvm-18/bin:${PATH}"
  fi
fi
if ! command -v clang >/dev/null 2>&1 || ! command -v clang++ >/dev/null 2>&1; then
  echo "clang/clang++ not found; install clang (host compiler) before configuring." >&2
  exit 1
fi

# HIP compiler selection for CMake HIP-language projects:
# Prefer the in-tree toolchain from ./install if available.
# Do NOT auto-fall back to system hipcc, to avoid mixing with /opt/rocm.
HIP_COMPILER=""
ROCM_PREFIX="${ROOT}/install"
if [[ -x "${ROCM_PREFIX}/bin/hipcc" ]]; then
  HIP_COMPILER="${ROCM_PREFIX}/bin/hipcc"
  echo "Using in-tree hipcc for CMake HIP projects: ${HIP_COMPILER}" | tee -a "${LOG_FILE}"
else
  echo "INFO: ${ROCM_PREFIX}/bin/hipcc not found yet (expected on first bootstrap). Leaving CMAKE_HIP_COMPILER unset; TheRock HIP subprojects use COMPILER_TOOLCHAIN=amd-hip internally." | tee -a "${LOG_FILE}"
fi
if [[ ! -d "${ROOT}/rocm-libraries" || ! -d "${ROOT}/rocm-systems" ]]; then
  echo "Missing sources; run: python3 ./build_tools/fetch_sources.py" >&2
  exit 1
fi

if (( DO_CLEAN )); then
  rm -rf "${ROOT}/${BUILD_DIR}"
fi

if (( CHECK_CLEAN )); then
  if [[ -d "${ROOT}/${BUILD_DIR}" ]] && [[ -n "$(ls -A "${ROOT}/${BUILD_DIR}" 2>/dev/null)" ]]; then
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

BUILD_PATH="${ROOT}/${BUILD_DIR}"

# Stage-2: point the top-level compilers/linkers at the Stage-1 in-tree toolchain
# so even subprojects that forget COMPILER_TOOLCHAIN won't fall back to system clang.
if [[ "${STAGE}" == "2" ]]; then
  STAGE1_PATH="${ROOT}/${STAGE1_BUILD_DIR}"
  STAGE1_LLVM_BIN="${STAGE1_PATH}/compiler/amd-llvm/dist/lib/llvm/bin"
  if [[ ! -x "${STAGE1_LLVM_BIN}/clang" || ! -x "${STAGE1_LLVM_BIN}/clang++" || ! -x "${STAGE1_LLVM_BIN}/lld" ]]; then
    echo "STAGE=2 requires Stage-1 toolchain in ${STAGE1_LLVM_BIN} (missing clang/clang++/lld)." >&2
    echo "Build Stage-1 first (amd-llvm + hip-clr) in BUILD_DIR=${STAGE1_BUILD_DIR}." >&2
    exit 1
  fi
  STAGE2_C_COMPILER="${STAGE1_LLVM_BIN}/clang"
  STAGE2_CXX_COMPILER="${STAGE1_LLVM_BIN}/clang++"
  STAGE2_LINKER="${STAGE1_LLVM_BIN}/lld"
  STAGE2_AR="${STAGE1_LLVM_BIN}/llvm-ar"
  STAGE2_RANLIB="${STAGE1_LLVM_BIN}/llvm-ranlib"
  STAGE2_NM="${STAGE1_LLVM_BIN}/llvm-nm"
else
  STAGE2_C_COMPILER="clang"
  STAGE2_CXX_COMPILER="clang++"
  STAGE2_LINKER=""
  STAGE2_AR=""
  STAGE2_RANLIB=""
  STAGE2_NM=""
fi

cmake_args=(
	  -DTHEROCK_AMDGPU_TARGETS="${TARGETS}"
	  -DTHEROCK_DIST_AMDGPU_TARGETS="${TARGETS}"
	  -DTHEROCK_DIST_AMDGPU_FAMILIES="${TARGETS}"
	  -DDEFAULT_ROCM_PATH="${BUILD_PATH}/core/clr/dist"
	  -DROCM_PATH="${BUILD_PATH}/core/clr/dist"
	  -DROCM_DIR="${BUILD_PATH}/core/clr/dist"
	  -DROCM_ROOT="${BUILD_PATH}/core/clr/dist"
	  -DHIP_ROOT_DIR="${BUILD_PATH}/core/clr/dist"
	  -DHIP_DIR="${BUILD_PATH}/core/clr/dist"
	  -DHIP_PATH="${BUILD_PATH}/core/clr/dist"
	  -DTHEROCK_ENABLE_ALL=OFF
	  -DSPDLOG_FMT_EXTERNAL=OFF
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
  -DTHEROCK_ENABLE_ROCPROFSYS=$(bool_on_off "${ENABLE_ROCPROFSYS}")
  -DTHEROCK_ENABLE_DC_TOOLS=$(bool_on_off "${ENABLE_DC_TOOLS}")
  -DBUILD_TESTING=$(bool_on_off "${ENABLE_BUILD_TESTING}")
  -DTHEROCK_MIOPEN_USE_COMPOSABLE_KERNEL=$(bool_on_off "${ENABLE_COMPOSABLE_KERNEL}")
  # Keep these explicit so we don't accidentally inherit stale values from an
  # older in-place configure.
  -DCMAKE_C_FLAGS=
  -DCMAKE_CXX_FLAGS=
  -DCMAKE_C_COMPILER="${STAGE2_C_COMPILER}"
  -DCMAKE_CXX_COMPILER="${STAGE2_CXX_COMPILER}"
  -DCMAKE_C_COMPILER_LAUNCHER=ccache
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
)
if [[ -n "${STAGE2_LINKER}" ]]; then
  cmake_args+=( -DCMAKE_LINKER="${STAGE2_LINKER}" )
fi
if [[ -x "${STAGE2_AR}" ]]; then
  cmake_args+=( -DCMAKE_AR="${STAGE2_AR}" )
fi
if [[ -x "${STAGE2_RANLIB}" ]]; then
  cmake_args+=( -DCMAKE_RANLIB="${STAGE2_RANLIB}" )
fi
if [[ -x "${STAGE2_NM}" ]]; then
  cmake_args+=( -DCMAKE_NM="${STAGE2_NM}" )
fi
if [[ -n "${HIP_COMPILER}" ]]; then
  cmake_args+=( -DCMAKE_HIP_COMPILER="${HIP_COMPILER}" )
fi

run_cmd_array cmake -B "${BUILD_DIR}" -GNinja . "${cmake_args[@]}" "${EXTRA_CMAKE_ARGS[@]}"

echo "Configure complete. Next: ./build_gfx1031.sh (use --skip-configure to reuse) " | tee -a "${LOG_FILE}"
