#!/bin/bash
# Test script to verify Ollama GPU detection

echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
echo "║                        Ollama GPU Detection Test                             ║"
echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check if Ollama is running
if ! systemctl is-active --quiet ollama; then
    echo "⚠️  Ollama service is not running!"
    echo "   Start it with: sudo systemctl start ollama"
    exit 1
fi

echo "✓ Ollama service is running"
echo ""

# Check environment from service
echo "=== Ollama Service Environment ==="
sudo systemctl show ollama -p Environment | grep -o 'ROCM_PATH=[^ ]*\|HIP_PATH=[^ ]*\|HSA_OVERRIDE_GFX_VERSION=[^ ]*' | head -5
echo ""

# Check recent logs for GPU detection
echo "=== GPU Detection Logs (last 5 minutes) ==="
sudo journalctl -u ollama --since "5 minutes ago" --no-pager | grep -i "gpu\|rocm\|amd\|gfx" | tail -10 || echo "No GPU logs found recently"
echo ""

# Test with a small model
echo "=== Testing with small model ==="
echo "This will pull and run llama3.2:1b (about 1.3GB)"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Running test prompt..."
    ollama run llama3.2:1b "Say 'GPU test successful' if you can read this." --verbose 2>&1 | head -20

    echo ""
    echo "Check the output above for GPU offload information"
fi

echo ""
echo "To monitor Ollama logs in real-time:"
echo "  sudo journalctl -u ollama -f"
