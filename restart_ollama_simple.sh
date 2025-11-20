#!/bin/bash
# Simple script to restart Ollama and test GPU detection

echo "Restarting Ollama to pick up native gfx1031 support..."
echo ""

# Kill old ollama process
echo "[1/3] Stopping Ollama..."
pkill -9 ollama 2>/dev/null
sleep 2

# Start ollama in background with no override
echo "[2/3] Starting Ollama (will run in background)..."
unset HSA_OVERRIDE_GFX_VERSION
export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:$LD_LIBRARY_PATH

nohup /usr/local/bin/ollama serve > /tmp/ollama.log 2>&1 &
OLLAMA_PID=$!
echo "Started Ollama with PID: $OLLAMA_PID"
sleep 3

# Test if it's running
echo "[3/3] Testing Ollama..."
if pgrep ollama > /dev/null; then
    echo "✓ Ollama is running"
    echo ""
    echo "Waiting 5 seconds for initialization..."
    sleep 5

    echo ""
    echo "Testing GPU detection..."
    ollama ps 2>/dev/null || echo "No models loaded yet"

    echo ""
    echo "Load a model to test GPU:"
    echo "  ollama run llama3.2 'Hello!'"
else
    echo "✗ Ollama failed to start"
    echo "Check logs: cat /tmp/ollama.log"
fi
