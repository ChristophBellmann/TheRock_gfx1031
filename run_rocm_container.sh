#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${IMAGE:-rocm/dev-ubuntu-22.04:latest}"
BUILD_DIR="${BUILD_DIR:-build-stage2}"
RUN_BENCH=0
DROP_SHELL=1

usage() {
  cat <<'EOF'
Usage: run_rocm_container.sh [options]

Runs repo-local sanity (or benches) inside an ROCm dev container, using the in-tree
dist under <builddir>/dist/rocm (no /opt/rocm required).

Options:
  --stage2           Use BUILD_DIR=build-stage2 (default)
  --stage1           Use BUILD_DIR=build-stage1
  --build-dir <dir>  Override build dir (e.g. build, build-stage2)
  --bench            Run ./test_gfx1031.sh --bench
  --no-shell         Exit after running tests (default: drop into bash)
  -h, --help         Show this help

Env overrides:
  IMAGE              Docker image (default: rocm/dev-ubuntu-22.04:latest)
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
    --bench)
      RUN_BENCH=1
      shift
      ;;
    --no-shell)
      DROP_SHELL=0
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

cmd=(./test_gfx1031.sh --no-bench)
if (( RUN_BENCH )); then
  cmd=(./test_gfx1031.sh --bench)
fi

docker run --rm -it \
  --device=/dev/kfd --device=/dev/dri \
  --group-add video --group-add render \
  --security-opt seccomp=unconfined \
  -v "${ROOT}:/work:rw" \
  -w /work \
  "${IMAGE}" \
  bash -lc "
    set -euo pipefail
    echo '== GPU check (container) =='
    if command -v rocminfo >/dev/null 2>&1; then rocminfo | head -n 60 || true; else echo 'rocminfo not found in image'; fi
    echo
    echo '== Activate in-tree ROCm (${BUILD_DIR}) =='
    export BUILD_DIR='${BUILD_DIR}'
    export ROCM_PATH=\"\$PWD/\$BUILD_DIR/dist/rocm\"
    export PATH=\"\$ROCM_PATH/bin:\$ROCM_PATH/llvm/bin:\$PATH\"
    export LD_LIBRARY_PATH=\"\$ROCM_PATH/lib:\$ROCM_PATH/lib64:\$ROCM_PATH/lib/host-math/lib:\$ROCM_PATH/lib/rocm_sysdeps/lib:\$ROCM_PATH/llvm/lib:\${LD_LIBRARY_PATH:-}\"
    export TEST_SKIP_VENV=1
    echo \"ROCM_PATH=\$ROCM_PATH\"
    echo
    echo '== Repo sanity =='
    rc=0
    ${cmd[*]} --build-dir \"\$BUILD_DIR\" || rc=\$?
    echo
    echo \"test_gfx1031 rc=\$rc\"
    if [[ '${DROP_SHELL}' == '1' ]]; then
      echo
      echo '== Shell =='
      exec bash
    fi
    exit \$rc
  "

