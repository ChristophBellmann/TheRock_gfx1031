#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_ENABLED=0
LOG_FILE_DEFAULT="${ROOT}/test_gfx1031.log"
LOG_FILE="${LOG_FILE_DEFAULT}"
MODE="quick"
RUN_SANITY=1
# Default behavior is *build validation* (sanity + consistency). Benchmarks are
# opt-in because they can be slow and depend on installed bench binaries.
RUN_BENCH=0
RUN_MIOPEN=0
RUN_MIOPEN_SMOKE=0
BUILD_DIR="${BUILD_DIR:-}"
RUN_CONSISTENCY=0
CONSISTENCY_DEEP=0
EXPECT_STAGE="" # "", "stage1", "stage2"
STAGE1_BUILD_DIR="${STAGE1_BUILD_DIR:-build-stage1}"
ORIG_ARGS=("$@")
USER_SELECTED_BUILD_DIR=0
BENCH_LITE=0
BENCH_MENU=0
if [[ -n "${BUILD_DIR}" ]]; then
  USER_SELECTED_BUILD_DIR=1
fi

# Output styling (TTY only).
IS_TTY=0
if [[ -t 1 ]]; then
  IS_TTY=1
fi

COLOR_ENABLED="${IS_TTY}"
if [[ -n "${NO_COLOR:-}" ]]; then
  COLOR_ENABLED=0
fi
# If logging to a file, default to plain output to keep logs readable.
if (( LOG_ENABLED )) && [[ -z "${FORCE_COLOR:-}" ]]; then
  COLOR_ENABLED=0
fi

if (( COLOR_ENABLED )); then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
fi

usage() {
  cat <<'EOF_USAGE'
Usage: test_gfx1031.sh [options]

Options:
  --quick        Select quick benchmark sizes (default mode)
  --full         Select longer benchmark sizes (bigger sizes / more iters)
  --bench        Run performance benchmarks (in addition to sanity)
  --bench-lite   Run only the lightweight BLAS GEMM benchmarks (rocBLAS + hipBLAS)
  --bench-menu   Interactive bench menu (select 1-9; 0=all; q=quit)
  --log [file]   Enable logging to file (default: test_gfx1031.log)
  --no-bench     Skip performance benchmarks (default)
  --bench-only   Run benchmarks only (no sanity)
  --miopen       Check MIOpen + composable_kernel artifacts (and MIOpenDriver --version if present)
  --miopen-smoke Run a tiny MIOpenDriver smoke test (may take time on first run)
  --consistency  Run build/toolchain consistency checks
  --consistency-only
                Run consistency checks only
  --deep         Deep consistency checks (scan more files)
  --expect-stage1
                Expect Stage-1 (system clang allowed)
  --expect-stage2
                Expect Stage-2 (no system clang/llvm-18 fallback)
  --stage1       Use BUILD_DIR=build-stage1
  --stage2       Use BUILD_DIR=build-stage2
  --build-dir <dir>
                Override build directory (default: build)
  -h, --help     Show this help

Environment overrides:
  BENCH_SIZE       override GEMM size (default 2048 quick, 4096 full)
  BENCH_ITERS      override iterations (default 10 quick, 20 full)
  TEST_LOG         override log file (only used if --log is set)
  BUILD_DIR        build directory name (auto: if multiple exist, tests build-stage2, build, build-stage1)
  STAGE1_BUILD_DIR Stage-1 build dir for Stage-2 expectations (default: build-stage1)
EOF_USAGE
}

choose_default_build_dir() {
  # If user set BUILD_DIR explicitly (env or --build-dir), keep it.
  if [[ -n "${BUILD_DIR:-}" ]]; then
    return 0
  fi
  # Prefer Stage-2 if present (most useful for users).
  if [[ -d "${ROOT}/build-stage2/dist/rocm" ]]; then
    BUILD_DIR="build-stage2"
    return 0
  fi
  # Fall back to a default in-tree build dir.
  if [[ -d "${ROOT}/build/dist/rocm" ]]; then
    BUILD_DIR="build"
    return 0
  fi
  # Finally Stage-1 toolchain dist (toolchain-only; limited runtime tools).
  if [[ -d "${ROOT}/build-stage1/dist/rocm" ]]; then
    BUILD_DIR="build-stage1"
    return 0
  fi
  # As a last resort, keep the traditional "build" name so error messages are stable.
  BUILD_DIR="build"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)
      MODE="quick"
      shift
      ;;
    --full)
      MODE="full"
      shift
      ;;
    --bench)
      RUN_BENCH=1
      shift
      ;;
    --bench-lite)
      RUN_BENCH=1
      BENCH_LITE=1
      shift
      ;;
    --bench-menu)
      RUN_SANITY=0
      RUN_BENCH=1
      BENCH_MENU=1
      shift
      ;;
    --log)
      LOG_ENABLED=1
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        LOG_FILE="$2"
        shift 2
      else
        shift
      fi
      ;;
    --no-bench)
      RUN_BENCH=0
      shift
      ;;
    --bench-only)
      RUN_SANITY=0
      RUN_BENCH=1
      shift
      ;;
    --miopen)
      RUN_MIOPEN=1
      shift
      ;;
    --miopen-smoke)
      RUN_MIOPEN=1
      RUN_MIOPEN_SMOKE=1
      shift
      ;;
    --consistency)
      RUN_CONSISTENCY=1
      shift
      ;;
    --consistency-only)
      RUN_SANITY=0
      RUN_BENCH=0
      RUN_CONSISTENCY=1
      shift
      ;;
    --deep)
      CONSISTENCY_DEEP=1
      shift
      ;;
    --expect-stage1)
      EXPECT_STAGE="stage1"
      shift
      ;;
    --expect-stage2)
      EXPECT_STAGE="stage2"
      shift
      ;;
    --stage1)
      BUILD_DIR="build-stage1"
      USER_SELECTED_BUILD_DIR=1
      shift
      ;;
    --stage2)
      BUILD_DIR="build-stage2"
      USER_SELECTED_BUILD_DIR=1
      shift
      ;;
    --build-dir)
      BUILD_DIR="${2:-}"
      USER_SELECTED_BUILD_DIR=1
      shift 2
      ;;
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

# Default UX: if invoked without args in an interactive terminal, open the bench menu.
if (( ${#ORIG_ARGS[@]} == 0 )) && [[ -t 0 ]]; then
  RUN_SANITY=0
  RUN_BENCH=1
  BENCH_MENU=1
fi

# If no build dir was specified, and we have multiple in-tree dist roots,
# run the same tests for each build dir automatically (stage2/build/stage1).
if [[ -z "${TEST_GFX1031_SINGLE:-}" && ${USER_SELECTED_BUILD_DIR} -eq 0 ]]; then
  # If the user sets an explicit expectation, interpret it as a selection.
  if [[ "${EXPECT_STAGE}" == "stage2" ]]; then
    BUILD_DIR="build-stage2"
    USER_SELECTED_BUILD_DIR=1
  elif [[ "${EXPECT_STAGE}" == "stage1" ]]; then
    BUILD_DIR="build-stage1"
    USER_SELECTED_BUILD_DIR=1
  else
    # For benchmarks, default to Stage-2 if available (Stage-1 is typically
    # toolchain-only and does not ship rocblas-bench/hipblas-bench).
    if (( RUN_BENCH )) && [[ -d "${ROOT}/build-stage2/dist/rocm" ]]; then
      BUILD_DIR="build-stage2"
      USER_SELECTED_BUILD_DIR=1
    fi

    if (( USER_SELECTED_BUILD_DIR == 0 )); then
      build_dirs=()
      for d in build-stage2 build build-stage1; do
        if [[ -d "${ROOT}/${d}/dist/rocm" ]]; then
          build_dirs+=("${d}")
        fi
      done
      if (( ${#build_dirs[@]} > 1 )); then
        overall_rc=0
        for d in "${build_dirs[@]}"; do
          echo "==== build dir: ${d} ===="
        if (( LOG_ENABLED )); then
          base_log="${LOG_FILE_DEFAULT}"
          if [[ "${base_log}" == *.log ]]; then
            this_log="${base_log%.log}.${d}.log"
          else
            this_log="${base_log}.${d}.log"
          fi
          TEST_GFX1031_SINGLE=1 BUILD_DIR="${d}" "${ROOT}/test_gfx1031.sh" --log "${this_log}" "${ORIG_ARGS[@]}" || overall_rc=1
        else
          TEST_GFX1031_SINGLE=1 BUILD_DIR="${d}" "${ROOT}/test_gfx1031.sh" "${ORIG_ARGS[@]}" || overall_rc=1
        fi
      done
      exit "${overall_rc}"
    fi
  fi
fi
fi

choose_default_build_dir

if (( LOG_ENABLED )); then
  if [[ -n "${TEST_LOG:-}" ]]; then
    LOG_FILE="${TEST_LOG}"
  fi
else
  # Default: no log file is created. We still pipe through a log sink for
  # simplicity (tee -a /dev/null).
  LOG_FILE="/dev/null"
fi

if [[ -f "${ROOT}/.venv/bin/activate" ]] && [[ -z "${VIRTUAL_ENV:-}" ]]; then
  # Activate venv for helper tools if present.
  # shellcheck disable=SC1091
  source "${ROOT}/.venv/bin/activate"
fi

if (( LOG_ENABLED )); then
  if [[ -f "${LOG_FILE}" ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    mv "${LOG_FILE}" "${LOG_FILE}.bak-${ts}"
  fi
  touch "${LOG_FILE}"
fi

ROCM_PATH_DEFAULT="${ROOT}/${BUILD_DIR}/dist/rocm"
ROCM_PATH="${ROCM_PATH:-${ROCM_PATH_DEFAULT}}"
HAVE_ROCM_ENV=0
if [[ -d "${ROCM_PATH}" ]]; then
  HAVE_ROCM_ENV=1
  export ROCM_PATH
  export HIP_PATH="${HIP_PATH:-$ROCM_PATH}"
  export HSA_PATH="${HSA_PATH:-$ROCM_PATH}"
  export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:${PATH:-}"
  # Include host BLAS in-tree prefix for benchmarks (lib/host-math/lib).
  export LD_LIBRARY_PATH="$ROCM_PATH/lib:$ROCM_PATH/lib64:$ROCM_PATH/lib/host-math/lib:$ROCM_PATH/lib/rocm_sysdeps/lib:$ROCM_PATH/llvm/lib:${LD_LIBRARY_PATH:-}"
  # Some packaging flows may drop OpenBLAS SONAME symlinks. For benchmark runs,
  # provide a local fallback without mutating the in-tree dist.
  _host_blas_lib="$ROCM_PATH/lib/host-math/lib"
  if [[ -d "${_host_blas_lib}" ]] && [[ ! -e "${_host_blas_lib}/librocm-openblas.so.0" ]] && [[ -e "${_host_blas_lib}/librocm-openblas.so.0.3" ]]; then
    _tmp_blas="$(mktemp -d)"
    ln -s "${_host_blas_lib}/librocm-openblas.so.0.3" "${_tmp_blas}/librocm-openblas.so.0"
    ln -s "${_host_blas_lib}/librocm-openblas.so.0.3" "${_tmp_blas}/librocm-openblas.so"
    export LD_LIBRARY_PATH="${_tmp_blas}:${LD_LIBRARY_PATH}"
  fi
  if [[ -z "${HIP_DEVICE_LIB_PATH:-}" ]]; then
    if [[ -d "$ROCM_PATH/lib/llvm/amdgcn/bitcode" ]]; then
      export HIP_DEVICE_LIB_PATH="$ROCM_PATH/lib/llvm/amdgcn/bitcode"
    else
      export HIP_DEVICE_LIB_PATH="$ROCM_PATH/amdgcn/bitcode"
    fi
  fi
  echo "${C_GREEN}Activated in-tree ROCm:${C_RESET} ${ROCM_PATH}" | tee -a "${LOG_FILE}"
else
  if (( RUN_SANITY )) || (( RUN_BENCH )); then
    echo "ROCM_PATH not found: ${ROCM_PATH}" | tee -a "${LOG_FILE}" >&2
    echo "Build first (expected default: ${ROCM_PATH_DEFAULT})." | tee -a "${LOG_FILE}" >&2
    exit 1
  fi
  echo "ROCM_PATH not found: ${ROCM_PATH} (OK for --consistency-only; skipping runtime/HIP checks)" | tee -a "${LOG_FILE}"
fi

RESULT_LABELS=()
RESULT_STATUS=()
RESULT_TIME=()
RESULT_METRIC=()

add_result() {
  RESULT_LABELS+=("$1")
  RESULT_STATUS+=("$2")
  RESULT_TIME+=("$3")
  RESULT_METRIC+=("$4")
}

miopen_find_driver() {
  if command -v MIOpenDriver >/dev/null 2>&1; then
    echo "MIOpenDriver"
    return 0
  fi
  if command -v miopen-driver >/dev/null 2>&1; then
    echo "miopen-driver"
    return 0
  fi
  return 1
}

check_miopen_artifacts() {
  local label_prefix="$1"
  local start=$SECONDS
  local ok=0

  # MIOpen library presence
  if [[ -e "${ROCM_PATH}/lib/libMIOpen.so" || -n "$(ls -1 "${ROCM_PATH}/lib/libMIOpen.so"* 2>/dev/null | head -n 1)" ]]; then
    add_result "${label_prefix} miopen library" "OK" "0s" "libMIOpen found"
    ok=1
  elif [[ -e "${ROCM_PATH}/lib64/libMIOpen.so" || -n "$(ls -1 "${ROCM_PATH}/lib64/libMIOpen.so"* 2>/dev/null | head -n 1)" ]]; then
    add_result "${label_prefix} miopen library" "OK" "0s" "libMIOpen found (lib64)"
    ok=1
  else
    add_result "${label_prefix} miopen library" "SKIP" "0s" "libMIOpen not found under ${ROCM_PATH}/lib{,64} (may be disabled)"
  fi

  # composable_kernel headers (may or may not be installed depending on packaging)
  if [[ -d "${ROCM_PATH}/include/ck" || -d "${ROCM_PATH}/include/composable_kernel" ]]; then
    add_result "${label_prefix} ck headers" "OK" "0s" "headers present"
  else
    add_result "${label_prefix} ck headers" "SKIP" "0s" "not found under ${ROCM_PATH}/include (may be ok)"
  fi

  local elapsed=$((SECONDS - start))
  if (( ok )); then
    add_result "${label_prefix} miopen artifacts" "OK" "${elapsed}s" ""
  else
    add_result "${label_prefix} miopen artifacts" "SKIP" "${elapsed}s" "MIOpen not installed in this dist"
  fi
}

run_miopen_checks() {
  local label_prefix="$1"
  if (( HAVE_ROCM_ENV == 0 )); then
    add_result "${label_prefix} miopen" "FAIL" "0s" "ROCM_PATH missing"
    return 1
  fi
  check_miopen_artifacts "${label_prefix}" || true

  local drv
  if drv="$(miopen_find_driver)"; then
    run_timed "${label_prefix} driver --version" "<5s" "${drv}" --version || true
    if (( RUN_MIOPEN_SMOKE )); then
      # Very small conv; kernel compilation may still take time on first run.
      # Use conservative sizes to keep it quick if cache is warm.
      run_timed "${label_prefix} conv (smoke)" "30-180s" "${drv}" conv -n 1 -c 1 -H 8 -W 8 -k 1 -y 3 -x 3 -p 1 -q 1 || true
    else
      add_result "${label_prefix} conv (smoke)" "SKIP" "0s" "use --miopen-smoke to run"
    fi
  else
    add_result "${label_prefix} driver --version" "SKIP" "0s" "MIOpenDriver/miopen-driver not in PATH"
    add_result "${label_prefix} conv (smoke)" "SKIP" "0s" "MIOpenDriver/miopen-driver not in PATH"
  fi
}

detect_expect_stage() {
  if [[ -n "${EXPECT_STAGE}" ]]; then
    return 0
  fi
  case "${BUILD_DIR}" in
    *stage2*) EXPECT_STAGE="stage2" ;;
    *stage1*) EXPECT_STAGE="stage1" ;;
    *) EXPECT_STAGE="" ;;
  esac
}

check_cmd_available() {
  local label="$1"
  local exe="$2"
  if command -v "${exe}" >/dev/null 2>&1; then
    add_result "${label}" "OK" "0s" "$(command -v "${exe}")"
    return 0
  fi
  add_result "${label}" "FAIL" "0s" "missing: ${exe}"
  return 1
}

check_no_matches_in_files() {
  local label="$1"
  local expected="$2"
  local pattern="$3"
  shift 3
  local -a files=("$@")
  local tmp
  tmp="$(mktemp)"
  local start=$SECONDS
  set +e
  if command -v rg >/dev/null 2>&1; then
    rg -nH "${pattern}" "${files[@]}" >"${tmp}" 2>/dev/null
  else
    grep -nH -E "${pattern}" "${files[@]}" >"${tmp}" 2>/dev/null
  fi
  local rc=$?
  set -e
  local elapsed=$((SECONDS - start))
  if [[ ${rc} -eq 0 ]]; then
    local sample
    sample="$(head -n 3 "${tmp}" | tr '\n' ' ' | sed 's/[[:space:]]\\+/ /g')"
    add_result "${label}" "FAIL" "${elapsed}s" "matched (${expected}): ${sample}"
    rm -f "${tmp}"
    return 1
  fi
  add_result "${label}" "OK" "${elapsed}s" "${expected}"
  rm -f "${tmp}"
  return 0
}

check_no_opt_rocm_in_caches() {
  local label="$1"
  local expected="$2"
  local filter="${3:-}"
  local start=$SECONDS
  local tmp
  tmp="$(mktemp)"
  set +e
  # Ignore CMakeCache comment lines (which can mention "/opt/rocm" as the
  # upstream default in help text, even when the actual cache variables are
  # correctly pointing at in-tree prefixes).
  find "${ROOT}/${BUILD_DIR}" -name CMakeCache.txt -print0 2>/dev/null \
    | xargs -0 rg -nH "/opt/rocm" 2>/dev/null \
    | rg -v ":[0-9]+://" 2>/dev/null \
    >"${tmp}"
  local rc=$?
  set -e
  if [[ -n "${filter}" && -s "${tmp}" ]]; then
    # Remove known-benign matches (e.g. internal externalproject caches) for the light check.
    rg -v "${filter}" "${tmp}" > "${tmp}.filtered" 2>/dev/null || true
    mv -f "${tmp}.filtered" "${tmp}"
    if [[ ! -s "${tmp}" ]]; then
      rc=1
    else
      rc=0
    fi
  fi
  local elapsed=$((SECONDS - start))
  if [[ ${rc} -eq 0 ]]; then
    add_result "${label}" "FAIL" "${elapsed}s" "$(head -n 3 "${tmp}" | tr '\n' ' ' | sed 's/[[:space:]]\\+/ /g')"
    rm -f "${tmp}"
    return 1
  fi
  add_result "${label}" "OK" "${elapsed}s" "${expected}"
  rm -f "${tmp}"
  return 0
}

check_toolchain_paths() {
  local stage_expect="$1"
  local label_prefix="$2"

  # Top-level cache compilers
  local cache="${ROOT}/${BUILD_DIR}/CMakeCache.txt"
  if [[ -f "${cache}" ]]; then
    local cxx
    cxx="$(rg -n "^CMAKE_CXX_COMPILER:[A-Z_]+=" "${cache}" | head -n 1 | cut -d= -f2- || true)"
    if [[ -n "${cxx}" ]]; then
      if [[ "${stage_expect}" == "stage2" ]]; then
        case "${cxx}" in
          *"${ROOT}/${STAGE1_BUILD_DIR}/"*)
            add_result "${label_prefix} top-level compiler" "OK" "0s" "${cxx}"
            ;;
          *)
            add_result "${label_prefix} top-level compiler" "FAIL" "0s" "expected Stage-1 toolchain clang++ from ${STAGE1_BUILD_DIR}, got: ${cxx}"
            ;;
        esac
      else
        add_result "${label_prefix} top-level compiler" "OK" "0s" "${cxx}"
      fi
    else
      add_result "${label_prefix} top-level compiler" "SKIP" "0s" "no CMAKE_CXX_COMPILER in cache"
    fi
  else
    add_result "${label_prefix} top-level compiler" "SKIP" "0s" "missing ${BUILD_DIR}/CMakeCache.txt"
  fi

  # Scan toolchain files for system clang fallbacks (Stage-2 should not contain these).
  if [[ "${stage_expect}" == "stage2" ]]; then
    local maxdepth_args=()
    if (( CONSISTENCY_DEEP == 0 )); then
      maxdepth_args=(-maxdepth 6)
    fi
    local tmp
    tmp="$(mktemp)"
    set +e
    find "${ROOT}/${BUILD_DIR}" "${maxdepth_args[@]}" -name "*_toolchain.cmake" -print0 2>/dev/null | \
      xargs -0 rg -nH "/usr/lib/llvm-18/|/usr/bin/clang\\+\\+|/usr/bin/clang(\\s|$)" 2>/dev/null >"${tmp}"
    local rc=$?
    set -e
    if [[ ${rc} -eq 0 ]]; then
      add_result "${label_prefix} toolchain scan" "FAIL" "0s" "$(head -n 3 "${tmp}" | tr '\n' ' ' | sed 's/[[:space:]]\\+/ /g')"
      rm -f "${tmp}"
      return 1
    fi
    add_result "${label_prefix} toolchain scan" "OK" "0s" "no system clang paths found"
    rm -f "${tmp}"
  else
    add_result "${label_prefix} toolchain scan" "SKIP" "0s" "stage1/system clang allowed"
  fi

  # compile_commands.json scan (if present)
  local cc_file=""
  if [[ -f "${ROOT}/${BUILD_DIR}/compile_commands.json" ]]; then
    cc_file="${ROOT}/${BUILD_DIR}/compile_commands.json"
  elif [[ -f "${ROOT}/compile_commands.json" ]]; then
    cc_file="${ROOT}/compile_commands.json"
  fi
  if [[ -n "${cc_file}" ]]; then
    if [[ "${stage_expect}" == "stage2" ]]; then
      check_no_matches_in_files "${label_prefix} compile_commands" "no system clang in ${cc_file}" "/usr/lib/llvm-18/|/usr/bin/clang\\+\\+" "${cc_file}" || true
    else
      add_result "${label_prefix} compile_commands" "SKIP" "0s" "stage1/system clang allowed (${cc_file})"
    fi
  else
    add_result "${label_prefix} compile_commands" "SKIP" "0s" "no compile_commands.json found"
  fi
}

check_hip_device_libs() {
  local label_prefix="$1"
  if [[ ! -d "${HIP_DEVICE_LIB_PATH}" ]]; then
    add_result "${label_prefix} hip device libs" "FAIL" "0s" "HIP_DEVICE_LIB_PATH not found: ${HIP_DEVICE_LIB_PATH}"
    return 1
  fi
  if [[ -f "${HIP_DEVICE_LIB_PATH}/oclc_isa_version_1031.bc" ]]; then
    add_result "${label_prefix} hip device libs" "OK" "0s" "found oclc_isa_version_1031.bc"
  else
    add_result "${label_prefix} hip device libs" "FAIL" "0s" "missing oclc_isa_version_1031.bc under ${HIP_DEVICE_LIB_PATH}"
  fi

  if command -v hipcc >/dev/null 2>&1 && [[ -f "${ROOT}/test_hip.cpp" ]]; then
    local tmp
    tmp="$(mktemp)"
    set +e
    hipcc -v --offload-arch=gfx1031 "${ROOT}/test_hip.cpp" -o "${tmp}.out" 2>"${tmp}"
    local rc=$?
    set -e
    if [[ ${rc} -ne 0 ]]; then
      add_result "${label_prefix} hipcc -v" "FAIL" "0s" "hipcc failed (rc=${rc})"
      rm -f "${tmp}" "${tmp}.out" 2>/dev/null || true
      return 1
    fi
    if rg -q "gfx1031|oclc_isa_version_1031|amdgcn/bitcode" "${tmp}"; then
      add_result "${label_prefix} hipcc -v" "OK" "0s" "saw gfx1031/device-lib path in hipcc -v"
    else
      add_result "${label_prefix} hipcc -v" "FAIL" "0s" "no gfx1031/device-lib hints in hipcc -v"
    fi
    rm -f "${tmp}" "${tmp}.out" 2>/dev/null || true
  else
    add_result "${label_prefix} hipcc -v" "SKIP" "0s" "hipcc or test_hip.cpp missing"
  fi
}

check_runtime_linkage() {
  local label_prefix="$1"
  local -a bins=(rocminfo hipinfo rocblas-bench hipblas-bench)
  local b
  for b in "${bins[@]}"; do
    if ! command -v "${b}" >/dev/null 2>&1; then
      add_result "${label_prefix} ldd ${b}" "SKIP" "0s" "not in PATH"
      continue
    fi
    local exe
    exe="$(command -v "${b}")"
    local tmp
    tmp="$(mktemp)"
    set +e
    ldd "${exe}" 2>/dev/null | rg -n "/opt/rocm" >"${tmp}"
    local rc=$?
    set -e
    if [[ ${rc} -eq 0 ]]; then
      add_result "${label_prefix} ldd ${b}" "FAIL" "0s" "$(head -n 2 "${tmp}" | tr '\n' ' ' | sed 's/[[:space:]]\\+/ /g')"
      rm -f "${tmp}"
      continue
    fi
    add_result "${label_prefix} ldd ${b}" "OK" "0s" "no /opt/rocm deps"
    rm -f "${tmp}"
  done
}

extract_gflops() {
  local file="$1"
  local gflops
  # rocblas-bench / hipblas-bench CSV format:
  # header contains rocblas-Gflops or hipblas-Gflops and data row is comma-separated.
  gflops=$(awk -F',' '
    BEGIN { col=0 }
    /(^|,)rocblas-Gflops(,|$)/ || /(^|,)hipblas-Gflops(,|$)/ {
      for(i=1;i<=NF;i++) {
        if($i ~ /rocblas-Gflops/ || $i ~ /hipblas-Gflops/) { col=i; break }
      }
      next
    }
    col>0 && ($0 ~ /^[[:space:]]*[NTC],[NTC],/ || $0 ~ /^[[:space:]]*[a-zA-Z0-9_]+,[NTC],[NTC],/) {
      v=$col
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if(v ~ /^[0-9]+(\.[0-9]+)?$/) val=v
    }
    END { if(val!="") print val }
  ' "$file" 2>/dev/null)
  if [[ -n "${gflops}" ]]; then
    echo "${gflops}"
    return 0
  fi
  gflops=$(grep -Eo '([0-9]+(\.[0-9]+)?)\s*(Gflop/s|GFLOP/s|GFLOPS|gflops)' "$file" | tail -n1 | awk '{print $1}')
  if [[ -n "${gflops}" ]]; then
    echo "${gflops}"
    return 0
  fi
  gflops=$(awk '
    /Gflop/ {for(i=1;i<=NF;i++) if($i ~ /Gflop/) col=i}
    col && NF>=col {val=$col}
    END {if(val!="") print val}
  ' "$file")
  if [[ -n "${gflops}" ]]; then
    echo "${gflops}"
    return 0
  fi
  echo ""
}

extract_tflops() {
  local file="$1"
  local tflops
  tflops=$(grep -Eo '([0-9]+(\.[0-9]+)?)\s*(Tflop/s|TFLOP/s|TFLOPS|tflops)' "$file" | tail -n1 | awk '{print $1}')
  if [[ -n "${tflops}" ]]; then
    echo "${tflops}"
    return 0
  fi
  echo ""
}

extract_gbps() {
  local file="$1"
  local v
  v=$(grep -Eo '([0-9]+(\.[0-9]+)?)\s*GB/s' "$file" | tail -n1 | awk '{print $1}')
  echo "${v}"
}

extract_gsamples() {
  local file="$1"
  local v
  v=$(grep -Eo '([0-9]+(\.[0-9]+)?)\s*GSample/s' "$file" | tail -n1 | awk '{print $1}')
  echo "${v}"
}

extract_ms() {
  local file="$1"
  local v
  v=$(grep -Eo '([0-9]+(\.[0-9]+)?)\s*ms' "$file" | tail -n1 | awk '{print $1}')
  echo "${v}"
}

extract_sparse_metrics() {
  local file="$1"
  awk '
    BEGIN { g=0; b=0; m=0; gf=""; gb=""; ms="" }
    /^size[[:space:]]/ {
      for(i=1;i<=NF;i++) {
        if($i=="GFlop/s" || $i=="GFlops") g=i
        if($i=="GB/s") b=i
        if($i=="msec" || $i=="ms") m=i
      }
      next
    }
    g>0 && $1 ~ /^[0-9]+/ {
      gf=$g
      if(b>0) gb=$b
      if(m>0) ms=$m
    }
    END {
      if(gf!="") {
        out="GFLOP/s=" gf
        if(gb!="") out=out " (GB/s=" gb ")"
        if(ms!="") out=out " (ms=" ms ")"
        print out
      }
    }
  ' "$file" 2>/dev/null
}

extract_rocrand_metrics() {
  local file="$1"
  awk -F',' '
    BEGIN { gb=""; gs=""; ms="" }
    /^[a-zA-Z0-9_]+,[a-zA-Z0-9_-]+,[0-9]/ {
      gb=$3; gs=$4; ms=$5
    }
    END {
      if(gb!="") {
        out="GB/s=" gb
        if(gs!="") out=out " (GSample/s=" gs ")"
        if(ms!="") out=out " (ms=" ms ")"
        print out
      }
    }
  ' "$file" 2>/dev/null
}

extract_single_number() {
  local file="$1"
  local v
  # Some bench clients print a single numeric value (e.g. gpu_time_us).
  v="$(tr -d '[:space:]' <"${file}" | head -c 64)"
  if [[ "${v}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "${v}"
    return 0
  fi
  echo ""
  return 1
}

print_bench_menu() {
  cat <<'EOF_BENCH_MENU'

Bench menu (gfx1031):
  0) Run all (1-9)
  1) rocBLAS GEMM f32
  2) hipBLAS GEMM f32
  3) rocSOLVER geqrf_strided_batched (s)
  4) hipSOLVER (default) tiny solver
  5) rocSPARSE axpyi (s)
  6) hipSPARSE axpyi (s)
  7) rocFFT complex fwd 1024 (single)
  8) dyna-rocFFT complex fwd 1024 (single)
  9) rocRAND generate (philox, uniform-float)

Enter one number (e.g. 2) or a list (e.g. 1,2,7). Use 'q' to quit.
EOF_BENCH_MENU
}

parse_bench_selection() {
  local input="$1"
  local -a out=()
  input="$(echo "${input}" | tr -d '[:space:]')"
  input="${input//,/ }"
  # shellcheck disable=SC2206
  out=(${input})
  echo "${out[@]}"
}

fmt_status() {
  local s="$1"
  case "${s}" in
    OK) echo "${C_GREEN}OK${C_RESET}" ;;
    FAIL) echo "${C_RED}FAIL${C_RESET}" ;;
    SKIP) echo "${C_YELLOW}SKIP${C_RESET}" ;;
    *) echo "${s}" ;;
  esac
}

fmt_label() {
  local s="$1"
  echo "${C_BOLD}${s}${C_RESET}"
}

now_ms() {
  local t
  t="$(date +%s%3N 2>/dev/null || true)"
  if [[ -n "${t}" && "${t}" =~ ^[0-9]+$ ]]; then
    echo "${t}"
    return 0
  fi
  echo "$(( $(date +%s) * 1000 ))"
}

fmt_duration_ms() {
  local ms="$1"
  if [[ -z "${ms}" || "${ms}" == "0" ]]; then
    echo "0ms"
    return 0
  fi
  if (( ms < 1000 )); then
    echo "${ms}ms"
    return 0
  fi
  local s=$((ms / 1000))
  local rem_ms=$((ms % 1000))
  if (( s < 60 )); then
    printf "%d.%03ds" "${s}" "${rem_ms}"
    return 0
  fi
  local m=$((s / 60))
  local rem_s=$((s % 60))
  printf "%dm%02ds" "${m}" "${rem_s}"
}

print_run_header() {
  local title="$1"
  local build_dir="$2"
  local rocm_path="$3"

  local log_state="disabled (use --log [file])"
  if (( LOG_ENABLED )); then
    log_state="${LOG_FILE}"
  fi

  echo "${C_BOLD}${title}${C_RESET}" | tee -a "${LOG_FILE}"
  echo "${C_DIM}- build dir:${C_RESET} ${build_dir}" | tee -a "${LOG_FILE}"
  echo "${C_DIM}- ROCm:${C_RESET} ${rocm_path}" | tee -a "${LOG_FILE}"
  echo "${C_DIM}- mode:${C_RESET} ${MODE} (BENCH_SIZE=${BENCH_SIZE:-auto}, BENCH_ITERS=${BENCH_ITERS:-auto})" | tee -a "${LOG_FILE}"
  echo "${C_DIM}- logging:${C_RESET} ${log_state}" | tee -a "${LOG_FILE}"

  local what=()
  if (( RUN_CONSISTENCY )); then what+=("consistency"); fi
  if (( RUN_SANITY )); then what+=("sanity"); fi
  if (( RUN_MIOPEN )); then
    if (( RUN_MIOPEN_SMOKE )); then what+=("miopen-smoke"); else what+=("miopen"); fi
  fi
  if (( RUN_BENCH )); then
    if (( BENCH_MENU )); then what+=("bench-menu"); elif (( BENCH_LITE )); then what+=("bench-lite"); else what+=("bench"); fi
  fi
  if (( ${#what[@]} )); then
    echo "${C_DIM}- will run:${C_RESET} ${what[*]}" | tee -a "${LOG_FILE}"
  fi
  echo "" | tee -a "${LOG_FILE}"
}

run_timed() {
  local label="$1"
  local expected="$2"
  shift 2
  local cmd=("$@")
  local tmp
  tmp="$(mktemp)"
  echo "${C_CYAN}==>${C_RESET} $(fmt_label "${label}") ${C_DIM}(expected: ${expected})${C_RESET}" | tee -a "${LOG_FILE}"
  local start_ms
  start_ms="$(now_ms)"
  set +e
  "${cmd[@]}" 2>&1 | tee -a "${LOG_FILE}" | tee "${tmp}" >/dev/null
  local rc=${PIPESTATUS[0]}
  set -e
  local end_ms
  end_ms="$(now_ms)"
  local elapsed_ms=$((end_ms - start_ms))
  if [[ ${rc} -eq 0 ]]; then
    add_result "${label}" "OK" "$(fmt_duration_ms "${elapsed_ms}")" ""
  else
    add_result "${label}" "FAIL" "$(fmt_duration_ms "${elapsed_ms}")" "rc=${rc}"
  fi
  rm -f "${tmp}"
  return ${rc}
}

run_bench_with_timeout() {
  local label="$1"
  local expected="$2"
  local timeout_s="$3"
  shift 3
  local cmd=("$@")
  local tmp
  tmp="$(mktemp)"
  echo "${C_CYAN}==>${C_RESET} $(fmt_label "${label}") ${C_DIM}(expected: ${expected})${C_RESET}" | tee -a "${LOG_FILE}"
  local start_ms
  start_ms="$(now_ms)"
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status "${timeout_s}" "${cmd[@]}" 2>&1 | tee -a "${LOG_FILE}" | tee "${tmp}" >/dev/null
  else
    "${cmd[@]}" 2>&1 | tee -a "${LOG_FILE}" | tee "${tmp}" >/dev/null
  fi
  local rc=${PIPESTATUS[0]}
  set -e
  local end_ms
  end_ms="$(now_ms)"
  local elapsed_ms=$((end_ms - start_ms))
  local metric=""
  if [[ ${rc} -eq 124 || ${rc} -eq 137 || ${rc} -eq 143 ]]; then
    add_result "${label}" "SKIP" "$(fmt_duration_ms "${elapsed_ms}")" "timeout after ${timeout_s}s (first run may JIT; rerun)"
    rm -f "${tmp}"
    return 0
  elif [[ ${rc} -eq 0 ]]; then
    local gflops
    local tflops
    gflops="$(extract_gflops "${tmp}")"
    tflops="$(extract_tflops "${tmp}")"
    if [[ -z "${tflops}" && -n "${gflops}" ]]; then
      tflops=$(awk -v v="${gflops}" 'BEGIN{printf "%.3f", v/1000.0}')
      metric="TFLOPS=${tflops} (GFLOPS=${gflops})"
    elif [[ -n "${tflops}" ]]; then
      metric="TFLOPS=${tflops}"
    fi
    if [[ -z "${metric}" ]]; then
      local gbps
      local gs
      local ms
      local special
      gbps="$(extract_gbps "${tmp}")"
      gs="$(extract_gsamples "${tmp}")"
      ms="$(extract_ms "${tmp}")"
      if [[ -n "${gbps}" ]]; then
        metric="GB/s=${gbps}"
        if [[ -n "${gs}" ]]; then
          metric="${metric} (GSample/s=${gs})"
        fi
      elif [[ -n "${gs}" ]]; then
        metric="GSample/s=${gs}"
      elif [[ -n "${ms}" ]]; then
        metric="ms=${ms}"
      fi
      if [[ -z "${metric}" && ( "${label}" == *"rocSPARSE"* || "${label}" == *"hipSPARSE"* ) ]]; then
        special="$(extract_sparse_metrics "${tmp}")"
        metric="${special:-}"
      fi
      if [[ -z "${metric}" && "${label}" == *"rocRAND"* ]]; then
        special="$(extract_rocrand_metrics "${tmp}")"
        metric="${special:-}"
      fi
      if [[ -z "${metric}" && ( "${label}" == *"rocSOLVER"* || "${label}" == *"hipSOLVER"* ) ]]; then
        special="$(extract_single_number "${tmp}")"
        if [[ -n "${special}" ]]; then
          metric="gpu_time_us=${special}"
        fi
      fi
    fi
    add_result "${label}" "OK" "$(fmt_duration_ms "${elapsed_ms}")" "${metric}"
  else
    # Some upstream bench clients can print valid results but still exit non-zero
    # (observed: rocsolver-bench exits 255 while printing a full "Results" table).
    if [[ ${rc} -eq 255 ]] && [[ "${label}" == *"rocSOLVER"* ]] && rg -q "Results:|gpu_time" "${tmp}"; then
      add_result "${label}" "OK" "$(fmt_duration_ms "${elapsed_ms}")" "rc=255 (client exit-code bug; results printed)"
    else
      add_result "${label}" "FAIL" "$(fmt_duration_ms "${elapsed_ms}")" "rc=${rc}"
    fi
  fi
  rm -f "${tmp}"
  return ${rc}
}

run_bench_suite() {
  local timeout_s="$1"
  shift 1
  local -a selected=("$@")
  local expected_blas="${BENCH_EXPECTED}"
  local expected_misc="${BENCH_EXPECTED_MISC}"

  bench_selected() {
    local idx="$1"
    if (( ${#selected[@]} == 0 )); then
      return 0
    fi
    local s
    for s in "${selected[@]}"; do
      if [[ "${s}" == "${idx}" ]]; then
        return 0
      fi
    done
    return 1
  }

  # 1) BLAS (GEMM) — good "is my stack fast?" signal
  if bench_selected 1 && command -v rocblas-bench >/dev/null 2>&1; then
    run_bench_with_timeout "bench: rocBLAS GEMM f32" "${expected_blas}" "${timeout_s}" \
      rocblas-bench -f gemm -r f32_r -m "${BENCH_SIZE}" -n "${BENCH_SIZE}" -k "${BENCH_SIZE}" \
      --alpha 1 --beta 0 --iters "${BENCH_ITERS}" || true
  elif bench_selected 1; then
    add_result "bench: rocBLAS GEMM f32" "SKIP" "0s" "rocblas-bench not in PATH (enable build.benchmarks=true, then rebuild rocBLAS)"
  fi

  if bench_selected 2 && command -v hipblas-bench >/dev/null 2>&1; then
    run_bench_with_timeout "bench: hipBLAS GEMM f32" "${expected_blas}" "${timeout_s}" \
      hipblas-bench -f gemm -r f32_r -m "${BENCH_SIZE}" -n "${BENCH_SIZE}" -k "${BENCH_SIZE}" \
      --alpha 1 --beta 0 --iters "${BENCH_ITERS}" || true
  elif bench_selected 2; then
    add_result "bench: hipBLAS GEMM f32" "SKIP" "0s" "hipblas-bench not in PATH (enable build.benchmarks=true, then rebuild hipBLAS)"
  fi

  if (( BENCH_LITE )); then
    return 0
  fi

  # 2) SOLVER (LAPACK-ish)
  if bench_selected 3 && command -v rocsolver-bench >/dev/null 2>&1; then
    # Use a known-good invocation that returns rc=0 and produces timing output.
    run_bench_with_timeout "bench: rocSOLVER geqrf_strided_batched (s)" "${expected_misc}" "${timeout_s}" \
      rocsolver-bench -f geqrf_strided_batched -r s -m 30 --batch_count 100 --perf 1 -i 2 || true
  elif bench_selected 3; then
    add_result "bench: rocSOLVER geqrf_strided_batched (s)" "SKIP" "0s" "rocsolver-bench not in PATH"
  fi

  if bench_selected 4 && command -v hipsolver-bench >/dev/null 2>&1; then
    run_bench_with_timeout "bench: hipSOLVER (tiny solver)" "${expected_misc}" "${timeout_s}" \
      hipsolver-bench -m 128 -n 128 -i 2 || true
  elif bench_selected 4; then
    add_result "bench: hipSOLVER (tiny solver)" "SKIP" "0s" "hipsolver-bench not in PATH"
  fi

  # 3) SPARSE
  if bench_selected 5 && command -v rocsparse-bench >/dev/null 2>&1; then
    run_bench_with_timeout "bench: rocSPARSE axpyi (s)" "${expected_misc}" "${timeout_s}" \
      rocsparse-bench -f axpyi -n 256 -z 64 -i 1 --iters_inner 1 -v 0 -r s || true
  elif bench_selected 5; then
    add_result "bench: rocSPARSE axpyi (s)" "SKIP" "0s" "rocsparse-bench not in PATH"
  fi

  if bench_selected 6 && command -v hipsparse-bench >/dev/null 2>&1; then
    run_bench_with_timeout "bench: hipSPARSE axpyi (s)" "${expected_misc}" "${timeout_s}" \
      hipsparse-bench -f axpyi -n 256 -z 64 -i 1 --iters_inner 1 -v 0 -r s || true
  elif bench_selected 6; then
    add_result "bench: hipSPARSE axpyi (s)" "SKIP" "0s" "hipsparse-bench not in PATH"
  fi

  # 4) FFT
  if bench_selected 7 && command -v rocfft-bench >/dev/null 2>&1; then
    run_bench_with_timeout "bench: rocFFT complex fwd 1024 (single)" "${expected_misc}" "${timeout_s}" \
      rocfft-bench --length 1024 --precision single -t 0 -N 2 || true
  elif bench_selected 7; then
    add_result "bench: rocFFT complex fwd 1024 (single)" "SKIP" "0s" "rocfft-bench not in PATH"
  fi

  if bench_selected 8 && command -v dyna-rocfft-bench >/dev/null 2>&1; then
    local lib
    lib="$(ls -1 "${ROCM_PATH}/lib/librocfft.so"* 2>/dev/null | head -n 1 || true)"
    if [[ -n "${lib}" ]]; then
      run_bench_with_timeout "bench: dyna-rocFFT complex fwd 1024 (single)" "${expected_misc}" "${timeout_s}" \
        dyna-rocfft-bench --lib "${lib}" --length 1024 --precision single -t 0 -N 2 || true
    else
      add_result "bench: dyna-rocFFT complex fwd 1024 (single)" "SKIP" "0s" "librocfft.so not found under ${ROCM_PATH}/lib"
    fi
  elif bench_selected 8; then
    add_result "bench: dyna-rocFFT complex fwd 1024 (single)" "SKIP" "0s" "dyna-rocfft-bench not in PATH"
  fi

  # 5) RNG
  if bench_selected 9 && command -v benchmark_rocrand_generate >/dev/null 2>&1; then
    run_bench_with_timeout "bench: rocRAND generate (philox, uniform-float)" "${expected_misc}" "${timeout_s}" \
      benchmark_rocrand_generate --size 1048576 --trials 2 --dis uniform-float --engine philox --format csv || true
  elif bench_selected 9; then
    add_result "bench: rocRAND generate (philox, uniform-float)" "SKIP" "0s" "benchmark_rocrand_generate not in PATH"
  fi
}

if [[ "${MODE}" == "full" ]]; then
  BENCH_SIZE="${BENCH_SIZE:-4096}"
  BENCH_ITERS="${BENCH_ITERS:-20}"
  # RX 6700 XT (gfx1031) typical: GEMM 2-6s, others <1s (warm cache).
  BENCH_EXPECTED="typ. 2-6s"
  BENCH_EXPECTED_MISC="typ. <1s"
  BENCH_TIMEOUT_S="${BENCH_TIMEOUT_S:-900}"
else
  BENCH_SIZE="${BENCH_SIZE:-2048}"
  BENCH_ITERS="${BENCH_ITERS:-10}"
  # RX 6700 XT (gfx1031) typical: GEMM 1-2s, others <1s (warm cache).
  BENCH_EXPECTED="typ. 1-2s"
  BENCH_EXPECTED_MISC="typ. <1s"
  BENCH_TIMEOUT_S="${BENCH_TIMEOUT_S:-300}"
fi

print_run_header "gfx1031 test run" "${BUILD_DIR}" "${ROCM_PATH}"

detect_expect_stage

if (( RUN_CONSISTENCY )); then
  echo "==== consistency checks (${BUILD_DIR}) ====" | tee -a "${LOG_FILE}"
  add_result "expected stage" "OK" "0s" "${EXPECT_STAGE:-unspecified}"
  check_cmd_available "tool present: ninja" ninja || true
  check_cmd_available "tool present: cmake" cmake || true
  check_cmd_available "tool present: ccache" ccache || true

  # Basic cache/path hygiene checks
  # Light scan excludes known-benign matches (packaging prefixes inside internal ExternalProject caches).
  check_no_opt_rocm_in_caches \
    "no /opt/rocm in caches" \
    "scan CMakeCache.txt under ${BUILD_DIR}" \
    "/compiler/amd-llvm/build/runtimes/|CPACK_PACKAGING_INSTALL_PREFIX:(STRING|PATH)=/opt/rocm|CMAKE_INSTALL_PREFIX:(STRING|PATH)=/opt/rocm|_GNUInstallDirs_LAST_CMAKE_INSTALL_PREFIX:INTERNAL=/opt/rocm|FIND_PACKAGE_MESSAGE_DETAILS_HIP:INTERNAL=\\[/opt/rocm/bin\\]" || true
  check_toolchain_paths "${EXPECT_STAGE}" "toolchain" || true
  if (( HAVE_ROCM_ENV )) && [[ "${EXPECT_STAGE}" == "stage2" ]]; then
    check_hip_device_libs "hip" || true
  else
    add_result "hip device libs" "SKIP" "0s" "Stage-1 (or ROCM_PATH missing)"
  fi

  if (( CONSISTENCY_DEEP )); then
    # Deep scan: scan everything under BUILD_DIR, but still exclude known-benign
    # packaging defaults and internal caches that mention /opt/rocm without
    # actually *using* it as an effective search root.
    check_no_opt_rocm_in_caches \
      "no /opt/rocm in caches (deep)" \
      "full scan under ${BUILD_DIR} (excluding known-benign packaging defaults)" \
      "/compiler/amd-llvm/build/runtimes/|CPACK_PACKAGING_INSTALL_PREFIX:(STRING|PATH)=/opt/rocm|CMAKE_INSTALL_PREFIX:(STRING|PATH)=/opt/rocm|_GNUInstallDirs_LAST_CMAKE_INSTALL_PREFIX:INTERNAL=/opt/rocm|FIND_PACKAGE_MESSAGE_DETAILS_HIP:INTERNAL=\\[/opt/rocm/bin\\]" || true
    if (( HAVE_ROCM_ENV )); then
      check_runtime_linkage "runtime" || true
    else
      add_result "runtime linkage" "SKIP" "0s" "ROCM_PATH missing"
    fi
  else
    add_result "runtime linkage" "SKIP" "0s" "use --deep to run ldd checks"
  fi
fi

if (( RUN_SANITY )); then
  if command -v rocminfo >/dev/null 2>&1; then
    run_timed "rocminfo (sanity)" "typ. <1s" rocminfo
  else
    add_result "rocminfo (sanity)" "SKIP" "0s" "not in PATH"
  fi

  if command -v hipinfo >/dev/null 2>&1; then
    run_timed "hipinfo (sanity)" "typ. <1s" hipinfo
  else
    add_result "hipinfo (sanity)" "SKIP" "0s" "not in PATH (linux builds typically don't ship hipinfo; core-hipinfo is windows-only)"
  fi
fi

if (( RUN_MIOPEN )); then
  run_miopen_checks "miopen" || true
fi

if (( RUN_BENCH )); then
  if (( BENCH_MENU )); then
    if [[ ! -t 0 ]]; then
      echo "ERROR: --bench-menu requires an interactive TTY (stdin)." | tee -a "${LOG_FILE}" >&2
      exit 2
    fi
    while true; do
      print_bench_menu | tee -a "${LOG_FILE}"
      read -r -p "Select bench test (0-9, list, q): " sel
      echo "Selection: ${sel}" | tee -a "${LOG_FILE}"
      case "${sel}" in
        q|quit|exit)
          break
          ;;
        "")
          continue
          ;;
      esac
      # shellcheck disable=SC2207
      selected_arr=($(parse_bench_selection "${sel}"))
      # If user chose 0, run all (empty selection -> all).
      for s in "${selected_arr[@]}"; do
        if [[ "${s}" == "0" ]]; then
          selected_arr=()
          break
        fi
      done

      # Reset results per selection so the summary is for this run only.
      RESULT_LABELS=()
      RESULT_STATUS=()
      RESULT_TIME=()
      RESULT_METRIC=()

      run_bench_suite "${BENCH_TIMEOUT_S}" "${selected_arr[@]}"

      echo "" | tee -a "${LOG_FILE}"
      echo "==== gfx1031 test summary ====" | tee -a "${LOG_FILE}"
      for i in "${!RESULT_LABELS[@]}"; do
        label="${RESULT_LABELS[$i]}"
        status="${RESULT_STATUS[$i]}"
        time="${RESULT_TIME[$i]}"
        metric="${RESULT_METRIC[$i]}"
        fmt_s="$(fmt_status "${status}")"
        fmt_l="$(fmt_label "${label}")"
        if [[ -n "${metric}" ]]; then
          printf -- "- %02d) %-36s %s ${C_DIM}(%s)${C_RESET} %s\n" "$((i+1))" "${fmt_l}" "${fmt_s}" "${time}" "${metric}" | tee -a "${LOG_FILE}"
        else
          printf -- "- %02d) %-36s %s ${C_DIM}(%s)${C_RESET}\n" "$((i+1))" "${fmt_l}" "${fmt_s}" "${time}" | tee -a "${LOG_FILE}"
        fi
      done
      if (( LOG_ENABLED )); then
        echo "${C_DIM}Log:${C_RESET} ${LOG_FILE}" | tee -a "${LOG_FILE}"
      else
        echo "${C_DIM}Log:${C_RESET} (disabled; re-run with --log [file])" | tee -a "${LOG_FILE}"
      fi
    done
  else
    run_bench_suite "${BENCH_TIMEOUT_S}"
  fi
fi

echo "" | tee -a "${LOG_FILE}"
echo "==== gfx1031 test summary ====" | tee -a "${LOG_FILE}"
for i in "${!RESULT_LABELS[@]}"; do
  label="${RESULT_LABELS[$i]}"
  status="${RESULT_STATUS[$i]}"
  time="${RESULT_TIME[$i]}"
  metric="${RESULT_METRIC[$i]}"
  fmt_s="$(fmt_status "${status}")"
  fmt_l="$(fmt_label "${label}")"
  if [[ -n "${metric}" ]]; then
    printf -- "- %02d) %-36s %s ${C_DIM}(%s)${C_RESET} %s\n" "$((i+1))" "${fmt_l}" "${fmt_s}" "${time}" "${metric}" | tee -a "${LOG_FILE}"
  else
    printf -- "- %02d) %-36s %s ${C_DIM}(%s)${C_RESET}\n" "$((i+1))" "${fmt_l}" "${fmt_s}" "${time}" | tee -a "${LOG_FILE}"
  fi
done

if (( LOG_ENABLED )); then
  echo "${C_DIM}Log:${C_RESET} ${LOG_FILE}" | tee -a "${LOG_FILE}"
else
  echo "${C_DIM}Log:${C_RESET} (disabled; re-run with --log [file])" | tee -a "${LOG_FILE}"
fi
