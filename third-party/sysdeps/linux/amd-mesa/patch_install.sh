#!/bin/bash
# Patches installed binaries from the external build system.
# Args: install_dir patchelf_binary
set -e

PREFIX="${1:?Expected install prefix argument}"
PATCHELF="${PATCHELF:-patchelf}"
THEROCK_SOURCE_DIR="${THEROCK_SOURCE_DIR:?THEROCK_SOURCE_DIR not defined}"

if [ -z "${Python3_EXECUTABLE:-}" ]; then
  Python3_EXECUTABLE="$(command -v python3)"
fi

if [ -z "${Python3_EXECUTABLE}" ]; then
  echo "Python3 executable not found (set Python3_EXECUTABLE)" >&2
  exit 1
fi

"$Python3_EXECUTABLE" "$THEROCK_SOURCE_DIR/build_tools/patch_linux_so.py" \
  --patchelf "${PATCHELF}" --add-prefix rocm_sysdeps_ \
  $PREFIX/lib/libgallium_drv_video.so \
  $PREFIX/lib/libva.so \
  $PREFIX/lib/libva-drm.so
