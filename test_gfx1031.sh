#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${ROOT}/test_gfx1031.log"
MODE="quick"
RUN_SANITY=1
RUN_BENCH=1
BUILD_DIR="${BUILD_DIR:-build}"

usage() {
  cat <<'EOF_USAGE'
Usage: test_gfx1031.sh [options]

Options:
  --quick        Quick sanity + light benchmarks (default)
  --full         Longer benchmarks (bigger sizes / more iters)
  --no-bench     Skip performance benchmarks
  --bench-only   Run benchmarks only
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
    --no-bench)
      RUN_BENCH=0
      shift
      ;;
    --bench-only)
      RUN_SANITY=0
      RUN_BENCH=1
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

ROCM_PATH_DEFAULT="${ROOT}/${BUILD_DIR}/dist/rocm"
ROCM_PATH="${ROCM_PATH:-${ROCM_PATH_DEFAULT}}"
if [[ ! -d "${ROCM_PATH}" ]]; then
  echo "ROCM_PATH not found: ${ROCM_PATH}" >&2
  echo "Build first (expected default: ${ROCM_PATH_DEFAULT})." >&2
  exit 1
fi

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

if [[ -f "${LOG_FILE}" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  mv "${LOG_FILE}" "${LOG_FILE}.bak-${ts}"
fi

touch "${LOG_FILE}"

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
    printf "- %-28s %s (%s) %s\n" "${label}" "${status}" "${time}" "${metric}" | tee -a "${LOG_FILE}"
  else
    printf "- %-28s %s (%s)\n" "${label}" "${status}" "${time}" | tee -a "${LOG_FILE}"
  fi
done

echo "Log: ${LOG_FILE}" | tee -a "${LOG_FILE}"
