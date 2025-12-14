#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Optional helper for giving the current shell priority under OOM situations.
# Runs `sudo echo -1000 > /proc/$$/oom_score_adj`. If you have NOPASSWD sudo
# configured or already authenticated, it will succeed without asking. Otherwise
# you can set SUDO_PASSWORD before invoking this script.

if [ -n "${SUDO_PASSWORD-}" ]; then
    echo "$SUDO_PASSWORD" | sudo -S sh -c "echo -1000 > /proc/$$/oom_score_adj" 2>/dev/null && \
        echo "✓ OOM protection enabled (from env password)" || \
        echo "⚠ Warning: Could not enable OOM protection (continuing anyway)"
else
    sudo sh -c "echo -1000 > /proc/$$/oom_score_adj" 2>/dev/null && \
        echo "✓ OOM protection enabled" || \
        echo "⚠ Warning: Could not enable OOM protection (continuing anyway)"
fi
