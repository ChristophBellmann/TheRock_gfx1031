#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

BUILD_DIR="${BUILD_DIR:-build-stage2}"
PREFIX="${PREFIX:-/opt/rocm}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/rocm_backups}"
WHEEL_GLOB_DEFAULT="/tmp/therock_torch_wheels_custom_rocm/torch-*.whl"
WHEEL_GLOB="${WHEEL_GLOB:-$WHEEL_GLOB_DEFAULT}"
ORT_WHEEL_GLOB_DEFAULT="${ROOT}/validation/workspace/cache/wheels/onnxruntime_rocm711/onnxruntime_rocm-*.whl"
ORT_WHEEL_GLOB="${ORT_WHEEL_GLOB:-$ORT_WHEEL_GLOB_DEFAULT}"
DO_VALIDATE="${DO_VALIDATE:-1}"

echo "== system_install_with_backup.sh =="
echo "repo      : ${ROOT}"
echo "build dir : ${BUILD_DIR}"
echo "prefix    : ${PREFIX}"
echo "backup    : ${BACKUP_ROOT}"
echo "wheel glob: ${WHEEL_GLOB}"
echo "ort wheel glob: ${ORT_WHEEL_GLOB}"
echo ""

if [[ ! -x "${ROOT}/install_to_opt.sh" ]]; then
  echo "ERROR: install_to_opt.sh not found or not executable in ${ROOT}" >&2
  exit 1
fi

if ! compgen -G "${WHEEL_GLOB}" >/dev/null; then
  echo "ERROR: no wheel found matching ${WHEEL_GLOB}" >&2
  exit 1
fi
WHEEL="$(ls -1 ${WHEEL_GLOB} | tail -n 1)"
echo "Using wheel: ${WHEEL}"

ORT_WHEEL=""
if compgen -G "${ORT_WHEEL_GLOB}" >/dev/null; then
  ORT_WHEEL="$(ls -1 ${ORT_WHEEL_GLOB} | tail -n 1)"
  echo "Using ONNX Runtime wheel: ${ORT_WHEEL}"
else
  echo "INFO: no ONNX Runtime wheel found matching ${ORT_WHEEL_GLOB} (install continues without ORT wheel copy)"
fi

TS="$(date +%F-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TS}"
echo "Backup dir: ${BACKUP_DIR}"

echo ""
echo "== Backup current install =="
sudo mkdir -p "${BACKUP_DIR}"
if [[ -d "${PREFIX}" ]]; then
  sudo rsync -aH --delete "${PREFIX}/" "${BACKUP_DIR}/rocm/"
else
  echo "INFO: ${PREFIX} does not exist yet, skipping prefix backup"
fi

if [[ -f /etc/ld.so.conf.d/rocm.conf ]]; then
  sudo install -D -m 0644 /etc/ld.so.conf.d/rocm.conf "${BACKUP_DIR}/etc/ld.so.conf.d/rocm.conf"
else
  echo "INFO: /etc/ld.so.conf.d/rocm.conf not present"
fi

if [[ -f /etc/OpenCL/vendors/amdocl64.icd ]]; then
  sudo install -D -m 0644 /etc/OpenCL/vendors/amdocl64.icd "${BACKUP_DIR}/etc/OpenCL/vendors/amdocl64.icd"
else
  echo "INFO: /etc/OpenCL/vendors/amdocl64.icd not present"
fi

echo ""
echo "== Install new prefix =="
INSTALL_ARGS=(
  --build-dir "${BUILD_DIR}"
  --prefix "${PREFIX}"
  --pytorch-wheel "${WHEEL}"
  -y
)
if [[ -n "${ORT_WHEEL}" ]]; then
  INSTALL_ARGS+=(--onnxruntime-wheel "${ORT_WHEEL}")
fi
sudo "${ROOT}/install_to_opt.sh" "${INSTALL_ARGS[@]}"

if [[ "${DO_VALIDATE}" == "1" ]]; then
  echo ""
  echo "== Post-install validation =="
  if [[ -x "${PREFIX}/bin/rocminfo" ]]; then
    "${PREFIX}/bin/rocminfo" | head -n 30 || true
  fi
  if [[ -x "${PREFIX}/bin/hipcc" ]]; then
    "${PREFIX}/bin/hipcc" --version || true
  fi
  echo "Wheel dir:"
  ls -1 "${PREFIX}/wheels/pytorch_rocm711/" || true
  echo "ONNX Runtime wheel dir:"
  ls -1 "${PREFIX}/wheels/onnxruntime_rocm711/" || true
fi

echo ""
echo "Done."
echo "Backup saved at: ${BACKUP_DIR}"
