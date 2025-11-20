#!/bin/bash
set -e

echo "=========================================="
echo "Updating Ollama for ROCm"
echo "=========================================="
echo ""

# Check if ROCm is installed
if [ ! -d "/opt/rocm" ]; then
    echo "ERROR: /opt/rocm not found. Run install_to_opt_rocm.sh first."
    exit 1
fi

# Check if Ollama is installed
if ! command -v ollama &> /dev/null; then
    echo "ERROR: Ollama not found. Please install Ollama first."
    exit 1
fi

echo "Current Ollama location: $(which ollama)"
echo "Current Ollama version: $(ollama --version)"
echo ""

# Stop Ollama service if running
echo "Stopping Ollama service..."
if systemctl --user is-active --quiet ollama 2>/dev/null; then
    systemctl --user stop ollama
    echo "✓ User Ollama service stopped"
elif sudo systemctl is-active --quiet ollama 2>/dev/null; then
    sudo systemctl stop ollama
    echo "✓ System Ollama service stopped"
else
    echo "✓ No running Ollama service found"
fi

# Kill any running ollama processes
if pgrep -x ollama > /dev/null; then
    echo "Killing existing Ollama processes..."
    pkill -9 ollama || true
    sleep 2
    echo "✓ Ollama processes terminated"
fi

# Create Ollama systemd service with ROCm environment
echo ""
echo "Creating Ollama systemd service with ROCm support..."

# Create user service directory if it doesn't exist
mkdir -p ~/.config/systemd/user

# Create service file
tee ~/.config/systemd/user/ollama.service > /dev/null << 'EOF'
[Unit]
Description=Ollama Service with ROCm Support
After=network-online.target

[Service]
Type=exec
ExecStart=/usr/local/bin/ollama serve
Environment="ROCM_PATH=/opt/rocm"
Environment="HIP_PATH=/opt/rocm"
Environment="PATH=/opt/rocm/bin:/usr/local/bin:/usr/bin:/bin"
Environment="LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64"
Environment="HSA_OVERRIDE_GFX_VERSION="
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

echo "✓ Service file created at ~/.config/systemd/user/ollama.service"

# Reload systemd and enable service
echo ""
echo "Reloading systemd and enabling service..."
systemctl --user daemon-reload
systemctl --user enable ollama.service
echo "✓ Service enabled"

# Start the service
echo ""
echo "Starting Ollama service..."
systemctl --user start ollama.service
sleep 3

# Check status
if systemctl --user is-active --quiet ollama.service; then
    echo "✓ Ollama service is running"
else
    echo "⚠ Warning: Ollama service may not have started correctly"
    echo "Check status with: systemctl --user status ollama.service"
fi

echo ""
echo "=========================================="
echo "Ollama Updated Successfully!"
echo "=========================================="
echo ""
echo "Ollama is now configured to use TheRock ROCm with native gfx1031 support"
echo ""
echo "Useful commands:"
echo "  systemctl --user status ollama   # Check service status"
echo "  systemctl --user restart ollama  # Restart service"
echo "  journalctl --user -u ollama -f   # View logs"
echo ""
echo "Test GPU detection:"
echo "  rocminfo | grep 'Name:' | head -3"
echo ""
echo "Test Ollama:"
echo "  ollama list"
echo "  ollama run llama3.2"
echo ""
