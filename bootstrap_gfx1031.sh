#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE_DEFAULT="${ROOT}/build.log"
LOG_FILE="${LOG_FILE:-$LOG_FILE_DEFAULT}"
MEM_HIGH="${MEM_HIGH:-28G}"
MEM_MAX="${MEM_MAX:-31G}"
JOBS="${BOOTSTRAP_JOBS:-1}"
PRESERVE_LD_LIBRARY_PATH="${PRESERVE_LD_LIBRARY_PATH:-0}"

usage() {
  cat <<'EOF_USAGE'
Usage: bootstrap_gfx1031.sh [options]

Bootstraps third-party/sysdeps artifacts that are needed early so subsequent
subproject configures during the full build don't fail on missing *Config.cmake
or rocm_sysdeps shared libraries.

Prerequisite: run ./configure_gfx1031.sh first (creates build/build.ninja).

Options:
  -h, --help        Show this help

Environment overrides:
  MEM_HIGH / MEM_MAX     systemd-run memory limits (default 28G/31G)
  BOOTSTRAP_JOBS         ninja -j value (default 1)
  LOG_FILE               log path (default ./build.log)
  PRESERVE_LD_LIBRARY_PATH  append inherited LD_LIBRARY_PATH (default 0)
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "${ROOT}/.venv/bin/activate" ]]; then
  echo "Missing .venv; run ./configure_gfx1031.sh once (it auto-creates venv) or create it per README." >&2
  exit 1
fi
if [[ ! -f "${ROOT}/build/build.ninja" ]]; then
  echo "Missing build/build.ninja; run: ./configure_gfx1031.sh (or --clean) first." >&2
  exit 1
fi

if [[ -x "${ROOT}/.local/bin/ccache" ]]; then
  PATH="${ROOT}/.local/bin:${PATH}"
fi
if [[ -x "${ROOT}/build_tools/setup_ccache.py" ]]; then
  eval "$(python3 "${ROOT}/build_tools/setup_ccache.py" --init)"
fi
export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-include_file_ctime}"
if ! command -v ninja >/dev/null 2>&1; then
  echo "ninja not found; install it before bootstrapping." >&2
  exit 1
fi

compute_sysdeps_ld_library_path() {
  local -a sysdeps_libs=(
    "${ROOT}/build/dist/rocm/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/zstd/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/zstd/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/zstd/build/build/b"
    "${ROOT}/build/third-party/sysdeps/linux/zlib/build/dist/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/zlib/build/stage/lib/rocm_sysdeps/lib"
    "${ROOT}/build/third-party/sysdeps/linux/zlib/build/build/b"
  )
  local ldpath=""
  local p
  for p in "${sysdeps_libs[@]}"; do
    [[ -d "$p" ]] && ldpath="${ldpath:+$ldpath:}$p"
  done
  echo "${ldpath}"
}

run_cmd() {
  local cmd="$1"
  local ldpath
  ldpath="$(compute_sysdeps_ld_library_path)"
  local ld_export="export LD_LIBRARY_PATH=\"${ldpath}\""
  if [[ "${PRESERVE_LD_LIBRARY_PATH}" == "1" ]]; then
    ld_export="export LD_LIBRARY_PATH=\"${ldpath:+$ldpath:}\${LD_LIBRARY_PATH}\""
  fi
  systemd-run --user --scope -p "MemoryHigh=${MEM_HIGH}" -p "MemoryMax=${MEM_MAX}" \
    bash -lc "source \"${ROOT}/.venv/bin/activate\" && ${ld_export} && ${cmd}" 2>&1 | tee -a "${LOG_FILE}"
}

run_cmd_array() {
  local -a cmd=("$@")
  local escaped
  printf -v escaped '%q ' "${cmd[@]}"
  run_cmd "${escaped}"
}

bootstrap_targets=(
  # Base CMake tooling used by many subprojects via find_package(ROCmCMakeBuildTools).
  "rocm-cmake+dist"

  # Sysdeps used by host tools and grpc; provides ZLIBConfig.cmake and librocm_sysdeps_z*.so.
  "therock-zlib+dist"
  "therock-zstd+dist"
  "therock-numactl+dist"
  "therock-elfutils+dist"

  # Host BLAS is needed early by SuiteSparse.
  "therock-host-blas+dist"

  # Common CMake config deps frequently used by downstream projects.
  "therock-fmt+dist"
  "therock-spdlog+dist"
  "therock-yaml-cpp+dist"
  "therock-nlohmann-json+dist"
  "therock-eigen+dist"
  "therock-FunctionalPlus+dist"
)

echo "Bootstrapping ${#bootstrap_targets[@]} targets (ninja -j${JOBS})..." | tee -a "${LOG_FILE}"
for t in "${bootstrap_targets[@]}"; do
  echo "==> ${t}" | tee -a "${LOG_FILE}"
  run_cmd_array ninja -C build -j "${JOBS}" "${t}"
done

echo "Verifying expected stage/dist artifacts..." | tee -a "${LOG_FILE}"

expect_paths=(
  "${ROOT}/build/base/rocm-cmake/dist/share/rocmcmakebuildtools/cmake"
  "${ROOT}/build/base/rocm-cmake/dist/share/rocm/cmake"
  "${ROOT}/build/third-party/sysdeps/linux/zlib/build/dist/lib/rocm_sysdeps/lib/cmake/ZLIB/zlib-config.cmake"
  "${ROOT}/build/third-party/sysdeps/linux/zlib/build/dist/lib/rocm_sysdeps/lib/librocm_sysdeps_z.so.1"
  "${ROOT}/build/third-party/sysdeps/linux/zstd/build/dist/lib/rocm_sysdeps/lib/cmake/zstd/zstdConfig.cmake"
  "${ROOT}/build/third-party/sysdeps/linux/zstd/build/dist/lib/rocm_sysdeps/lib/librocm_sysdeps_zstd.so.1"
  "${ROOT}/build/third-party/sysdeps/linux/numactl/build/dist/lib/rocm_sysdeps/lib/cmake/NUMA/numa-config.cmake"
  "${ROOT}/build/third-party/sysdeps/linux/elfutils/build/dist/lib/rocm_sysdeps/lib/cmake/LibElf/libelf-config.cmake"
  "${ROOT}/build/third-party/host-blas/dist/lib/host-math/lib/cmake/OpenBLAS/OpenBLASConfig.cmake"
)

missing=0
for p in "${expect_paths[@]}"; do
  if [[ ! -e "${p}" ]]; then
    echo "MISSING: ${p}" | tee -a "${LOG_FILE}"
    missing=1
  else
    echo "OK: ${p}" | tee -a "${LOG_FILE}"
  fi
done

if (( missing )); then
  echo "Bootstrap incomplete (missing artifacts). See ${LOG_FILE}." >&2
  exit 1
fi

echo "Bootstrap complete. Next: ./build_gfx1031.sh --skip-configure" | tee -a "${LOG_FILE}"
