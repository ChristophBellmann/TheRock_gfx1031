#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD_DIR="${BUILD_DIR:-build-stage2}"
IMAGE="${IMAGE:-rocm/dev-ubuntu-24.04:latest}"
MODE="quick"
BENCH_LITE=1
KEEP_LOGS=0
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
  --out <dir>        Write captured output under this dir (implies --keep-logs)
  --no-install-deps  Do not install runtime deps in the docker image (default: installs libgfortran5)
  --keep-logs        Keep logs under ./perf_compare/<timestamp>/ (default: delete after printing summary)
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
    --out) OUT_DIR="${2:-}"; KEEP_LOGS=1; shift 2 ;;
    --no-install-deps) INSTALL_DEPS=0; shift ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${BUILD_DIR}" ]]; then
  echo "BUILD_DIR is empty" >&2
  exit 2
fi

ts="$(date +%Y%m%d-%H%M%S)"
# Default: use a temp dir and delete it after printing summary (unless --keep-logs/--out).
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="$(mktemp -d -t perf_compare_gfx1031.XXXXXXXX)"
  if (( KEEP_LOGS )); then
    OUT_DIR="${ROOT}/perf_compare/${ts}"
  fi
fi
mkdir -p "${OUT_DIR}"

host_cap="${OUT_DIR}/host.${BUILD_DIR}.out"
docker_cap="${OUT_DIR}/docker.${BUILD_DIR}.out"

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
./test_gfx1031.sh --build-dir "${BUILD_DIR}" "${bench_args[@]}" 2>&1 | tee "${host_cap}"
host_rc=$?
set -e
if (( host_rc != 0 )); then
  echo "Host run failed (rc=${host_rc})." >&2
  exit "${host_rc}"
fi

echo ""
echo "== docker bench =="
docker_rc=0
set +e
docker_args=(--image "${IMAGE}" --build-dir "${BUILD_DIR}" "${bench_args[@]}" --no-tty)
if (( INSTALL_DEPS )); then
  docker_args+=(--install-deps)
fi
./run_rocm_container.sh "${docker_args[@]}" 2>&1 | tee "${docker_cap}"
docker_rc=$?
set -e
if (( docker_rc != 0 )); then
  echo "Docker run failed (rc=${docker_rc})." >&2
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

host_rocblas="$(extract_tflops "rocBLAS GEMM f32" "${host_cap}")"
docker_rocblas="$(extract_tflops "rocBLAS GEMM f32" "${docker_cap}")"
host_hipblas="$(extract_tflops "hipBLAS GEMM f32" "${host_cap}")"
docker_hipblas="$(extract_tflops "hipBLAS GEMM f32" "${docker_cap}")"

host_rocblas_avgw="$(extract_kv "bench: rocBLAS GEMM f32" "avgW" "${host_cap}")"
docker_rocblas_avgw="$(extract_kv "bench: rocBLAS GEMM f32" "avgW" "${docker_cap}")"
host_rocblas_gpu="$(extract_kv "bench: rocBLAS GEMM f32" "gpu%" "${host_cap}")"
docker_rocblas_gpu="$(extract_kv "bench: rocBLAS GEMM f32" "gpu%" "${docker_cap}")"

host_hipblas_avgw="$(extract_kv "bench: hipBLAS GEMM f32" "avgW" "${host_cap}")"
docker_hipblas_avgw="$(extract_kv "bench: hipBLAS GEMM f32" "avgW" "${docker_cap}")"
host_hipblas_gpu="$(extract_kv "bench: hipBLAS GEMM f32" "gpu%" "${host_cap}")"
docker_hipblas_gpu="$(extract_kv "bench: hipBLAS GEMM f32" "gpu%" "${docker_cap}")"

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
  echo ""
  echo "Captured output:"
  echo "- ${host_cap}"
  echo "- ${docker_cap}"
else
  rm -rf "${OUT_DIR}"
fi
