#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD_DIR="${BUILD_DIR:-build-stage2}"
IMAGE="${IMAGE:-rocm/dev-ubuntu-24.04:latest}"
MODE="quick"
BENCH_LITE=1
KEEP_LOGS=1
OUT_DIR=""
INSTALL_DEPS=1
POWER=1

usage() {
  cat <<'EOF'
Usage: compare_perf_gfx1031.sh [options]

Runs a small benchmark suite twice:
1) directly on the host (using <builddir>/dist/rocm)
2) inside an ROCm dev docker image (mounting this repo, using the same dist)

Then parses key metrics and prints a side-by-side comparison.

Options:
  --stage2           Use BUILD_DIR=build-stage2 (default)
  --stage1           Use BUILD_DIR=build-stage1
  --build-dir <dir>  Override build dir
  --image <image>    Docker image (default: rocm/dev-ubuntu-22.04:latest)
  --bench            Run full bench set (default: bench-lite)
  --bench-lite       Run only BLAS GEMM benches (default)
  --full             Longer bench sizes/iters (passes --full)
  --no-power         Disable sysfs power sampling (default: enabled)
  --out <dir>        Write logs under this dir (default: ./perf_compare/<timestamp>/)
  --no-install-deps  Do not install runtime deps in the docker image (default: installs libgfortran5)
  --no-logs          Do not keep logs (still prints summary)
  -h, --help         Show this help

Env overrides:
  BUILD_DIR, IMAGE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage2) BUILD_DIR="build-stage2"; shift ;;
    --stage1) BUILD_DIR="build-stage1"; shift ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --bench) BENCH_LITE=0; shift ;;
    --bench-lite) BENCH_LITE=1; shift ;;
    --full) MODE="full"; shift ;;
    --no-power) POWER=0; shift ;;
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    --no-install-deps) INSTALL_DEPS=0; shift ;;
    --no-logs) KEEP_LOGS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${BUILD_DIR}" ]]; then
  echo "BUILD_DIR is empty" >&2
  exit 2
fi

ts="$(date +%Y%m%d-%H%M%S)"
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="${ROOT}/perf_compare/${ts}"
fi
mkdir -p "${OUT_DIR}"

local_log="${OUT_DIR}/host.${BUILD_DIR}.log"

# Docker must write logs to a mounted path. If OUT_DIR is outside the repo root,
# write the docker log under the repo and copy it back afterwards.
docker_out_dir="${OUT_DIR}"
if [[ "${OUT_DIR}" != "${ROOT}"* ]]; then
  docker_out_dir="${ROOT}/perf_compare/${ts}"
  mkdir -p "${docker_out_dir}"
fi
docker_log="${docker_out_dir}/docker.${BUILD_DIR}.log"

bench_args=(--bench)
if (( BENCH_LITE )); then
  bench_args=(--bench-lite)
fi
if [[ "${MODE}" == "full" ]]; then
  bench_args+=(--full)
fi
if (( POWER )); then
  bench_args+=(--power)
fi

echo "== host bench =="
host_rc=0
set +e
./test_gfx1031.sh --build-dir "${BUILD_DIR}" "${bench_args[@]}" --log "${local_log}"
host_rc=$?
set -e
if (( host_rc != 0 )); then
  echo "Host run failed (rc=${host_rc}). Log: ${local_log}" >&2
  exit "${host_rc}"
fi

echo ""
echo "== docker bench =="
docker_rc=0
set +e
docker_args=(--image "${IMAGE}" --build-dir "${BUILD_DIR}" "${bench_args[@]}" --no-shell --no-tty --log "${docker_log}")
if (( INSTALL_DEPS )); then
  docker_args+=(--install-deps)
fi
./run_rocm_container.sh "${docker_args[@]}"
docker_rc=$?
set -e
if (( docker_rc != 0 )); then
  echo "Docker run failed (rc=${docker_rc}). Log: ${docker_log}" >&2
  if [[ -f "${docker_log}" ]]; then
    if rg -q "GLIBC_[0-9.]+' not found|GLIBCXX_" "${docker_log}"; then
      echo "Hint: container userland is too old for your in-tree dist (glibc/libstdc++ mismatch). Try a newer image, e.g.:" >&2
      echo "  ./compare_perf_gfx1031.sh --image rocm/dev-ubuntu-24.04:latest" >&2
    fi
    echo "--- docker log tail ---" >&2
    tail -n 20 "${docker_log}" >&2
  fi
  exit "${docker_rc}"
fi

extract_tflops() {
  local label="$1"
  local file="$2"
  # Prefer TFLOPS=; fall back to GFLOPS=
  local t
  t="$(rg -n "${label}" "${file}" | rg -o "TFLOPS=[0-9.]+" | tail -n 1 | cut -d= -f2 || true)"
  if [[ -z "${t}" ]]; then
    local g
    g="$(rg -n "${label}" "${file}" | rg -o "GFLOPS=[0-9.]+" | tail -n 1 | cut -d= -f2 || true)"
    if [[ -n "${g}" ]]; then
      t="$(python3 -c "print(float('${g}')/1000.0)")"
    fi
  fi
  echo "${t}"
}

extract_kv() {
  local label="$1"
  local key="$2" # e.g. avgW, gpu%, maxW
  local file="$3"
  python3 - "${label}" "${key}" "${file}" <<'PY'
import re,sys
label=sys.argv[1]
key=sys.argv[2]
path=sys.argv[3]
try:
    lines=open(path,'r',encoding='utf-8',errors='replace').read().splitlines()
except FileNotFoundError:
    print("")
    raise SystemExit(0)

line=""
for ln in lines:
    if label in ln:
        line=ln
if not line:
    print("")
    raise SystemExit(0)

m=re.search(rf"{re.escape(key)}\s*=\s*([+\-]?[0-9]+(?:\.[0-9]+)?)", line)
print(m.group(1) if m else "")
PY
}

fmt_pct() {
  local a="$1"
  local b="$2"
  if [[ -z "${a}" || -z "${b}" ]]; then
    echo "n/a"
    return 0
  fi
  python3 -c "a=float('${a}'); b=float('${b}'); print('n/a' if a==0 else f'{(b-a)/a*100.0:+.1f}%')"
}

host_rocblas="$(extract_tflops "rocBLAS GEMM f32" "${local_log}")"
docker_rocblas="$(extract_tflops "rocBLAS GEMM f32" "${docker_log}")"
host_hipblas="$(extract_tflops "hipBLAS GEMM f32" "${local_log}")"
docker_hipblas="$(extract_tflops "hipBLAS GEMM f32" "${docker_log}")"

host_rocblas_avgw="$(extract_kv "bench: rocBLAS GEMM f32" "avgW" "${local_log}")"
docker_rocblas_avgw="$(extract_kv "bench: rocBLAS GEMM f32" "avgW" "${docker_log}")"
host_rocblas_gpu="$(extract_kv "bench: rocBLAS GEMM f32" "gpu%" "${local_log}")"
docker_rocblas_gpu="$(extract_kv "bench: rocBLAS GEMM f32" "gpu%" "${docker_log}")"

host_hipblas_avgw="$(extract_kv "bench: hipBLAS GEMM f32" "avgW" "${local_log}")"
docker_hipblas_avgw="$(extract_kv "bench: hipBLAS GEMM f32" "avgW" "${docker_log}")"
host_hipblas_gpu="$(extract_kv "bench: hipBLAS GEMM f32" "gpu%" "${local_log}")"
docker_hipblas_gpu="$(extract_kv "bench: hipBLAS GEMM f32" "gpu%" "${docker_log}")"

echo ""
echo "==== perf comparison (${BUILD_DIR}) ===="
printf "%-22s %10s %10s %10s  %9s %9s  %7s %7s\n" "bench" "hostTF" "dockTF" "ΔTF" "hostW" "dockW" "hGPU%" "dGPU%"
printf "%-22s %10s %10s %10s  %9s %9s  %7s %7s\n" \
  "rocBLAS GEMM f32" "${host_rocblas:-n/a}" "${docker_rocblas:-n/a}" "$(fmt_pct "${host_rocblas}" "${docker_rocblas}")" \
  "${host_rocblas_avgw:-n/a}" "${docker_rocblas_avgw:-n/a}" "${host_rocblas_gpu:-n/a}" "${docker_rocblas_gpu:-n/a}"
printf "%-22s %10s %10s %10s  %9s %9s  %7s %7s\n" \
  "hipBLAS GEMM f32" "${host_hipblas:-n/a}" "${docker_hipblas:-n/a}" "$(fmt_pct "${host_hipblas}" "${docker_hipblas}")" \
  "${host_hipblas_avgw:-n/a}" "${docker_hipblas_avgw:-n/a}" "${host_hipblas_gpu:-n/a}" "${docker_hipblas_gpu:-n/a}"

if (( KEEP_LOGS )); then
  if [[ "${docker_out_dir}" != "${OUT_DIR}" ]]; then
    mkdir -p "${OUT_DIR}"
    cp -f "${docker_log}" "${OUT_DIR}/docker.${BUILD_DIR}.log"
    docker_log="${OUT_DIR}/docker.${BUILD_DIR}.log"
  fi
  echo ""
  echo "Logs:"
  echo "- ${local_log}"
  echo "- ${docker_log}"
else
  rm -rf "${OUT_DIR}"
fi
