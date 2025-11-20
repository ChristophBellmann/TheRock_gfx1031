#!/bin/bash
# Script to install ROCm to /opt/rocm and configure system

set -e

echo "Installing ROCm to /opt/rocm..."
sudo cmake --build build --target install

echo ""
echo "Setting up ldconfig..."
sudo cp rocm-ldconfig.conf /etc/ld.so.conf.d/rocm.conf
sudo ldconfig

echo ""
echo "Setting up system-wide environment variables..."
sudo cp rocm-env.sh /etc/profile.d/rocm.sh
sudo chmod +x /etc/profile.d/rocm.sh

echo ""
echo "Verifying installation..."
if [ -f /opt/rocm/bin/hipcc ]; then
    echo "✓ hipcc installed to /opt/rocm/bin/hipcc"
    /opt/rocm/bin/hipcc --version
else
    echo "✗ hipcc not found in /opt/rocm/bin/"
    exit 1
fi

echo ""
echo "Installation complete!"
echo ""
echo "To use ROCm in current shell, run:"
echo "  source /etc/profile.d/rocm.sh"
echo ""
echo "Or start a new shell session."
echo ""
echo "To verify GPU detection:"
echo "  /opt/rocm/bin/rocminfo"
