#!/bin/bash
set -e

echo "=========================================="
echo "Installing Official Ollama ROCm Build"
echo "=========================================="
echo ""

# Stop existing Ollama service
echo "Stopping Ollama service..."
systemctl --user stop ollama || true
pkill -9 ollama || true
sleep 2
echo "✓ Ollama stopped"
echo ""

# Backup old ollama binary
if [ -f "/usr/local/bin/ollama" ]; then
    echo "Backing up old Ollama binary..."
    sudo mv /usr/local/bin/ollama /usr/local/bin/ollama.backup-$(date +%Y%m%d-%H%M%S)
    echo "✓ Backup created"
fi

# Download official Ollama ROCm build
echo ""
echo "Downloading official Ollama ROCm build..."
cd /tmp
curl -fsSL https://ollama.com/download/ollama-linux-amd64-rocm.tgz -o ollama-rocm.tgz
echo "✓ Download complete"

# Extract
echo ""
echo "Extracting Ollama..."
tar -xzf ollama-rocm.tgz
echo "✓ Extraction complete"

# Install binary
echo ""
echo "Installing Ollama binary..."
sudo install -m 755 bin/ollama /usr/local/bin/ollama
echo "✓ Binary installed"

# Install ROCm libraries
if [ -d "lib/ollama" ]; then
    echo ""
    echo "Installing bundled ROCm libraries..."
    sudo mkdir -p /usr/local/lib/ollama
    sudo cp -r lib/ollama/* /usr/local/lib/ollama/
    echo "✓ Libraries installed"
fi

# Clean up
rm -rf ollama-rocm.tgz bin lib
echo "✓ Cleanup complete"

echo ""
echo "New Ollama version:"
/usr/local/bin/ollama --version

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Now update the Ollama service configuration:"
echo "  systemctl --user daemon-reload"
echo "  systemctl --user start ollama"
echo ""
echo "Check GPU detection:"
echo "  journalctl --user -u ollama -f"
echo ""
