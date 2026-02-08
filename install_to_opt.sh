#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD_DIR="${BUILD_DIR:-build-stage2}"
SRC_PREFIX="${SRC_PREFIX:-}"
PREFIX="${PREFIX:-/opt/rocm}"
PYTORCH_WHEEL="${PYTORCH_WHEEL:-}"
DO_PYTORCH_WHEEL=1
DO_DELETE=1
DO_LDCONFIG=1
DO_CHECK=1
DO_DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: install_to_opt.sh [options]

Installs the in-tree ROCm dist prefix to a system prefix (default: /opt/rocm).
This script is intentionally separate from building: it copies an existing dist.

Default:
  - source:  <repo>/<build-dir>/dist/rocm  (default build-dir: build-stage2)
  - dest:    /opt/rocm
  - rsync mirror with --delete (avoids mixed/contaminated installs)
  - installs an ldconfig snippet and runs ldconfig
  - runs a quick post-install check (rocminfo, hipcc --version)

Options:
  --build-dir <dir>     Build dir containing dist/rocm (default: build-stage2)
  --src-prefix <path>   Override source prefix (must contain bin/, lib/, include/)
  --prefix <path>       Destination prefix (default: /opt/rocm)
  --pytorch-wheel <path>
                       Also copy this custom-built torch wheel into <prefix>/wheels/pytorch_rocm711/
                       (default: auto-discover in validation cache; best-effort)
  --no-pytorch-wheel    Do not copy the custom torch wheel
  --no-delete           Do not delete extra files in destination
  --no-ldconfig         Do not write /etc/ld.so.conf.d snippet, do not run ldconfig
  --no-check            Do not run post-install checks
  --dry-run             Print what would happen (rsync --dry-run)
  -y, --yes             Do not prompt
  -h, --help            Show help

Notes:
  - This does not "build from scratch". If you want a clean rebuild first:
      ./build_gfx1031.sh configure --stage2 && ./build_gfx1031.sh build --stage2
EOF
}

require_cmd() {
  local exe="$1"
  if ! command -v "${exe}" >/dev/null 2>&1; then
    echo "ERROR: '${exe}' not found. Install it and retry." >&2
    exit 1
  fi
}

need_sudo() {
  # Returns 0 if we should use sudo for writes to PREFIX and /etc.
  if [[ "${EUID}" -eq 0 ]]; then
    return 1
  fi
  if [[ -w "${PREFIX}" ]] || [[ -w "$(dirname "${PREFIX}")" ]]; then
    # PREFIX (or parent) is writable without root.
    return 1
  fi
  return 0
}

confirm() {
  local msg="$1"
  if (( ASSUME_YES )); then
    return 0
  fi
  read -r -p "${msg} [Y/n] " ans
  case "${ans}" in
    ""|Y|y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)
      BUILD_DIR="${2:-}"
      shift 2
      ;;
    --src-prefix)
      SRC_PREFIX="${2:-}"
      shift 2
      ;;
    --prefix)
      PREFIX="${2:-}"
      shift 2
      ;;
    --pytorch-wheel)
      PYTORCH_WHEEL="${2:-}"
      shift 2
      ;;
    --no-pytorch-wheel)
      DO_PYTORCH_WHEEL=0
      shift
      ;;
    --no-delete)
      DO_DELETE=0
      shift
      ;;
    --no-ldconfig)
      DO_LDCONFIG=0
      shift
      ;;
    --no-check)
      DO_CHECK=0
      shift
      ;;
    --dry-run)
      DO_DRY_RUN=1
      shift
      ;;
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      echo "Run: ./install_to_opt.sh --help" >&2
      exit 2
      ;;
  esac
done

require_cmd rsync

if [[ -z "${SRC_PREFIX}" ]]; then
  SRC_PREFIX="${ROOT}/${BUILD_DIR}/dist/rocm"
fi

if [[ ! -d "${SRC_PREFIX}/bin" || ! -d "${SRC_PREFIX}/lib" || ! -d "${SRC_PREFIX}/include" ]]; then
  echo "ERROR: Source prefix does not look like a ROCm dist: ${SRC_PREFIX}" >&2
  echo "Expected at least: bin/, lib/, include/" >&2
  echo "" >&2
  echo "Hint: build Stage-2 first:" >&2
  echo "  ./build_gfx1031.sh build --stage2" >&2
  exit 1
fi

src_size="$(du -sh "${SRC_PREFIX}" 2>/dev/null | awk '{print $1}' || true)"
echo "== TheRock install =="
echo "source : ${SRC_PREFIX} ${src_size:+(${src_size})}"
echo "dest   : ${PREFIX}"
mode="rsync mirror"
if (( DO_DELETE )); then
  mode="${mode} (with --delete)"
fi
if (( DO_DRY_RUN )); then
  mode="${mode} (dry-run)"
fi
echo "mode   : ${mode}"
echo "ldconfig: $([[ ${DO_LDCONFIG} -eq 1 ]] && echo yes || echo no)"
echo "check  : $([[ ${DO_CHECK} -eq 1 ]] && echo yes || echo no)"
echo "pytorch wheel: $([[ ${DO_PYTORCH_WHEEL} -eq 1 ]] && echo best-effort || echo no)"
echo ""

if ! confirm "Proceed with install to '${PREFIX}'?"; then
  echo "Aborted."
  exit 0
fi

SUDO=""
if need_sudo; then
  SUDO="sudo"
fi

RSYNC_ARGS=(-aH --numeric-ids --info=stats2,progress2)
if (( DO_DELETE )); then
  RSYNC_ARGS+=(--delete)
fi
# Keep extras across mirror runs (wheels are not part of the ROCm dist).
RSYNC_ARGS+=(--exclude 'wheels/')
if (( DO_DRY_RUN )); then
  RSYNC_ARGS+=(--dry-run)
fi

${SUDO} mkdir -p "${PREFIX}"
${SUDO} rsync "${RSYNC_ARGS[@]}" "${SRC_PREFIX}/" "${PREFIX}/"

if (( DO_PYTORCH_WHEEL )); then
  # Best-effort: copy a custom torch wheel (built against in-tree ROCm 7.11)
  # into the system prefix for easy per-project installs.
  if [[ -z "${PYTORCH_WHEEL}" ]]; then
    PYTORCH_WHEEL="$(ls -1t "${ROOT}/validation/workspace/cache/wheels/pytorch_rocm711"/torch-*.whl 2>/dev/null | head -n 1 || true)"
    if [[ -z "${PYTORCH_WHEEL}" ]]; then
      PYTORCH_WHEEL="$(ls -1t "${ROOT}/validation/workspace/cache/git/pytorch_rocm711/dist"/torch-*.whl 2>/dev/null | head -n 1 || true)"
    fi
  fi
  if [[ -n "${PYTORCH_WHEEL}" && -f "${PYTORCH_WHEEL}" ]]; then
    wheel_dir="${PREFIX}/wheels/pytorch_rocm711"
    echo ""
    echo "== PyTorch wheel =="
    echo "wheel  : ${PYTORCH_WHEEL}"
    echo "dest   : ${wheel_dir}/"
    ${SUDO} mkdir -p "${wheel_dir}"
    if (( DO_DRY_RUN )); then
      ${SUDO} rsync -a --dry-run --info=stats2 "${PYTORCH_WHEEL}" "${wheel_dir}/"
    else
      ${SUDO} rsync -a --info=stats2 "${PYTORCH_WHEEL}" "${wheel_dir}/"
    fi
  else
    echo ""
    echo "WARN: No custom torch wheel found. Skipping wheel copy."
    echo "      Build it via:"
    echo "        python3 validation/scripts/validate.py --profile pytorch_rocm711_source --build-dirs ${BUILD_DIR} --yes --power --log"
  fi
fi

if (( DO_LDCONFIG )); then
  ldconf_path="/etc/ld.so.conf.d/rocm.conf"
  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
# ROCm library paths for ldconfig (TheRock in-tree dist)
${PREFIX}/lib
${PREFIX}/lib64
${PREFIX}/lib/llvm/lib
${PREFIX}/lib/host-math/lib
${PREFIX}/lib/rocm_sysdeps/lib
EOF
  ${SUDO} install -m 0644 "${tmp}" "${ldconf_path}"
  rm -f "${tmp}"
  if (( ! DO_DRY_RUN )); then
    ${SUDO} ldconfig
  fi
fi

if (( DO_CHECK )); then
  echo ""
  echo "== Post-install checks =="
  if (( DO_DRY_RUN )); then
    echo "(dry-run) Skipping binary execution checks."
  else
    if [[ -x "${PREFIX}/bin/rocminfo" ]]; then
      "${PREFIX}/bin/rocminfo" | head -n 40 || true
    else
      echo "WARN: ${PREFIX}/bin/rocminfo not found"
    fi
    if [[ -x "${PREFIX}/bin/hipcc" ]]; then
      "${PREFIX}/bin/hipcc" --version || true
    else
      echo "WARN: ${PREFIX}/bin/hipcc not found"
    fi
  fi
fi

echo ""
echo "Install complete."
echo "To use it in your shell:"
echo "  export ROCM_PATH='${PREFIX}'"
echo "  export PATH=\"\\$ROCM_PATH/bin:\\$ROCM_PATH/llvm/bin:\\$PATH\""
if (( DO_PYTORCH_WHEEL )); then
  echo ""
  echo "Custom PyTorch wheel (if copied):"
  echo "  ls -1 '${PREFIX}/wheels/pytorch_rocm711/'"
  echo "  python3 -m venv .venv && source .venv/bin/activate"
  echo "  python -m pip install '${PREFIX}/wheels/pytorch_rocm711/'/torch-*.whl"
fi
