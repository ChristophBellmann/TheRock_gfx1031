#!/usr/bin/env bash
# Build script for low memory systems
# This limits parallelism to prevent OOM

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Protect this shell from OOM killer (optional - requires sudo)
# -1000 makes it very unlikely to be killed (range is -1000 to +1000)
if [ -n "$SUDO_PASSWORD" ]; then
    echo "$SUDO_PASSWORD" | sudo -S sh -c "echo -1000 > /proc/$$/oom_score_adj" 2>/dev/null && echo "✓ OOM protection enabled" || echo "⚠ Warning: Could not enable OOM protection (continuing anyway)"
else
    # Try without password (if user has NOPASSWD sudo or already authenticated)
    sudo sh -c "echo -1000 > /proc/$$/oom_score_adj" 2>/dev/null && echo "✓ OOM protection enabled" || echo "⚠ Warning: Could not enable OOM protection (continuing anyway)"
fi

# Activate virtual environment
VENV_ACTIVATE="${VENV_ACTIVATE:-$SCRIPT_DIR/.venv/bin/activate}"
if [ ! -f "$VENV_ACTIVATE" ]; then
    echo "ERROR: virtualenv activation script not found at $VENV_ACTIVATE"
    exit 1
fi
source "$VENV_ACTIVATE"

# Set memory limits per process (in KB)
# Limit each process to ~8GB to prevent single process from consuming all memory
ulimit -v 8388608 || echo "Warning: Could not set memory limit"

# Force single-threaded linking for LLVM to reduce memory spikes
export LLVM_PARALLEL_LINK_JOBS=1

# Allow overriding the job count; default to all available cores
JOBS="${BUILD_JOBS:-$(nproc)}"

echo "Building with -j$JOBS and OOM protections enabled..."
nice -n 10 cmake --build build -j"$JOBS" -- -l"$JOBS" "$@"
