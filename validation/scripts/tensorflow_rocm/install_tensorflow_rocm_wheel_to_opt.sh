#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_DIR="${SRC_DIR:-${ROOT}/validation/workspace/cache/wheels/tensorflow_rocm_custom}"
DEST_DIR="${DEST_DIR:-/opt/rocm/wheels/tensorflow_rocm_custom}"

WHEEL="$(ls -1t "${SRC_DIR}"/*.whl 2>/dev/null | head -n1 || true)"
if [[ -z "${WHEEL}" ]]; then
  echo "No TensorFlow wheel found in ${SRC_DIR}"
  exit 1
fi

echo "Source: ${WHEEL}"
echo "Target: ${DEST_DIR}"

sudo mkdir -p "${DEST_DIR}"
sudo cp -f "${WHEEL}" "${DEST_DIR}/"

echo "\nSHA256:"
sha256sum "${WHEEL}" "${DEST_DIR}/$(basename "${WHEEL}")"

ls -lh "${DEST_DIR}/$(basename "${WHEEL}")"
