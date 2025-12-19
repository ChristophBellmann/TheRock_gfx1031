#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE_DEFAULT="${ROOT}/bootstrap.log"
LOG_FILE="${LOG_FILE:-$LOG_FILE_DEFAULT}"
MEM_HIGH="${MEM_HIGH:-28G}"
MEM_MAX="${MEM_MAX:-31G}"
JOBS="${BOOTSTRAP_JOBS:-1}"

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
  LOG_FILE               log path (default ./bootstrap.log)
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
if ! command -v ninja >/dev/null 2>&1; then
  echo "ninja not found; install it before bootstrapping." >&2
  exit 1
fi

if [[ -f "${LOG_FILE}" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  mv "${LOG_FILE}" "${LOG_FILE}.bak-${ts}"
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
  systemd-run --user --scope -p "MemoryHigh=${MEM_HIGH}" -p "MemoryMax=${MEM_MAX}" \
    bash -lc "source \"${ROOT}/.venv/bin/activate\" && export LD_LIBRARY_PATH=\"${ldpath:+$ldpath:}\${LD_LIBRARY_PATH}\" && ${cmd}" 2>&1 | tee -a "${LOG_FILE}"
}

run_cmd_array() {
  local -a cmd=("$@")
  local escaped
  printf -v escaped '%q ' "${cmd[@]}"
  run_cmd "${escaped}"
}

bootstrap_targets=(
  # Base CMake tooling used by many subprojects via find_package(ROCmCMakeBuildTools).
  "rocm-cmake+stage"

  # Sysdeps used by host tools and grpc; provides ZLIBConfig.cmake and librocm_sysdeps_z*.so.
  "therock-zlib+stage"
  "therock-zstd+stage"

  # Host BLAS is needed early by SuiteSparse.
  "therock-host-blas+stage"

  # Common CMake config deps frequently used by downstream projects.
  "therock-fmt+stage"
  "therock-spdlog+stage"
  "therock-yaml-cpp+stage"
  "therock-nlohmann-json+stage"
  "therock-eigen+stage"
  "therock-FunctionalPlus+stage"
)

echo "Bootstrapping ${#bootstrap_targets[@]} targets (ninja -j${JOBS})..." | tee -a "${LOG_FILE}"
for t in "${bootstrap_targets[@]}"; do
  echo "==> ${t}" | tee -a "${LOG_FILE}"
  run_cmd_array ninja -C build -j "${JOBS}" "${t}"
done

echo "Verifying expected stage/dist artifacts..." | tee -a "${LOG_FILE}"

expect_paths=(
  "${ROOT}/build/base/rocm-cmake/stage/share/rocmcmakebuildtools/cmake"
  "${ROOT}/build/third-party/sysdeps/linux/zlib/build/stage/lib/rocm_sysdeps/lib/cmake/ZLIB"
  "${ROOT}/build/third-party/sysdeps/linux/zlib/build/stage/lib/rocm_sysdeps/lib/librocm_sysdeps_z.so.1"
  "${ROOT}/build/third-party/sysdeps/linux/zstd/build/stage/lib/rocm_sysdeps/lib/librocm_sysdeps_zstd.so.1"
  "${ROOT}/build/third-party/host-blas/stage/lib/host-math/lib/cmake/OpenBLAS"
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

