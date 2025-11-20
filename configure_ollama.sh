#!/bin/bash
# Script to configure Ollama with ROCm support

set -e

echo "Configuring Ollama for ROCm..."
echo ""

# Backup existing service file
if [ -f /etc/systemd/system/ollama.service ]; then
    echo "Backing up existing service file..."
    sudo cp /etc/systemd/system/ollama.service /etc/systemd/system/ollama.service.backup.$(date +%Y%m%d_%H%M%S)
fi

# Install new service file
echo "Installing updated Ollama service configuration..."
sudo cp ollama.service.new /etc/systemd/system/ollama.service

# Reload systemd
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

# Restart Ollama service
echo "Restarting Ollama service..."
sudo systemctl restart ollama

# Wait a moment for service to start
sleep 2

# Check service status
echo ""
echo "Checking Ollama service status..."
sudo systemctl status ollama --no-pager | head -15

echo ""
echo "✓ Ollama has been configured for ROCm support!"
echo ""
echo "To test GPU detection, run:"
echo "  ollama run llama3.2:1b --verbose"
echo ""
echo "Or check the service logs:"
echo "  journalctl -u ollama -f"
