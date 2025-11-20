#!/bin/bash
# Install xxd which is needed for building ROCr runtime

echo "Installing xxd (part of vim-common)..."
sudo dnf install -y vim-common

if command -v xxd &> /dev/null; then
    echo "✓ xxd installed successfully!"
    xxd --version
else
    echo "✗ Failed to install xxd"
    exit 1
fi
