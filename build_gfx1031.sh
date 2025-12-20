#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Common defaults (override via env or flags)
LOG_FILE="${LOG_FILE:-${ROOT}/build.log}"
BUILD_DIR="${BUILD_DIR:-build}"
STAGE="${STAGE:-1}"
STAGE1_BUILD_DIR="${STAGE1_BUILD_DIR:-build-stage1}"
MEM_HIGH="${MEM_HIGH:-28G}"
MEM_MAX="${MEM_MAX:-31G}"
PRESERVE_LD_LIBRARY_PATH="${PRESERVE_LD_LIBRARY_PATH:-0}"
DETACH=0
JOBS="${JOBS:-}"
WAIT_LOCK=0

# Default feature switches (override by exporting ENABLE_* or via configure_gfx1031.sh wrapper)
ENABLE_COMPILER="${ENABLE_COMPILER:-true}"
ENABLE_CORE_RUNTIME="${ENABLE_CORE_RUNTIME:-true}"
ENABLE_HIP_RUNTIME="${ENABLE_HIP_RUNTIME:-true}"
ENABLE_HIPIFY="${ENABLE_HIPIFY:-true}"
ENABLE_BLAS="${ENABLE_BLAS:-true}"
ENABLE_PRIM="${ENABLE_PRIM:-true}"
ENABLE_RAND="${ENABLE_RAND:-true}"
ENABLE_FFT="${ENABLE_FFT:-true}"
ENABLE_SPARSE="${ENABLE_SPARSE:-true}"
ENABLE_SOLVER="${ENABLE_SOLVER:-true}"
ENABLE_HIPBLASLT="${ENABLE_HIPBLASLT:-false}"
ENABLE_HIPSPARSELT="${ENABLE_HIPSPARSELT:-false}"
ENABLE_MIOPEN="${ENABLE_MIOPEN:-true}"
ENABLE_HIPDNN="${ENABLE_HIPDNN:-true}"
ENABLE_COMPOSABLE_KERNEL="${ENABLE_COMPOSABLE_KERNEL:-true}"
ENABLE_RCCL="${ENABLE_RCCL:-true}"
ENABLE_ROCWMMA="${ENABLE_ROCWMMA:-false}"
ENABLE_PROFILER="${ENABLE_PROFILER:-true}"
ENABLE_DC_TOOLS="${ENABLE_DC_TOOLS:-false}"
ENABLE_BUILD_TESTING="${ENABLE_BUILD_TESTING:-false}"
ENABLE_ROCPROFSYS="${ENABLE_ROCPROFSYS:-false}"

usage() {
  cat <<'EOF_USAGE'
Usage: build_gfx1031.sh <command> [options] [args...]

Commands:
  configure         Top-level CMake configure (Stage-1/Stage-2 supported)
  configure-sub     (Re)configure specific subprojects only (<name>+configure)
  bootstrap         Build early sysdeps (+dist) and verify outputs
  build             Build the full superbuild (ninja -C <builddir>)
  rebuild           Expunge + rebuild specific subprojects
  expunge           Expunge specific subprojects (no rebuild)
  rocprofiler-gcc   Phase-2: build rocprofiler-systems with GCC in a separate build dir

Shared options:
  --stage1                Use BUILD_DIR=build-stage1 and STAGE=1
  --stage2                Use BUILD_DIR=build-stage2 and STAGE=2 (uses Stage-1 toolchain)
  --build-dir <dir>       Override build directory (default: build)
  --stage1-build-dir <d>  Stage-1 build dir used by --stage2 (default: build-stage1)
  --wait                  Wait for an in-progress build lock (per BUILD_DIR)
  -j, --jobs <n>          Ninja parallelism (optional)
  --detach                Run build in background via systemd-run (build/configure-sub only)
  -h, --help              Show this help

Configure options:
  --clean                 Remove BUILD_DIR before configuring (default)
  --no-clean              Do not remove BUILD_DIR before configuring
  --no-check-clean        Skip "build dir must be empty" check
  -- <extra cmake args>   Extra args forwarded to top-level cmake

Environment:
  LOG_FILE, BUILD_DIR, STAGE, STAGE1_BUILD_DIR
  MEM_HIGH / MEM_MAX, PRESERVE_LD_LIBRARY_PATH, JOBS
  ENABLE_* (see configure_gfx1031.sh) and THEROCK_AMDGPU_TARGETS
EOF_USAGE
}

bool_on_off() {
  local v="$1"
  if [[ "${v}" == "true" ]]; then echo "ON"; else echo "OFF"; fi
}

require_cmd() {
  local exe="$1"
  local hint="$2"
  if ! command -v "${exe}" >/dev/null 2>&1; then
    echo "${exe} not found; ${hint}" >&2
    exit 1
  fi
}

ensure_venv() {
  if [[ ! -f "${ROOT}/.venv/bin/activate" ]]; then
    echo "Creating .venv (python3 -m venv .venv && pip install -r requirements.txt)..." | tee -a "${LOG_FILE}"
    python3 -m venv "${ROOT}/.venv"
    # shellcheck disable=SC1091
    source "${ROOT}/.venv/bin/activate"
    pip install --upgrade pip
    pip install -r "${ROOT}/requirements.txt"
  else
    # shellcheck disable=SC1091
    source "${ROOT}/.venv/bin/activate"
  fi
}

setup_ccache() {
  if [[ -x "${ROOT}/.local/bin/ccache" ]]; then
    PATH="${ROOT}/.local/bin:${PATH}"
  fi
  if [[ -x "${ROOT}/build_tools/setup_ccache.py" ]]; then
    eval "$(python3 "${ROOT}/build_tools/setup_ccache.py" --init)"
  fi
  export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-include_file_ctime}"
  require_cmd ccache "install it or run setup_ccache.py as in README."
}

compute_sysdeps_ld_library_path() {
  local -a sysdeps_libs=(
    "${ROOT}/${BUILD_DIR}/dist/rocm/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/zstd/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/zstd/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/zstd/build/build/b"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/zlib/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/zlib/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/zlib/build/build/b"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/bzip2/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/bzip2/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/liblzma/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/liblzma/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/elfutils/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/elfutils/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/libdrm/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/libdrm/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/numactl/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/numactl/build/stage/lib/rocm_sysdeps/lib"
  )
  local ldpath=""
  local p
  for p in "${sysdeps_libs[@]}"; do
    [[ -d "$p" ]] && ldpath="${ldpath:+$ldpath:}$p"
  done
  echo "${ldpath}"
}

run_cmd() {
  local cmdline="$1"
  local ldpath
  ldpath="$(compute_sysdeps_ld_library_path)"
  local ld_export="export LD_LIBRARY_PATH=\"${ldpath}\""
  if [[ "${PRESERVE_LD_LIBRARY_PATH}" == "1" ]]; then
    ld_export="export LD_LIBRARY_PATH=\"${ldpath:+$ldpath:}\${LD_LIBRARY_PATH}\""
  fi
  local jobs_arg=""
  if [[ -n "${JOBS}" ]]; then
    jobs_arg="-j ${JOBS}"
  fi
  if (( DETACH )); then
    local unit="therock-gfx1031-${BUILD_DIR}-${cmd}"
    systemd-run --user --no-block --quiet --collect --unit "${unit}" --property=Restart=no \
      --property="MemoryHigh=${MEM_HIGH}" --property="MemoryMax=${MEM_MAX}" \
      --property=MemoryAccounting=yes --property=CPUAccounting=yes \
      bash -lc "cd \"${ROOT}\" && source \"${ROOT}/.venv/bin/activate\" && ${ld_export} && ${cmdline} ${jobs_arg} >> \"${LOG_FILE}\" 2>&1"
    echo "Started as user unit: ${unit}.service (logs: ${LOG_FILE})"
  else
    systemd-run --user --scope -p "MemoryHigh=${MEM_HIGH}" -p "MemoryMax=${MEM_MAX}" \
      bash -lc "cd \"${ROOT}\" && source \"${ROOT}/.venv/bin/activate\" && ${ld_export} && ${cmdline} ${jobs_arg}" 2>&1 | tee -a "${LOG_FILE}"
  fi
}

run_cmd_array() {
  local -a cmdline=("$@")
  local escaped
  printf -v escaped '%q ' "${cmdline[@]}"
  run_cmd "${escaped}"
}

cmd="${1:-}"
if [[ -z "${cmd}" || "${cmd}" == "-h" || "${cmd}" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

# Parse shared flags first.
DO_CLEAN=1
CHECK_CLEAN=1
EXTRA_CMAKE_ARGS=()
SUBPROJECTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage1)
      BUILD_DIR="build-stage1"
      STAGE=1
      shift
      ;;
    --stage2)
      BUILD_DIR="build-stage2"
      STAGE=2
      shift
      ;;
    --build-dir)
      BUILD_DIR="${2:-}"
      shift 2
      ;;
    --stage1-build-dir)
      STAGE1_BUILD_DIR="${2:-}"
      shift 2
      ;;
    --detach)
      DETACH=1
      shift
      ;;
    --wait)
      WAIT_LOCK=1
      shift
      ;;
    -j|--jobs)
      JOBS="${2:-}"
      shift 2
      ;;
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
    --)
      shift
      if [[ "${cmd}" == "configure" ]]; then
        EXTRA_CMAKE_ARGS+=("$@")
      else
        SUBPROJECTS+=("$@")
      fi
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      SUBPROJECTS+=("$1")
      shift
      ;;
  esac
done

# Per-builddir lock (prevents concurrent runs touching the same BUILD_DIR).
LOCK_FILE="${ROOT}/${BUILD_DIR}/.therock_build.lock"
LOCK_FD=200
mkdir -p "${ROOT}/${BUILD_DIR}"
exec {LOCK_FD}>"${LOCK_FILE}"
if (( WAIT_LOCK )); then
  flock "${LOCK_FD}"
else
  if ! flock -n "${LOCK_FD}"; then
    echo "Another build is already running for BUILD_DIR='${BUILD_DIR}' (lock: ${LOCK_FILE})." >&2
    echo "Use: ./build_gfx1031.sh ${cmd} --build-dir ${BUILD_DIR} --wait" >&2
    exit 3
  fi
fi

# Setup prerequisites (venv + ccache) for all commands.
require_cmd python3 "install python3 and python3-venv."
ensure_venv
setup_ccache
require_cmd ninja "install it before building."
require_cmd cmake "install CMake (system /usr/bin/cmake recommended)."

if [[ ! -d "${ROOT}/rocm-libraries" || ! -d "${ROOT}/rocm-systems" ]]; then
  echo "Missing sources; run: python3 ./build_tools/fetch_sources.py" >&2
  exit 1
fi

if [[ "${cmd}" != "configure" && "${cmd}" != "rocprofiler-gcc" ]]; then
  if [[ ! -f "${ROOT}/${BUILD_DIR}/build.ninja" ]]; then
    echo "Missing ${BUILD_DIR}/build.ninja; run: ./build_gfx1031.sh configure --build-dir ${BUILD_DIR}" >&2
    exit 1
  fi
fi

bootstrap_targets=(
  "rocm-cmake+dist"
  "therock-zlib+dist"
  "therock-zstd+dist"
  "therock-numactl+dist"
  "therock-elfutils+dist"
  "therock-host-blas+dist"
  "therock-fmt+dist"
  "therock-spdlog+dist"
  "therock-yaml-cpp+dist"
  "therock-nlohmann-json+dist"
  "therock-eigen+dist"
  "therock-FunctionalPlus+dist"
)

verify_bootstrap() {
  local -a expect_paths=(
    "${ROOT}/${BUILD_DIR}/base/rocm-cmake/dist/share/rocmcmakebuildtools/cmake"
    "${ROOT}/${BUILD_DIR}/base/rocm-cmake/dist/share/rocm/cmake"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/zlib/build/dist/lib/rocm_sysdeps/lib/cmake/ZLIB/zlib-config.cmake"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/zlib/build/dist/lib/rocm_sysdeps/lib/librocm_sysdeps_z.so.1"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/zstd/build/dist/lib/rocm_sysdeps/lib/cmake/zstd/zstdConfig.cmake"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/zstd/build/dist/lib/rocm_sysdeps/lib/librocm_sysdeps_zstd.so.1"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/numactl/build/dist/lib/rocm_sysdeps/lib/cmake/NUMA/numa-config.cmake"
    "${ROOT}/${BUILD_DIR}/third-party/sysdeps/linux/elfutils/build/dist/lib/rocm_sysdeps/lib/cmake/LibElf/libelf-config.cmake"
    "${ROOT}/${BUILD_DIR}/third-party/host-blas/dist/lib/host-math/lib/cmake/OpenBLAS/OpenBLASConfig.cmake"
  )
  local missing=0
  local p
  for p in "${expect_paths[@]}"; do
    if [[ ! -e "${p}" ]]; then
      echo "MISSING: ${p}" | tee -a "${LOG_FILE}"
      missing=1
    else
      echo "OK: ${p}" | tee -a "${LOG_FILE}"
    fi
  done
  return "${missing}"
}

configure_top() {
  local targets="${THEROCK_AMDGPU_TARGETS:-gfx1031}"
  local build_path="${ROOT}/${BUILD_DIR}"

  if [[ -f "${LOG_FILE}" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    mv "${LOG_FILE}" "${LOG_FILE}.bak-${ts}"
  fi

  if (( DO_CLEAN )); then
    rm -rf "${build_path}"
  fi
  if (( CHECK_CLEAN )) && [[ -d "${build_path}" ]] && [[ -n "$(ls -A "${build_path}" 2>/dev/null)" ]]; then
    echo "${BUILD_DIR}/ is not clean. Use --clean or --no-check-clean." >&2
    exit 1
  fi

  # Host compiler selection. Use absolute paths so cmake --regenerate-during-build
  # does not depend on PATH.
  local c_compiler=""
  local cxx_compiler=""
  local linker=""
  local ar=""
  local ranlib=""
  local nm=""

  if [[ "${STAGE}" == "2" ]]; then
    local stage1_llvm_bin="${ROOT}/${STAGE1_BUILD_DIR}/compiler/amd-llvm/dist/lib/llvm/bin"
    if [[ ! -x "${stage1_llvm_bin}/clang" || ! -x "${stage1_llvm_bin}/clang++" || ! -x "${stage1_llvm_bin}/lld" ]]; then
      echo "STAGE=2 requires Stage-1 toolchain in ${stage1_llvm_bin} (missing clang/clang++/lld)." >&2
      exit 1
    fi
    c_compiler="${stage1_llvm_bin}/clang"
    cxx_compiler="${stage1_llvm_bin}/clang++"
    linker="${stage1_llvm_bin}/lld"
    ar="${stage1_llvm_bin}/llvm-ar"
    ranlib="${stage1_llvm_bin}/llvm-ranlib"
    nm="${stage1_llvm_bin}/llvm-nm"
  else
    # Prefer explicit llvm-18 if present.
    if [[ -x "/usr/lib/llvm-18/bin/clang" && -x "/usr/lib/llvm-18/bin/clang++" ]]; then
      c_compiler="/usr/lib/llvm-18/bin/clang"
      cxx_compiler="/usr/lib/llvm-18/bin/clang++"
    else
      c_compiler="$(command -v clang || true)"
      cxx_compiler="$(command -v clang++ || true)"
    fi
  fi

  if [[ -z "${c_compiler}" || -z "${cxx_compiler}" ]]; then
    echo "clang/clang++ not found; install clang-18 (or provide clang in PATH)." >&2
    exit 1
  fi

  # HIP compiler selection for CMake HIP-language projects:
  # Prefer in-tree toolchain from ./install if present. Do NOT auto-fall back to system hipcc.
  local hip_compiler=""
  local rocm_prefix="${ROOT}/install"
  if [[ -x "${rocm_prefix}/bin/hipcc" ]]; then
    hip_compiler="${rocm_prefix}/bin/hipcc"
    echo "Using in-tree hipcc for CMake HIP projects: ${hip_compiler}" | tee -a "${LOG_FILE}"
  else
    echo "INFO: ${rocm_prefix}/bin/hipcc not found yet (expected on first bootstrap). Leaving CMAKE_HIP_COMPILER unset; TheRock HIP subprojects use COMPILER_TOOLCHAIN=amd-hip internally." | tee -a "${LOG_FILE}"
  fi

  local -a cmake_args=(
    "-DTHEROCK_AMDGPU_TARGETS=${targets}"
    "-DTHEROCK_DIST_AMDGPU_TARGETS=${targets}"
    "-DTHEROCK_DIST_AMDGPU_FAMILIES=${targets}"
    "-DDEFAULT_ROCM_PATH=${build_path}/core/clr/dist"
    "-DROCM_PATH=${build_path}/core/clr/dist"
    "-DROCM_DIR=${build_path}/core/clr/dist"
    "-DROCM_ROOT=${build_path}/core/clr/dist"
    "-DHIP_ROOT_DIR=${build_path}/core/clr/dist"
    "-DHIP_DIR=${build_path}/core/clr/dist"
    "-DHIP_PATH=${build_path}/core/clr/dist"
    "-DTHEROCK_ENABLE_ALL=OFF"
    "-DSPDLOG_FMT_EXTERNAL=OFF"
    "-DTHEROCK_ENABLE_COMPILER=$(bool_on_off "${ENABLE_COMPILER}")"
    "-DTHEROCK_ENABLE_CORE_RUNTIME=$(bool_on_off "${ENABLE_CORE_RUNTIME}")"
    "-DTHEROCK_ENABLE_HIP_RUNTIME=$(bool_on_off "${ENABLE_HIP_RUNTIME}")"
    "-DTHEROCK_ENABLE_HIPIFY=$(bool_on_off "${ENABLE_HIPIFY}")"
    "-DTHEROCK_ENABLE_BLAS=$(bool_on_off "${ENABLE_BLAS}")"
    "-DTHEROCK_ENABLE_PRIM=$(bool_on_off "${ENABLE_PRIM}")"
    "-DTHEROCK_ENABLE_RAND=$(bool_on_off "${ENABLE_RAND}")"
    "-DTHEROCK_ENABLE_FFT=$(bool_on_off "${ENABLE_FFT}")"
    "-DTHEROCK_ENABLE_SPARSE=$(bool_on_off "${ENABLE_SPARSE}")"
    "-DTHEROCK_ENABLE_SOLVER=$(bool_on_off "${ENABLE_SOLVER}")"
    "-DTHEROCK_ENABLE_HIPBLASLT=$(bool_on_off "${ENABLE_HIPBLASLT}")"
    "-DTHEROCK_ENABLE_HIPSPARSELT=$(bool_on_off "${ENABLE_HIPSPARSELT}")"
    "-DTHEROCK_ENABLE_MIOPEN=$(bool_on_off "${ENABLE_MIOPEN}")"
    "-DTHEROCK_ENABLE_HIPDNN=$(bool_on_off "${ENABLE_HIPDNN}")"
    "-DTHEROCK_ENABLE_COMPOSABLE_KERNEL=$(bool_on_off "${ENABLE_COMPOSABLE_KERNEL}")"
    "-DTHEROCK_ENABLE_RCCL=$(bool_on_off "${ENABLE_RCCL}")"
    "-DTHEROCK_ENABLE_ROCWMMA=$(bool_on_off "${ENABLE_ROCWMMA}")"
    "-DTHEROCK_ENABLE_PROFILER=$(bool_on_off "${ENABLE_PROFILER}")"
    "-DTHEROCK_ENABLE_ROCPROFSYS=$(bool_on_off "${ENABLE_ROCPROFSYS}")"
    "-DTHEROCK_ENABLE_DC_TOOLS=$(bool_on_off "${ENABLE_DC_TOOLS}")"
    "-DBUILD_TESTING=$(bool_on_off "${ENABLE_BUILD_TESTING}")"
    "-DTHEROCK_MIOPEN_USE_COMPOSABLE_KERNEL=$(bool_on_off "${ENABLE_COMPOSABLE_KERNEL}")"
    "-DCMAKE_C_FLAGS="
    "-DCMAKE_CXX_FLAGS="
    "-DCMAKE_C_COMPILER:FILEPATH=${c_compiler}"
    "-DCMAKE_CXX_COMPILER:FILEPATH=${cxx_compiler}"
    "-DCMAKE_C_COMPILER_LAUNCHER=ccache"
    "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
  )
  if [[ -n "${linker}" ]]; then cmake_args+=("-DCMAKE_LINKER:FILEPATH=${linker}"); fi
  if [[ -x "${ar}" ]]; then cmake_args+=("-DCMAKE_AR:FILEPATH=${ar}"); fi
  if [[ -x "${ranlib}" ]]; then cmake_args+=("-DCMAKE_RANLIB:FILEPATH=${ranlib}"); fi
  if [[ -x "${nm}" ]]; then cmake_args+=("-DCMAKE_NM:FILEPATH=${nm}"); fi
  if [[ -n "${hip_compiler}" ]]; then cmake_args+=("-DCMAKE_HIP_COMPILER:FILEPATH=${hip_compiler}"); fi
  cmake_args+=("${EXTRA_CMAKE_ARGS[@]}")

  systemd-run --user --scope -p "MemoryHigh=${MEM_HIGH}" -p "MemoryMax=${MEM_MAX}" \
    bash -lc "cd \"${ROOT}\" && source \"${ROOT}/.venv/bin/activate\" && cmake -B \"${BUILD_DIR}\" -GNinja . ${cmake_args[*]}" 2>&1 | tee -a "${LOG_FILE}"

  echo "Configure complete. Next:" | tee -a "${LOG_FILE}"
  echo "  ./build_gfx1031.sh bootstrap --build-dir ${BUILD_DIR}" | tee -a "${LOG_FILE}"
  echo "  ./build_gfx1031.sh build --build-dir ${BUILD_DIR} [--detach]" | tee -a "${LOG_FILE}"
}

case "${cmd}" in
  configure)
    configure_top
    ;;
  configure-sub)
    if [[ ${#SUBPROJECTS[@]} -eq 0 ]]; then
      echo "configure-sub requires subproject names (e.g. roctracer rocPRIM rocprofiler-sdk)." >&2
      exit 2
    fi
    for t in "${SUBPROJECTS[@]}"; do
      run_cmd_array ninja -C "${BUILD_DIR}" "${t}+configure"
    done
    ;;
  bootstrap)
    echo "Bootstrapping ${#bootstrap_targets[@]} targets in ${BUILD_DIR}..." | tee -a "${LOG_FILE}"
    for t in "${bootstrap_targets[@]}"; do
      echo "==> ${t}" | tee -a "${LOG_FILE}"
      run_cmd_array ninja -C "${BUILD_DIR}" "${t}"
    done
    echo "Verifying expected bootstrap artifacts..." | tee -a "${LOG_FILE}"
    if ! verify_bootstrap; then
      echo "Bootstrap incomplete (missing artifacts). See ${LOG_FILE}." >&2
      exit 1
    fi
    echo "Bootstrap complete. Next: ./build_gfx1031.sh build --build-dir ${BUILD_DIR}" | tee -a "${LOG_FILE}"
    ;;
  build)
    if (( DETACH )) && [[ "${LOG_FILE}" == "${ROOT}/build.log" ]]; then
      LOG_FILE="${ROOT}/${BUILD_DIR}.log"
    fi
    run_cmd_array ninja -C "${BUILD_DIR}"
    ;;
  expunge)
    if [[ ${#SUBPROJECTS[@]} -eq 0 ]]; then
      echo "expunge requires subproject names (e.g. amd-llvm hip-clr rocBLAS rocRAND)." >&2
      exit 2
    fi
    for t in "${SUBPROJECTS[@]}"; do
      run_cmd_array ninja -C "${BUILD_DIR}" "${t}+expunge"
    done
    ;;
  rebuild)
    if [[ ${#SUBPROJECTS[@]} -eq 0 ]]; then
      echo "rebuild requires subproject names (e.g. amd-llvm hip-clr rocBLAS rocRAND)." >&2
      exit 2
    fi
    for t in "${SUBPROJECTS[@]}"; do
      run_cmd_array ninja -C "${BUILD_DIR}" "${t}+expunge"
      run_cmd_array ninja -C "${BUILD_DIR}" "${t}"
    done
    ;;
  rocprofiler-gcc)
    # Phase-2: rocprofiler-systems with GNU compilers (Dyninst requirement).
    build_dir="${ROOT}/build-rocprofiler-gcc"
    install_prefix="${ROOT}/install-rocprofiler-gcc"
    require_cmd gcc "install build-essential."
    require_cmd g++ "install build-essential."
    mkdir -p "${build_dir}"
    systemd-run --user --scope -p "MemoryHigh=${MEM_HIGH}" -p "MemoryMax=${MEM_MAX}" \
      bash -lc "cd \"${ROOT}\" && cmake -S . -B \"${build_dir}\" -GNinja \
        -DTHEROCK_ENABLE_ROCPROFSYS=ON \
        -DTHEROCK_DISABLE_GNU_CHECK=ON \
        -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_INSTALL_PREFIX=\"${install_prefix}\"" 2>&1 | tee -a "${LOG_FILE}"
    systemd-run --user --scope -p "MemoryHigh=${MEM_HIGH}" -p "MemoryMax=${MEM_MAX}" \
      bash -lc "cd \"${build_dir}\" && ninja && ninja install" 2>&1 | tee -a "${LOG_FILE}"
    echo "rocprofiler-systems installed to: ${install_prefix}" | tee -a "${LOG_FILE}"
    ;;
  *)
    echo "Unknown command: ${cmd}" >&2
    usage >&2
    exit 2
    ;;
esac

