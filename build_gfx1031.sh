#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${ROOT}/build.log"
MEM_HIGH="${MEM_HIGH:-28G}"
MEM_MAX="${MEM_MAX:-31G}"
CHECK_CLEAN=1
DO_CLEAN=0
SKIP_CONFIGURE=1
DETACH=0
EXTRA_CMAKE_ARGS=()

usage() {
  cat <<'EOF_USAGE'
Usage: build_gfx1031.sh [options] [-- <extra cmake args>]

Options:
  --clean           Remove build/ before configuring
  --no-check-clean  Skip clean build directory check
  --configure       Re-run CMake configure before building (default: skip)
  --skip-configure  Do not re-run CMake configure (default)
  --detach          Start build in background via systemd-run (logs to build.log)
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
    --skip-configure)
      SKIP_CONFIGURE=1
      shift
      ;;
    --configure)
      SKIP_CONFIGURE=0
      shift
      ;;
    --detach)
      DETACH=1
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

if [[ -x "${ROOT}/.local/bin/ccache" ]]; then
  PATH="${ROOT}/.local/bin:${PATH}"
fi
if ! command -v ccache >/dev/null 2>&1; then
  echo "ccache not found; install it or run setup_ccache.py as in README." >&2
  exit 1
fi
if [[ -x "${ROOT}/build_tools/setup_ccache.py" ]]; then
  eval "$(python3 "${ROOT}/build_tools/setup_ccache.py" --init)"
fi
export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-include_file_ctime}"
if ! command -v ninja >/dev/null 2>&1; then
  echo "ninja not found; install it before building." >&2
  exit 1
fi
if ! command -v clang >/dev/null 2>&1 || ! command -v clang++ >/dev/null 2>&1; then
  if [[ -x "/usr/lib/llvm-18/bin/clang" ]]; then
    PATH="/usr/lib/llvm-18/bin:${PATH}"
  fi
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

# Only enforce a clean build dir when (re)configuring.
if (( CHECK_CLEAN )) && (( SKIP_CONFIGURE == 0 )); then
  if [[ -d "${ROOT}/build" ]] && [[ -n "$(ls -A "${ROOT}/build" 2>/dev/null)" ]]; then
    echo "build/ is not clean. Use --clean or --no-check-clean." >&2
    exit 1
  fi
fi

# Only rotate when we are (re)configuring here; typical workflow is:
# configure -> bootstrap -> build, all appended to build.log.
if (( SKIP_CONFIGURE == 0 )); then
  if [[ -f "${LOG_FILE}" ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    mv "${LOG_FILE}" "${LOG_FILE}.bak-${ts}"
  fi
fi

run_cmd() {
  local cmd="$1"
  # Ensure sysdeps shared libs are found by host tools during the build (llvm-min-tblgen, etc.)
  local sysdeps_libs=(
    "${ROOT}/build/dist/rocm/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/zstd/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/zstd/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/zstd/build/build/b"
    "${ROOT}/build/third-party/sysdeps/linux/zlib/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/zlib/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/zlib/build/build/b"
    "${ROOT}/build/third-party/sysdeps/linux/bzip2/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/bzip2/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/liblzma/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/liblzma/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/elfutils/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/elfutils/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/libdrm/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/libdrm/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/numactl/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/numactl/build/stage/lib/rocm_sysdeps/lib"
  )
  local ldpath=""
  for p in "${sysdeps_libs[@]}"; do
    [[ -d "$p" ]] && ldpath="${ldpath:+$ldpath:}$p"
  done
  if (( DETACH )); then
    # Important: log piping must happen inside the transient unit, otherwise
    # killing the parent shell can terminate the pipeline and stop the build.
    systemd-run --user --scope --no-block \
      -p "MemoryHigh=${MEM_HIGH}" -p "MemoryMax=${MEM_MAX}" -p MemoryAccounting=yes -p CPUAccounting=yes \
      bash -lc "cd \"${ROOT}\" && source \"${ROOT}/.venv/bin/activate\" && export LD_LIBRARY_PATH=\"${ldpath:+$ldpath:}\${LD_LIBRARY_PATH}\" && ${cmd} 2>&1 | tee -a \"${LOG_FILE}\""
  else
    systemd-run --user --scope -p "MemoryHigh=${MEM_HIGH}" -p "MemoryMax=${MEM_MAX}" \
      bash -lc "cd \"${ROOT}\" && source \"${ROOT}/.venv/bin/activate\" && export LD_LIBRARY_PATH=\"${ldpath:+$ldpath:}\${LD_LIBRARY_PATH}\" && ${cmd}" 2>&1 | tee -a "${LOG_FILE}"
  fi
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
  -DTHEROCK_ENABLE_ROCPROFSYS=OFF
  -DBUILD_TESTING=OFF
  -DCMAKE_C_COMPILER=clang
  -DCMAKE_CXX_COMPILER=clang++
  -DCMAKE_C_COMPILER_LAUNCHER=ccache
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
)

if (( ! SKIP_CONFIGURE )); then
  run_cmd_array cmake -B build -GNinja . "${cmake_args[@]}" "${EXTRA_CMAKE_ARGS[@]}"
fi
run_cmd_array ninja -C build
