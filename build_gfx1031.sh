#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-${ROOT}/build.log}"
BUILD_DIR="${BUILD_DIR:-build}"
MEM_HIGH="${MEM_HIGH:-28G}"
MEM_MAX="${MEM_MAX:-31G}"
PRESERVE_LD_LIBRARY_PATH="${PRESERVE_LD_LIBRARY_PATH:-0}"
DETACH=0
JOBS="${JOBS:-}"
WAIT_LOCK=0

usage() {
  cat <<'EOF_USAGE'
Usage: build_gfx1031.sh <command> [options] [subprojects...]

Commands:
  bootstrap         Build early sysdeps (+dist) and verify outputs
  configure         (Re)configure specific subprojects only
  build             Build the full superbuild (ninja -C <builddir>)
  rebuild           Expunge + rebuild specific subprojects
  expunge           Expunge specific subprojects (no rebuild)
  rocprofiler-gcc   Phase-2: build rocprofiler-systems with GCC in a separate build dir

Options:
  --stage1          Use BUILD_DIR=build-stage1
  --stage2          Use BUILD_DIR=build-stage2
  --build-dir <dir> Override build directory (default: build)
  --detach          Run build in background via systemd-run (build only)
  --wait            Wait for an in-progress build lock
  -j, --jobs <n>    Ninja parallelism (default: inherit ninja default)
  -h, --help        Show this help

Environment:
  LOG_FILE                log path (default ./build.log)
  BUILD_DIR               build directory name (default build)
  MEM_HIGH / MEM_MAX      systemd-run memory limits (default 28G/31G)
  PRESERVE_LD_LIBRARY_PATH  append inherited LD_LIBRARY_PATH (default 0)
  JOBS                    ninja -j value (optional)
EOF_USAGE
}

cmd="${1:-}"
if [[ -z "${cmd}" || "${cmd}" == "-h" || "${cmd}" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

SUBPROJECTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage1) BUILD_DIR="build-stage1"; shift ;;
    --stage2) BUILD_DIR="build-stage2"; shift ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --detach) DETACH=1; shift ;;
    --wait) WAIT_LOCK=1; shift ;;
    -j|--jobs) JOBS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; SUBPROJECTS+=("$@"); break ;;
    *) SUBPROJECTS+=("$1"); shift ;;
  esac
done

LOCK_FILE="${ROOT}/${BUILD_DIR}/.therock_build.lock"
LOCK_FD=200
mkdir -p "${ROOT}/${BUILD_DIR}"
if (( WAIT_LOCK )); then
  exec {LOCK_FD}>"${LOCK_FILE}"
  flock "${LOCK_FD}"
else
  exec {LOCK_FD}>"${LOCK_FILE}"
  if ! flock -n "${LOCK_FD}"; then
    echo "Another build is already running for BUILD_DIR='${BUILD_DIR}' (lock: ${LOCK_FILE})." >&2
    echo "Use: ./build_gfx1031.sh <command> --build-dir ${BUILD_DIR} --wait" >&2
    exit 3
  fi
fi

if [[ ! -f "${ROOT}/.venv/bin/activate" ]]; then
  echo "Missing .venv; run ./configure_gfx1031.sh first (it auto-creates venv) or create it per README." >&2
  exit 1
fi
if [[ ! -f "${ROOT}/${BUILD_DIR}/build.ninja" ]]; then
  echo "Missing ${BUILD_DIR}/build.ninja; run ./configure_gfx1031.sh first." >&2
  exit 1
fi

if [[ -x "${ROOT}/.local/bin/ccache" ]]; then
  PATH="${ROOT}/.local/bin:${PATH}"
fi
if [[ -x "${ROOT}/build_tools/setup_ccache.py" ]]; then
  eval "$(python3 "${ROOT}/build_tools/setup_ccache.py" --init)"
fi
export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-include_file_ctime}"

if ! command -v ccache >/dev/null 2>&1; then
  echo "ccache not found; install it or run setup_ccache.py as in README." >&2
  exit 1
fi
if ! command -v ninja >/dev/null 2>&1; then
  echo "ninja not found; install it before building." >&2
  exit 1
fi

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
    local unit="therock-gfx1031-${BUILD_DIR}-build"
    systemd-run --user --no-block --quiet --collect --unit "${unit}" --property=Restart=no \
      --property="MemoryHigh=${MEM_HIGH}" --property="MemoryMax=${MEM_MAX}" \
      --property=MemoryAccounting=yes --property=CPUAccounting=yes \
      bash -lc "cd \"${ROOT}\" && source \"${ROOT}/.venv/bin/activate\" && ${ld_export} && ${cmdline} ${jobs_arg} >> \"${LOG_FILE}\" 2>&1"
    echo "Build started as user unit: ${unit}.service (logs: ${LOG_FILE})"
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

case "${cmd}" in
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
  configure)
    if [[ ${#SUBPROJECTS[@]} -eq 0 ]]; then
      echo "configure requires subproject names (e.g. amd-llvm hip-clr roctracer rocPRIM rocprofiler-sdk)." >&2
      exit 2
    fi
    for t in "${SUBPROJECTS[@]}"; do
      run_cmd_array ninja -C "${BUILD_DIR}" "${t}+configure"
    done
    ;;
  build)
    if (( DETACH )) && [[ "${LOG_FILE}" == "${ROOT}/build.log" ]]; then
      # Default to distinct log files per build dir when detached.
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
    if ! command -v gcc >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
      echo "gcc/g++ not found; install build-essential." >&2
      exit 1
    fi
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
