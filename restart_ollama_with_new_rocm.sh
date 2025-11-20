#!/bin/bash
# Restart Ollama to use the new system-wide ROCm installation

echo "=========================================="
echo "Restarting Ollama with New ROCm"
echo "=========================================="
echo ""

# Check if we're root
if [ "$EUID" -ne 0 ]; then
    echo "This script needs sudo to manage the system Ollama process"
    echo "Usage: sudo bash $0"
    exit 1
fi

echo "[1/4] Finding and stopping old Ollama process..."
OLD_PID=$(pgrep -x ollama | head -1)
if [ -n "$OLD_PID" ]; then
    echo "  Found Ollama process: PID $OLD_PID"
    kill -TERM $OLD_PID 2>/dev/null || kill -9 $OLD_PID 2>/dev/null
    sleep 2
    if pgrep -x ollama > /dev/null; then
        echo "  Force killing remaining processes..."
        pkill -9 ollama
        sleep 1
    fi
    echo "✓ Old Ollama stopped"
else
    echo "✓ No old Ollama process found"
fi

echo ""
echo "[2/4] Verifying ROCm installation..."
if [ ! -f /opt/rocm/bin/rocminfo ]; then
    echo "ERROR: /opt/rocm not found! Run install_systemwide.sh first"
    exit 1
fi

# Test rocminfo
if /opt/rocm/bin/rocminfo | grep -q "gfx1031"; then
    echo "✓ ROCm installed and detecting gfx1031"
else
    echo "⚠ Warning: gfx1031 not detected by rocminfo"
fi

echo ""
echo "[3/4] Creating Ollama systemd service with ROCm environment..."
cat > /etc/systemd/system/ollama.service << 'SVCEOF'
[Unit]
Description=Ollama Service with ROCm Support
After=network-online.target

[Service]
Type=simple
User=ollama
Group=ollama
ExecStart=/usr/local/bin/ollama serve
Restart=on-failure
RestartSec=5s

# ROCm Environment
Environment="ROCM_PATH=/opt/rocm"
Environment="HIP_PATH=/opt/rocm"
Environment="PATH=/opt/rocm/bin:/usr/local/bin:/usr/bin:/bin"
Environment="LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:/usr/local/lib/ollama/rocm:/usr/local/lib64"
Environment="HSA_OVERRIDE_GFX_VERSION="

# Ollama specific
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_MODELS=/usr/share/ollama/.ollama/models"

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
echo "✓ Systemd service created"

echo ""
echo "[4/4] Starting Ollama with new ROCm..."
systemctl enable ollama
systemctl start ollama
sleep 3

if systemctl is-active --quiet ollama; then
    echo "✓ Ollama started successfully"
    echo ""
    echo "Checking GPU detection..."
    sleep 2

    # Try to get GPU info from ollama
    if curl -s http://127.0.0.1:11434/api/version > /dev/null 2>&1; then
        echo "✓ Ollama API responding"
    else
        echo "⚠ Ollama API not responding yet (may need a moment)"
    fi
else
    echo "✗ Ollama failed to start"
    echo ""
    echo "Check logs with: journalctl -u ollama -n 50"
    exit 1
fi

echo ""
echo "=========================================="
echo "Ollama Restarted!"
echo "=========================================="
echo ""
echo "Test with:"
echo "  ollama ps"
echo "  ollama run llama3.2 'Hello!'"
echo ""
echo "Check GPU usage:"
echo "  rocm-smi --showuse"
echo ""
echo "Check logs:"
echo "  journalctl -u ollama -f"
echo ""
