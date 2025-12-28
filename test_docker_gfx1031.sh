#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow piping into tools like `head` without reporting failures on SIGPIPE.
trap 'exit 0' PIPE

BUILD_DIR="${BUILD_DIR:-build-stage2}"
IMAGE="${IMAGE:-rocm/dev-ubuntu-24.04:latest}"

MODE="quick"            # quick|full
BENCH_LITE=0            # default: run full bench suite (1-9)
POWER=1                 # default: on (sanity check needs it)
INSTALL_DEPS=1          # default: on for benches in container
NO_TTY=0
DROP_SHELL=0
EXTRA_ARGS=()

DO_HOST=1
DO_DOCKER=1
COMPARE=1

KEEP_LOGS=0
OUT_DIR=""
LOG_PATH="" # optional single-file --log base

usage() {
  cat <<'EOF'
Usage: test_docker_gfx1031.sh [options]

Runs repo-local sanity/benches against the in-tree dist under <builddir>/dist/rocm:
- on the host
- in a ROCm dev docker image (mounted repo + /dev/kfd,/dev/dri)

Default behavior:
  - bench (suite 1-9; skips missing tools) with power enabled
  - run host + docker
  - print a small comparison table
  - keep no log files (captures output to temp and deletes)

Options:
  --stage2            Use BUILD_DIR=build-stage2 (default)
  --stage1            Use BUILD_DIR=build-stage1
  --build-dir <dir>   Override build dir
  --image <image>     Docker image (default: rocm/dev-ubuntu-24.04:latest)

  --bench             Run full bench set (suite 1-9) (default)
  --bench-lite        Run BLAS GEMM benches only
  --full              Use longer benchmark sizes (passes --full)

  --no-power          Disable sysfs power sampling
  --no-install-deps   Do not install minimal runtime deps in the container

  --consistency       Also run build/toolchain consistency checks
  --miopen            Also run MIOpen/composable_kernel checks
  --miopen-smoke      Also run a tiny MIOpenDriver smoke test (can take time on first run)

  --docker-only       Run only in docker (no host run, no compare)
  --host-only         Run only on host (no docker run, no compare)
  --no-compare        Do not print compare table (still runs host+docker)
  --shell             Drop into an interactive shell in the container after running tests
  --no-tty            Do not allocate a pseudo-TTY for docker

  --keep-logs         Keep captured stdout/stderr under ./perf_compare/<timestamp>/
  --out <dir>         Keep captured output under <dir> (implies --keep-logs)
  --log [file]        Keep captured output. If <file> is provided:
                      - compare mode: writes <file>.host and <file>.docker
                      - docker-only: writes <file>

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
    --no-install-deps) INSTALL_DEPS=0; shift ;;
    --consistency) EXTRA_ARGS+=(--consistency); shift ;;
    --miopen) EXTRA_ARGS+=(--miopen); shift ;;
    --miopen-smoke) EXTRA_ARGS+=(--miopen-smoke); shift ;;
    --docker-only) DO_HOST=0; DO_DOCKER=1; COMPARE=0; shift ;;
    --host-only) DO_HOST=1; DO_DOCKER=0; COMPARE=0; shift ;;
    --no-compare) COMPARE=0; shift ;;
    --shell) DROP_SHELL=1; shift ;;
    --no-tty) NO_TTY=1; shift ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    --out) OUT_DIR="${2:-}"; KEEP_LOGS=1; shift 2 ;;
    --log)
      KEEP_LOGS=1
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        LOG_PATH="$2"
        shift 2
      else
        shift
      fi
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${BUILD_DIR}" ]]; then
  echo "BUILD_DIR is empty" >&2
  exit 2
fi

bench_args=()
if (( BENCH_LITE )); then
  bench_args+=(--bench-lite)
else
  bench_args+=(--bench)
fi
if [[ "${MODE}" == "full" ]]; then
  bench_args+=(--full)
fi
if (( POWER )); then
  bench_args+=(--power)
else
  # `test_gfx1031.sh` defaults power to ON. If the user disabled it here, be explicit.
  bench_args+=(--no-power)
fi

ts="$(date +%Y%m%d-%H%M%S)"
if [[ -z "${OUT_DIR}" ]]; then
  if (( KEEP_LOGS )); then
    OUT_DIR="${ROOT}/perf_compare/${ts}"
  else
    OUT_DIR="$(mktemp -d -t test_docker_gfx1031.XXXXXXXX)"
  fi
fi
mkdir -p "${OUT_DIR}"

host_cap="${OUT_DIR}/host.${BUILD_DIR}.out"
docker_cap="${OUT_DIR}/docker.${BUILD_DIR}.out"

if [[ -n "${LOG_PATH}" ]]; then
  if (( DO_DOCKER )) && (( DO_HOST )) && (( COMPARE )); then
    host_cap="${LOG_PATH}.host"
    docker_cap="${LOG_PATH}.docker"
  elif (( DO_DOCKER )) && (( ! DO_HOST )); then
    docker_cap="${LOG_PATH}"
  else
    host_cap="${LOG_PATH}"
  fi
  mkdir -p "$(dirname "${host_cap}")" "$(dirname "${docker_cap}")" 2>/dev/null || true
fi

run_host() {
  echo "== host run (local) =="
  local rc=0
  set +e
  ./test_gfx1031.sh --build-dir "${BUILD_DIR}" "${bench_args[@]}" "${EXTRA_ARGS[@]}" 2>&1 | tee "${host_cap}"
  rc=$?
  set -e
  return "${rc}"
}

docker_it=()
if (( ! NO_TTY )) && [[ -t 0 ]] && [[ -t 1 ]]; then
  docker_it=(-it)
fi

run_docker() {
  echo ""
  echo "== docker run (container) =="
  local rc=0
  set +e
  docker run --rm "${docker_it[@]}" \
    --device=/dev/kfd --device=/dev/dri \
    --group-add video --group-add render \
    --security-opt seccomp=unconfined \
    -v "${ROOT}:/work:rw" \
    -w /work \
    "${IMAGE}" \
    bash -lc "
      set -euo pipefail
      if (( ${INSTALL_DEPS} )); then
        if command -v apt-get >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -y >/dev/null
          apt-get install -y --no-install-recommends libgfortran5 >/dev/null || true
        fi
      fi
      echo '== GPU check (container) =='
      if command -v rocminfo >/dev/null 2>&1; then
        rocminfo | grep -E 'HSA Agents|Agent [0-9]+|Name:|Marketing Name:|Device Type:|amdgcn|gfx|Chip ID:' | head -n 120 || true
      else
        echo 'rocminfo not found in image'
      fi
      echo
      echo '== Activate in-tree ROCm (${BUILD_DIR}) =='
      export BUILD_DIR='${BUILD_DIR}'
      export ROCM_PATH=\"\$PWD/\$BUILD_DIR/dist/rocm\"
      export PATH=\"\$ROCM_PATH/bin:\$ROCM_PATH/llvm/bin:\$PATH\"
      export LD_LIBRARY_PATH=\"\$ROCM_PATH/lib:\$ROCM_PATH/lib64:\$ROCM_PATH/lib/host-math/lib:\$ROCM_PATH/lib/rocm_sysdeps/lib:\$ROCM_PATH/llvm/lib:\${LD_LIBRARY_PATH:-}\"
      export TEST_SKIP_VENV=1
      echo \"ROCM_PATH=\$ROCM_PATH\"
      echo
      rc=0
      ./test_gfx1031.sh --build-dir \"\$BUILD_DIR\" ${bench_args[*]} ${EXTRA_ARGS[*]} || rc=\$?
      echo
      echo \"test_gfx1031 rc=\$rc\"
      if [[ '${DROP_SHELL}' == '1' ]]; then
        echo
        echo '== Shell =='
        exec bash
      fi
      exit \$rc
    " 2>&1 | tee "${docker_cap}"
  rc=${PIPESTATUS[0]}
  set -e
  return "${rc}"
}

extract_tflops() {
  local id="$1"  # "01", "02", ...
  local file="$2"
  local line
  line="$(rg -n "^${id}  " "${file}" | tail -n 1 || true)"
  if [[ -z "${line}" ]]; then
    echo ""
    return 0
  fi
  # PERF column contains "TFLOPS <val>".
  echo "${line}" | sed -nE 's/.*TFLOPS[[:space:]]+([0-9.]+).*/\1/p'
}

extract_energy_line() {
  # prints the Energy line following a summary row, if present
  local id="$1"
  local file="$2"
  awk -v id="${id}" '
    $1 == id {
      getline
      if ($1 == "Energy:") {
        print $0
      }
      exit
    }
  ' "${file}" 2>/dev/null
}

extract_energy_wh() {
  local id="$1"
  local file="$2"
  local line
  line="$(extract_energy_line "${id}" "${file}")"
  echo "${line}" | sed -nE 's/.*Energy:[[:space:]]+([0-9.]+)Wh.*/\1/p'
}

extract_energy_avgw() {
  local id="$1"
  local file="$2"
  local line
  line="$(extract_energy_line "${id}" "${file}")"
  echo "${line}" | sed -nE 's/.*avg[[:space:]]+([0-9.]+)W.*/\1/p'
}

extract_energy_gpu() {
  local id="$1"
  local file="$2"
  local line
  line="$(extract_energy_line "${id}" "${file}")"
  echo "${line}" | sed -nE 's/.*gpu[[:space:]]+([0-9]+)%.*/\1/p'
}

extract_status() {
  local id="$1"
  local file="$2"
  local line
  line="$(rg -n "^${id}  " "${file}" | tail -n 1 || true)"
  echo "${line}" | sed -nE 's/.*[[:space:]](OK|FAIL|SKIP)[[:space:]].*/\1/p'
}

extract_perf_text() {
  local id="$1"
  local file="$2"
  local line
  line="$(rg -n "^${id}  " "${file}" | tail -n 1 || true)"
  # PERF column begins after the time field "<num>s". Keep it short for printing.
  echo "${line}" | sed -nE 's/.*[[:space:]][0-9]+\.[0-9]{3}s[[:space:]]+(.+)$/\1/p'
}

fmt_pct() {
  local a="$1"
  local b="$2"
  if [[ -z "${a}" || -z "${b}" ]]; then
    echo "n/a"
    return 0
  fi
  awk -v a="${a}" -v b="${b}" 'BEGIN{if(a==0){print "n/a"}else{printf "%+.1f%%", (b-a)/a*100.0}}'
}

host_rc=0
docker_rc=0

echo "==== test_docker_gfx1031 plan ===="
echo "- build dir : ${BUILD_DIR}"
echo "- image     : ${IMAGE}"
echo "- mode      : ${MODE} ($( ((BENCH_LITE)) && echo bench-lite || echo bench ))"
echo "- power     : $([[ ${POWER} -eq 1 ]] && echo enabled || echo disabled)"
echo "- host      : $([[ ${DO_HOST} -eq 1 ]] && echo yes || echo no)"
echo "- docker    : $([[ ${DO_DOCKER} -eq 1 ]] && echo yes || echo no)"
echo "- compare   : $([[ ${COMPARE} -eq 1 ]] && echo yes || echo no)"
echo "- logs      : $([[ ${KEEP_LOGS} -eq 1 ]] && echo keep || echo ephemeral)"
echo ""

if (( DO_HOST )); then
  run_host || host_rc=$?
fi
if (( DO_DOCKER )); then
  run_docker || docker_rc=$?
fi

if (( host_rc != 0 )); then
  echo "Host run failed (rc=${host_rc})." >&2
fi
if (( docker_rc != 0 )); then
  echo "Docker run failed (rc=${docker_rc})." >&2
fi

if (( COMPARE )) && (( DO_HOST )) && (( DO_DOCKER )); then
  echo ""
  echo "==== perf comparison (${BUILD_DIR}) ===="
  host_rocblas="$(extract_tflops "01" "${host_cap}")"
  docker_rocblas="$(extract_tflops "01" "${docker_cap}")"
  host_hipblas="$(extract_tflops "02" "${host_cap}")"
  docker_hipblas="$(extract_tflops "02" "${docker_cap}")"

  host_rocblas_wh="$(extract_energy_wh "01" "${host_cap}")"
  docker_rocblas_wh="$(extract_energy_wh "01" "${docker_cap}")"
  host_rocblas_avgw="$(extract_energy_avgw "01" "${host_cap}")"
  docker_rocblas_avgw="$(extract_energy_avgw "01" "${docker_cap}")"
  host_rocblas_gpu="$(extract_energy_gpu "01" "${host_cap}")"
  docker_rocblas_gpu="$(extract_energy_gpu "01" "${docker_cap}")"

  host_hipblas_wh="$(extract_energy_wh "02" "${host_cap}")"
  docker_hipblas_wh="$(extract_energy_wh "02" "${docker_cap}")"
  host_hipblas_avgw="$(extract_energy_avgw "02" "${host_cap}")"
  docker_hipblas_avgw="$(extract_energy_avgw "02" "${docker_cap}")"
  host_hipblas_gpu="$(extract_energy_gpu "02" "${host_cap}")"
  docker_hipblas_gpu="$(extract_energy_gpu "02" "${docker_cap}")"

  printf "%-34s %10s %10s %10s  %8s %8s  %7s %7s  %7s %7s\n" "bench" "hostTF" "dockTF" "ΔTF" "hWh" "dWh" "hW" "dW" "hGPU%" "dGPU%"
  printf "%-34s %10s %10s %10s  %8s %8s  %7s %7s  %7s %7s\n" \
    "rocBLAS GEMM f32" "${host_rocblas:-n/a}" "${docker_rocblas:-n/a}" "$(fmt_pct "${host_rocblas}" "${docker_rocblas}")" \
    "${host_rocblas_wh:-n/a}" "${docker_rocblas_wh:-n/a}" "${host_rocblas_avgw:-n/a}" "${docker_rocblas_avgw:-n/a}" "${host_rocblas_gpu:-n/a}" "${docker_rocblas_gpu:-n/a}"
  printf "%-34s %10s %10s %10s  %8s %8s  %7s %7s  %7s %7s\n" \
    "hipBLAS GEMM f32" "${host_hipblas:-n/a}" "${docker_hipblas:-n/a}" "$(fmt_pct "${host_hipblas}" "${docker_hipblas}")" \
    "${host_hipblas_wh:-n/a}" "${docker_hipblas_wh:-n/a}" "${host_hipblas_avgw:-n/a}" "${docker_hipblas_avgw:-n/a}" "${host_hipblas_gpu:-n/a}" "${docker_hipblas_gpu:-n/a}"

  if (( ! BENCH_LITE )); then
    echo ""
    echo "==== bench suite status (3-9) ===="
    printf "%-34s %-5s %-5s  %s\n" "bench" "host" "dock" "perf (host | docker)"
    for id in 03 04 05 06 07 08 09; do
      hst="$(extract_status "${id}" "${host_cap}")"
      dst="$(extract_status "${id}" "${docker_cap}")"
      # Use the host bench name as the label.
      name="$(rg -n "^${id}  " "${host_cap}" | tail -n 1 | sed -nE 's/^[0-9]{2}[[:space:]]+(.*)[[:space:]]+(OK|FAIL|SKIP)[[:space:]].*/\\1/p' || true)"
      [[ -z "${name}" ]] && name="bench ${id}"
      hperf="$(extract_perf_text "${id}" "${host_cap}")"
      dperf="$(extract_perf_text "${id}" "${docker_cap}")"
      printf "%-34.34s %-5s %-5s  %s\n" "${name}" "${hst:-n/a}" "${dst:-n/a}" "${hperf:-} | ${dperf:-}"
    done
  fi
fi

if (( KEEP_LOGS )); then
  echo ""
  if [[ -n "${LOG_PATH}" ]]; then
    echo "Captured output:"
    if (( DO_HOST )); then echo "- ${host_cap}"; fi
    if (( DO_DOCKER )); then echo "- ${docker_cap}"; fi
  else
    echo "Captured output dir: ${OUT_DIR}"
  fi
else
  rm -rf "${OUT_DIR}"
fi

if (( host_rc != 0 )); then
  exit "${host_rc}"
fi
exit "${docker_rc}"
