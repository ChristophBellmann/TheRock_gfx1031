#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${ROOT}/test_gfx1031.log"
MODE="quick"
RUN_SANITY=1
# Default behavior is *build validation* (sanity + consistency). Benchmarks are
# opt-in because they can be slow and depend on installed bench binaries.
RUN_BENCH=0
RUN_MIOPEN=0
RUN_MIOPEN_SMOKE=0
BUILD_DIR="${BUILD_DIR:-build}"
RUN_CONSISTENCY=0
CONSISTENCY_DEEP=0
EXPECT_STAGE="" # "", "stage1", "stage2"
STAGE1_BUILD_DIR="${STAGE1_BUILD_DIR:-build-stage1}"

usage() {
  cat <<'EOF_USAGE'
Usage: test_gfx1031.sh [options]

Options:
  --quick        Select quick benchmark sizes (default mode)
  --full         Select longer benchmark sizes (bigger sizes / more iters)
  --bench        Run performance benchmarks (in addition to sanity)
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
  TEST_LOG         override log file (default test_gfx1031.log)
  BUILD_DIR        build directory name (default build)
  STAGE1_BUILD_DIR Stage-1 build dir for Stage-2 expectations (default: build-stage1)
EOF_USAGE
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
      shift
      ;;
    --stage2)
      BUILD_DIR="build-stage2"
      shift
      ;;
    --build-dir)
      BUILD_DIR="${2:-}"
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

if [[ -n "${TEST_LOG:-}" ]]; then
  LOG_FILE="${TEST_LOG}"
fi

if [[ -f "${ROOT}/.venv/bin/activate" ]] && [[ -z "${VIRTUAL_ENV:-}" ]]; then
  # Activate venv for helper tools if present.
  # shellcheck disable=SC1091
  source "${ROOT}/.venv/bin/activate"
fi

if [[ -f "${LOG_FILE}" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  mv "${LOG_FILE}" "${LOG_FILE}.bak-${ts}"
fi

touch "${LOG_FILE}"

ROCM_PATH_DEFAULT="${ROOT}/${BUILD_DIR}/dist/rocm"
ROCM_PATH="${ROCM_PATH:-${ROCM_PATH_DEFAULT}}"
HAVE_ROCM_ENV=0
if [[ -d "${ROCM_PATH}" ]]; then
  HAVE_ROCM_ENV=1
  export ROCM_PATH
  export HIP_PATH="${HIP_PATH:-$ROCM_PATH}"
  export HSA_PATH="${HSA_PATH:-$ROCM_PATH}"
  export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:${PATH:-}"
  export LD_LIBRARY_PATH="$ROCM_PATH/lib:$ROCM_PATH/lib64:$ROCM_PATH/lib/rocm_sysdeps/lib:$ROCM_PATH/llvm/lib:${LD_LIBRARY_PATH:-}"
  if [[ -z "${HIP_DEVICE_LIB_PATH:-}" ]]; then
    if [[ -d "$ROCM_PATH/lib/llvm/amdgcn/bitcode" ]]; then
      export HIP_DEVICE_LIB_PATH="$ROCM_PATH/lib/llvm/amdgcn/bitcode"
    else
      export HIP_DEVICE_LIB_PATH="$ROCM_PATH/amdgcn/bitcode"
    fi
  fi
  echo "Activated in-tree ROCm: ${ROCM_PATH}" | tee -a "${LOG_FILE}"
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
    add_result "${label_prefix} miopen library" "FAIL" "0s" "libMIOpen not found under ${ROCM_PATH}/lib{,64}"
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
    add_result "${label_prefix} miopen artifacts" "FAIL" "${elapsed}s" ""
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

run_timed() {
  local label="$1"
  local expected="$2"
  shift 2
  local cmd=("$@")
  local tmp
  tmp="$(mktemp)"
  echo "==> ${label} (expected: ${expected})" | tee -a "${LOG_FILE}"
  local start=$SECONDS
  set +e
  "${cmd[@]}" 2>&1 | tee -a "${LOG_FILE}" | tee "${tmp}" >/dev/null
  local rc=${PIPESTATUS[0]}
  set -e
  local elapsed=$((SECONDS - start))
  if [[ ${rc} -eq 0 ]]; then
    add_result "${label}" "OK" "${elapsed}s" ""
  else
    add_result "${label}" "FAIL" "${elapsed}s" "rc=${rc}"
  fi
  rm -f "${tmp}"
  return ${rc}
}

run_bench() {
  local label="$1"
  local expected="$2"
  shift 2
  local cmd=("$@")
  local tmp
  tmp="$(mktemp)"
  echo "==> ${label} (expected: ${expected})" | tee -a "${LOG_FILE}"
  local start=$SECONDS
  set +e
  "${cmd[@]}" 2>&1 | tee -a "${LOG_FILE}" | tee "${tmp}" >/dev/null
  local rc=${PIPESTATUS[0]}
  set -e
  local elapsed=$((SECONDS - start))
  local metric=""
  if [[ ${rc} -eq 0 ]]; then
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
    add_result "${label}" "OK" "${elapsed}s" "${metric}"
  else
    add_result "${label}" "FAIL" "${elapsed}s" "rc=${rc}"
  fi
  rm -f "${tmp}"
  return ${rc}
}

if [[ "${MODE}" == "full" ]]; then
  BENCH_SIZE="${BENCH_SIZE:-4096}"
  BENCH_ITERS="${BENCH_ITERS:-20}"
  BENCH_EXPECTED="30-120s"
else
  BENCH_SIZE="${BENCH_SIZE:-2048}"
  BENCH_ITERS="${BENCH_ITERS:-10}"
  BENCH_EXPECTED="10-45s"
fi

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
    # Deep scan: no exclusions.
    check_no_opt_rocm_in_caches "no /opt/rocm in caches (deep)" "full scan under ${BUILD_DIR}" "" || true
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
    run_timed "rocminfo (sanity)" "<10s" rocminfo
  else
    add_result "rocminfo (sanity)" "SKIP" "0s" "not in PATH"
  fi

  if command -v hipinfo >/dev/null 2>&1; then
    run_timed "hipinfo (sanity)" "<10s" hipinfo
  else
    add_result "hipinfo (sanity)" "SKIP" "0s" "not in PATH"
  fi
fi

if (( RUN_MIOPEN )); then
  run_miopen_checks "miopen" || true
fi

if (( RUN_BENCH )); then
  if command -v rocblas-bench >/dev/null 2>&1; then
    run_bench "rocBLAS GEMM f32" "${BENCH_EXPECTED}" \
      rocblas-bench -f gemm -r f32_r -m "${BENCH_SIZE}" -n "${BENCH_SIZE}" -k "${BENCH_SIZE}" \
      --alpha 1 --beta 0 --iters "${BENCH_ITERS}"
  else
    add_result "rocBLAS GEMM f32" "SKIP" "0s" "rocblas-bench not in PATH"
  fi

  if command -v hipblas-bench >/dev/null 2>&1; then
    run_bench "hipBLAS GEMM f32" "${BENCH_EXPECTED}" \
      hipblas-bench -f gemm -r f32_r -m "${BENCH_SIZE}" -n "${BENCH_SIZE}" -k "${BENCH_SIZE}" \
      --alpha 1 --beta 0 --iters "${BENCH_ITERS}"
  else
    add_result "hipBLAS GEMM f32" "SKIP" "0s" "hipblas-bench not in PATH"
  fi
fi

echo "" | tee -a "${LOG_FILE}"
echo "==== gfx1031 test summary ====" | tee -a "${LOG_FILE}"
for i in "${!RESULT_LABELS[@]}"; do
  label="${RESULT_LABELS[$i]}"
  status="${RESULT_STATUS[$i]}"
  time="${RESULT_TIME[$i]}"
  metric="${RESULT_METRIC[$i]}"
  if [[ -n "${metric}" ]]; then
    printf -- "- %-28s %s (%s) %s\n" "${label}" "${status}" "${time}" "${metric}" | tee -a "${LOG_FILE}"
  else
    printf -- "- %-28s %s (%s)\n" "${label}" "${status}" "${time}" | tee -a "${LOG_FILE}"
  fi
done

echo "Log: ${LOG_FILE}" | tee -a "${LOG_FILE}"
