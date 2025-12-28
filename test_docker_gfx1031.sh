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

Runs repo-local benchmarks (bench suite 1–9; power optional) against the in-tree dist under <builddir>/dist/rocm:
- on the host
- in a ROCm dev docker image (mounted repo + /dev/kfd,/dev/dri)

Default behavior:
  - bench-only (suite 1-9; skips missing tools) with power enabled
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
# For perf comparison, we want stable 1–9 IDs without rocminfo/hipinfo shifting
# the numbering. `test_gfx1031.sh --bench-only` provides that.
bench_args+=(--bench-only)
if (( BENCH_LITE )); then
  bench_args+=(--bench-lite)
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
  local id="$1"
  local file="$2"
  local line
  line="$(rg -n "^${id}  " "${file}" | tail -n 1 || true)"
  [[ -z "${line}" ]] && { echo ""; return 0; }
  echo "${line}" | awk '
    {
      for(i=1;i<=NF;i++){
        if($i=="TFLOPS" && (i+1)<=NF){ print $(i+1); exit }
      }
    }'
}

extract_status_by_id() {
  local id="$1"
  local file="$2"
  local line
  line="$(rg -n "^${id}  " "${file}" | tail -n 1 || true)"
  [[ -z "${line}" ]] && { echo ""; return 0; }
  echo "${line}" | awk '
    {
      for(i=2;i<=NF;i++){
        if($i ~ /^(OK|FAIL|SKIP)$/ && $(i+1) ~ /^[0-9]+\.[0-9]{3}s$/){ print $i; exit }
      }
    }'
}

extract_time_by_id() {
  local id="$1"
  local file="$2"
  local line
  line="$(rg -n "^${id}  " "${file}" | tail -n 1 || true)"
  [[ -z "${line}" ]] && { echo ""; return 0; }
  echo "${line}" | awk '
    {
      for(i=2;i<=NF;i++){
        if($i ~ /^(OK|FAIL|SKIP)$/ && $(i+1) ~ /^[0-9]+\.[0-9]{3}s$/){ print $(i+1); exit }
      }
    }'
}

extract_perf_by_id() {
  local id="$1"
  local file="$2"
  local line
  line="$(rg -n "^${id}  " "${file}" | tail -n 1 || true)"
  [[ -z "${line}" ]] && { echo ""; return 0; }
  echo "${line}" | awk '
    {
      for(i=2;i<=NF;i++){
        if($i ~ /^(OK|FAIL|SKIP)$/ && $(i+1) ~ /^[0-9]+\.[0-9]{3}s$/){
          out=""
          for(j=i+2;j<=NF;j++){
            if(out!=""){ out=out " " }
            out=out $j
          }
          print out
          exit
        }
      }
    }'
}

extract_energy_line() {
  # prints the Energy line following a summary row, if present
  local id="$1"
  local file="$2"
  awk -v id="${id}" '
    $1 == id {
      getline
      if ($1 == "Energy:" || $1 ~ /^[[:space:]]*Energy:$/) {
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
  echo "==== perf comparison (host vs docker) ===="
  echo "- build dir: ${BUILD_DIR}"
  echo "- mode     : $( ((BENCH_LITE)) && echo "bench-lite (1-2)" || echo "bench (1-9)" )"
  echo ""

  bench_names=()
  bench_names+=("rocBLAS GEMM f32")
  bench_names+=("hipBLAS GEMM f32")
  if (( ! BENCH_LITE )); then
    bench_names+=("rocSOLVER geqrf_strided_batched (d)")
    bench_names+=("hipSOLVER (tiny solver)")
    bench_names+=("rocSPARSE axpyi (d)")
    bench_names+=("hipSPARSE axpyi (d)")
    bench_names+=("rocFFT complex fwd (262144, batch=4, d)")
    bench_names+=("dyna-rocFFT complex fwd (262144, batch=4, d)")
    bench_names+=("rocRAND generate (philox, uniform-float)")
  fi

  printf "%-3s %-38s %-5s %-9s %-30s  %-5s %-9s %-30s\n" "ID" "bench" "hST" "hTIME" "hPERF" "dST" "dTIME" "dPERF"
  printf "%s\n" "---------------------------------------------------------------------------------------------------------------------------"
  i=1
  for bench in "${bench_names[@]}"; do
    id="$(printf "%02d" "${i}")"
    hst="$(extract_status_by_id "${id}" "${host_cap}")"
    dst="$(extract_status_by_id "${id}" "${docker_cap}")"
    htime="$(extract_time_by_id "${id}" "${host_cap}")"
    dtime="$(extract_time_by_id "${id}" "${docker_cap}")"
    hperf="$(extract_perf_by_id "${id}" "${host_cap}")"
    dperf="$(extract_perf_by_id "${id}" "${docker_cap}")"
    printf "%-3s %-38.38s %-5s %-9s %-30.30s  %-5s %-9s %-30.30s\n" \
      "${id}" "${bench}" "${hst:-n/a}" "${htime:-n/a}" "${hperf:-}" "${dst:-n/a}" "${dtime:-n/a}" "${dperf:-}"

    # Power line (if available)
    hwh="$(extract_energy_wh "${id}" "${host_cap}")"
    dwh="$(extract_energy_wh "${id}" "${docker_cap}")"
    hw="$(extract_energy_avgw "${id}" "${host_cap}")"
    dw="$(extract_energy_avgw "${id}" "${docker_cap}")"
    hgpu="$(extract_energy_gpu "${id}" "${host_cap}")"
    dgpu="$(extract_energy_gpu "${id}" "${docker_cap}")"
    if [[ -n "${hwh}${dwh}${hw}${dw}${hgpu}${dgpu}" ]]; then
      printf "    %-38s  hWh %-7s hW %-6s hGPU %-4s   dWh %-7s dW %-6s dGPU %-4s\n" \
        "power" "${hwh:-n/a}" "${hw:-n/a}" "${hgpu:-n/a}%" "${dwh:-n/a}" "${dw:-n/a}" "${dgpu:-n/a}%"
    fi
    echo ""
    i=$((i+1))
  done
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
