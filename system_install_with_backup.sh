#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

BUILD_DIR="${BUILD_DIR:-build-stage2}"
PREFIX="${PREFIX:-/opt/rocm}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/rocm_backups}"
WHEEL_GLOB_DEFAULT="/tmp/therock_torch_wheels_custom_rocm/torch-*.whl"
WHEEL_GLOB="${WHEEL_GLOB:-$WHEEL_GLOB_DEFAULT}"
DO_VALIDATE="${DO_VALIDATE:-1}"

echo "== system_install_with_backup.sh =="
echo "repo      : ${ROOT}"
echo "build dir : ${BUILD_DIR}"
echo "prefix    : ${PREFIX}"
echo "backup    : ${BACKUP_ROOT}"
echo "wheel glob: ${WHEEL_GLOB}"
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
sudo "${ROOT}/install_to_opt.sh" \
  --build-dir "${BUILD_DIR}" \
  --prefix "${PREFIX}" \
  --pytorch-wheel "${WHEEL}" \
  -y

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
fi

echo ""
echo "Done."
echo "Backup saved at: ${BACKUP_DIR}"
