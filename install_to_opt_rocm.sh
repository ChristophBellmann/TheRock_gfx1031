#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEROCK_BUILD="$SCRIPT_DIR/build/dist/rocm"

echo "=========================================="
echo "Installing TheRock Build to /opt/rocm"
echo "=========================================="
echo ""

# Check if TheRock build exists
if [ ! -d "$THEROCK_BUILD" ]; then
    echo "ERROR: TheRock build not found at $THEROCK_BUILD"
    exit 1
fi

# Backup existing /opt/rocm if it exists
if [ -d "/opt/rocm" ]; then
    BACKUP_NAME="/opt/rocm.backup-$(date +%Y%m%d-%H%M%S)"
    echo "Backing up existing /opt/rocm to $BACKUP_NAME"
    sudo mv /opt/rocm "$BACKUP_NAME"
    echo "✓ Backup created"
fi

# Copy TheRock build to /opt/rocm
echo ""
echo "Copying TheRock build to /opt/rocm..."
sudo cp -a "$THEROCK_BUILD" /opt/rocm
echo "✓ TheRock build installed to /opt/rocm"

# Set proper ownership
echo ""
echo "Setting ownership to root:root..."
sudo chown -R root:root /opt/rocm
echo "✓ Ownership set"

# Configure ldconfig for ROCm libraries
echo ""
echo "Configuring library paths..."
sudo tee /etc/ld.so.conf.d/rocm.conf > /dev/null << 'EOF'
/opt/rocm/lib
/opt/rocm/lib64
EOF

sudo ldconfig
echo "✓ Library cache updated"

# Create system-wide environment script
echo ""
echo "Creating system environment configuration..."
sudo tee /etc/profile.d/rocm.sh > /dev/null << 'EOF'
# ROCm Environment Configuration (TheRock Build)
export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export PATH=/opt/rocm/bin:$PATH
export LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:$LD_LIBRARY_PATH

# Native gfx1031 support - no override needed
unset HSA_OVERRIDE_GFX_VERSION
EOF
echo "✓ Environment script created at /etc/profile.d/rocm.sh"

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "TheRock ROCm with native gfx1031 support is now installed at /opt/rocm"
echo ""
echo "Next steps:"
echo "1. Log out and log back in (or run: source /etc/profile.d/rocm.sh)"
echo "2. Verify installation: rocminfo | grep 'Name:'"
echo "3. Update Ollama to use the new ROCm"
echo ""
