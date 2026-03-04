#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_DIR="${SRC_DIR:-${ROOT}/validation/workspace/cache/wheels/onnxruntime_rocm711}"
DEST_DIR="${DEST_DIR:-/opt/rocm/wheels/onnxruntime_rocm711}"
TS="$(date +%Y%m%d_%H%M%S)"

usage() {
  echo "Usage:"
  echo "  $0 [path/to/onnxruntime_rocm-*.whl]"
  echo "  $0 --restore [onnxruntime_rocm-*.whl]"
}

find_latest_wheel() {
  ls -1t "${SRC_DIR}"/onnxruntime_rocm-*.whl 2>/dev/null | head -n1 || true
}

restore_latest_backup() {
  local wheel_name="$1"
  local target="${DEST_DIR}/${wheel_name}"
  local latest
  latest="$(ls -1t "${target}".bak_* 2>/dev/null | head -n1 || true)"
  if [[ -z "${latest}" ]]; then
    echo "No backup found for ${target}" >&2
    exit 1
  fi
  echo "Restoring backup:"
  echo "  from: ${latest}"
  echo "  to:   ${target}"
  sudo cp -f "${latest}" "${target}"
  sudo sha256sum "${target}"
  ls -lh "${target}"
}

MODE="install"
SRC_WHEEL=""

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--restore" ]]; then
  MODE="restore"
  if [[ -n "${2:-}" ]]; then
    WHEEL_NAME="$(basename "${2}")"
  else
    LATEST="$(find_latest_wheel)"
    if [[ -z "${LATEST}" ]]; then
      echo "No wheel found in ${SRC_DIR}" >&2
      exit 1
    fi
    WHEEL_NAME="$(basename "${LATEST}")"
  fi
  restore_latest_backup "${WHEEL_NAME}"
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  SRC_WHEEL="${1}"
else
  SRC_WHEEL="$(find_latest_wheel)"
fi

if [[ -z "${SRC_WHEEL}" || ! -f "${SRC_WHEEL}" ]]; then
  echo "Source wheel not found: ${SRC_WHEEL:-<empty>}" >&2
  echo "Checked SRC_DIR=${SRC_DIR}" >&2
  usage >&2
  exit 1
fi

DEST_WHEEL="${DEST_DIR}/$(basename "${SRC_WHEEL}")"

echo "Source: ${SRC_WHEEL}"
echo "Target: ${DEST_WHEEL}"

sudo mkdir -p "${DEST_DIR}"

if [[ -f "${DEST_WHEEL}" ]]; then
  BACKUP="${DEST_WHEEL}.bak_${TS}"
  echo "Backup: ${BACKUP}"
  sudo cp -f "${DEST_WHEEL}" "${BACKUP}"
fi

sudo cp -f "${SRC_WHEEL}" "${DEST_WHEEL}"

echo
echo "SHA256:"
sha256sum "${SRC_WHEEL}"
sudo sha256sum "${DEST_WHEEL}"

echo
echo "Installed wheel:"
ls -lh "${DEST_WHEEL}"
