#!/bin/bash
# ROCm Environment Switcher for RX 6700 XT (gfx1031)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_usage() {
    cat << EOF
ROCm Environment Switcher for AMD RX 6700 XT (gfx1031)

Usage: source $0 [mode]

Modes:
  native    - Use native gfx1031 (for building from source: llama.cpp, TheRock)
  compat    - Use gfx1030 override (for pre-built binaries: ollama, lmstudio)
  check     - Show current GPU and HSA configuration

Examples:
  source $0 native   # Switch to native gfx1031
  source $0 compat   # Switch to compatibility mode (gfx1030 override)
  source $0 check    # Check current configuration

EOF
}

check_gpu() {
    echo "=== GPU Information ==="
    if command -v rocm-smi &> /dev/null; then
        rocm-smi --showproductname 2>/dev/null | grep -E "(Card Series|GFX Version)"
    fi

    echo ""
    echo "=== Current HSA Configuration ==="
    if [ -n "$HSA_OVERRIDE_GFX_VERSION" ]; then
        echo "HSA_OVERRIDE_GFX_VERSION: $HSA_OVERRIDE_GFX_VERSION (overriding to gfx1030)"
    else
        echo "HSA_OVERRIDE_GFX_VERSION: (not set - using native gfx1031)"
    fi

    echo ""
    echo "=== Recommended Usage ==="
    echo "• Native mode (no override): llama.cpp builds, TheRock, custom HIP apps"
    echo "• Compat mode (gfx1030): ollama, lmstudio, pre-built binaries"
}

if [ "$1" = "check" ]; then
    check_gpu
    return 0 2>/dev/null || exit 0
fi

if [ "$1" = "native" ]; then
    source "$SCRIPT_DIR/rocm-env-native.sh"
    return 0 2>/dev/null || exit 0
elif [ "$1" = "compat" ]; then
    source "$SCRIPT_DIR/rocm-env-compat.sh"
    return 0 2>/dev/null || exit 0
else
    show_usage
    return 1 2>/dev/null || exit 1
fi
