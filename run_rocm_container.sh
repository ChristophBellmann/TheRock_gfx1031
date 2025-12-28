#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${IMAGE:-rocm/dev-ubuntu-24.04:latest}"
BUILD_DIR="${BUILD_DIR:-build-stage2}"
RUN_BENCH=0
BENCH_LITE=0
MODE="quick"
# Default: run tests and exit (non-interactive).
DROP_SHELL=0
NO_TTY=0
LOG_ENABLED=0
LOG_FILE=""
INSTALL_DEPS=0
INSTALL_DEPS_EXPLICIT=0
POWER=0

usage() {
  cat <<'EOF'
Usage: run_rocm_container.sh [options]

Runs repo-local sanity (or benches) inside an ROCm dev container, using the in-tree
dist under <builddir>/dist/rocm (no /opt/rocm required).

Options:
  --stage2           Use BUILD_DIR=build-stage2 (default)
  --stage1           Use BUILD_DIR=build-stage1
  --build-dir <dir>  Override build dir (e.g. build, build-stage2)
  --image <image>    Docker image (default: rocm/dev-ubuntu-24.04:latest)
  --bench            Run ./test_gfx1031.sh --bench
  --bench-lite       Run ./test_gfx1031.sh --bench-lite
  --full             Use longer benchmark sizes (passes --full)
  --power            Enable sysfs power sampling in ./test_gfx1031.sh
  --log [file]       Enable logging (default: run_rocm_container.<builddir>.log)
  --install-deps     Install minimal runtime deps inside the container (e.g. libgfortran5 for bench clients)
  --shell            Drop into an interactive shell after running tests
  --no-tty           Do not allocate a pseudo-TTY (useful for piping/capture)
  -h, --help         Show this help

Env overrides:
  IMAGE              Docker image (default: rocm/dev-ubuntu-24.04:latest)
  BUILD_DIR          Build dir (default: build-stage2)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage2)
      BUILD_DIR="build-stage2"
      shift
      ;;
    --stage1)
      BUILD_DIR="build-stage1"
      shift
      ;;
    --build-dir)
      BUILD_DIR="${2:-}"
      shift 2
      ;;
    --image)
      IMAGE="${2:-}"
      shift 2
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
    --full)
      MODE="full"
      shift
      ;;
    --power)
      POWER=1
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
    --install-deps)
      INSTALL_DEPS=1
      INSTALL_DEPS_EXPLICIT=1
      shift
      ;;
    --shell)
      DROP_SHELL=1
      shift
      ;;
    --no-tty)
      NO_TTY=1
      shift
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

if [[ -z "${BUILD_DIR}" ]]; then
  echo "BUILD_DIR is empty" >&2
  exit 2
fi

# Bench clients in the in-tree dist often depend on runtime libs not present in minimal dev images.
# If the user asked to run benches and did not explicitly override deps behavior, auto-install minimal deps.
if (( RUN_BENCH )) && (( ! INSTALL_DEPS_EXPLICIT )); then
  INSTALL_DEPS=1
fi

cmd=(./test_gfx1031.sh --no-bench)
if (( RUN_BENCH )); then
  if (( BENCH_LITE )); then
    cmd=(./test_gfx1031.sh --bench-lite)
  else
    cmd=(./test_gfx1031.sh --bench)
  fi
  if [[ "${MODE}" == "full" ]]; then
    cmd+=(--full)
  fi
fi
if (( POWER )); then
  cmd+=(--power)
fi

if (( LOG_ENABLED )); then
  if [[ -z "${LOG_FILE}" ]]; then
    LOG_FILE="${ROOT}/run_rocm_container.${BUILD_DIR}.log"
  fi
  # If the log file lives under the repo root, remap to the container's mount point.
  LOG_FILE_CONTAINER="${LOG_FILE}"
  if [[ "${LOG_FILE_CONTAINER}" == "${ROOT}"* ]]; then
    rel="${LOG_FILE_CONTAINER#${ROOT}/}"
    LOG_FILE_CONTAINER="/work/${rel}"
  fi
  cmd+=(--log "${LOG_FILE_CONTAINER}")
fi

cmd_str=""
printf -v cmd_str "%q " "${cmd[@]}"

log_dir=""
if (( LOG_ENABLED )); then
  log_dir="$(dirname "${LOG_FILE_CONTAINER}")"
fi

docker_it=()
if (( ! NO_TTY )) && [[ -t 0 ]] && [[ -t 1 ]]; then
  docker_it=(-it)
fi

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
        # Bench clients often depend on libgfortran at runtime.
        apt-get install -y --no-install-recommends libgfortran5 >/dev/null
      else
        echo 'NOTE: --install-deps requested but apt-get is not available in this image' >&2
      fi
    fi
    echo '== GPU check (container) =='
    if command -v rocminfo >/dev/null 2>&1; then
      # Show a compact summary including the GPU agent.
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
    if (( ${LOG_ENABLED} )); then
      mkdir -p \"${log_dir}\"
    fi
    echo
    echo '== Repo sanity =='
    rc=0
    ${cmd_str} --build-dir \"\$BUILD_DIR\" || rc=\$?
    echo
    echo \"test_gfx1031 rc=\$rc\"
    if [[ '${DROP_SHELL}' == '1' ]]; then
      echo
      echo '== Shell =='
      exec bash
    fi
    exit \$rc
  "
