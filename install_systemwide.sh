#!/bin/bash
# TheRock System-wide Installation Script
# Installs TheRock build to /opt/rocm with proper configuration
# Created: $(date)

set -e  # Exit on error

THEROCK_BUILD="/home/hashcat/TheRock/build/dist/rocm"
INSTALL_DIR="/opt/rocm"
BACKUP_SUFFIX="backup.$(date +%Y%m%d_%H%M%S)"

echo "=========================================="
echo "TheRock System-wide Installation"
echo "=========================================="
echo ""
echo "Source: $THEROCK_BUILD"
echo "Target: $INSTALL_DIR"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run with sudo"
    echo "Usage: sudo bash $0"
    exit 1
fi

# Verify source directory exists and is functional
echo "[1/7] Verifying TheRock build..."
if [ ! -d "$THEROCK_BUILD" ]; then
    echo "ERROR: TheRock build not found at $THEROCK_BUILD"
    exit 1
fi

if [ ! -f "$THEROCK_BUILD/bin/rocminfo" ]; then
    echo "ERROR: rocminfo not found in build directory"
    exit 1
fi

echo "✓ Build directory verified (2.4GB)"

# Backup existing installation
echo "[2/7] Backing up existing /opt/rocm..."
if [ -e "$INSTALL_DIR" ]; then
    BACKUP_PATH="${INSTALL_DIR}.${BACKUP_SUFFIX}"
    echo "  Moving $INSTALL_DIR to $BACKUP_PATH"
    mv "$INSTALL_DIR" "$BACKUP_PATH"
    echo "✓ Backup created: $BACKUP_PATH"
else
    echo "✓ No existing installation to backup"
fi

# Create /opt if it doesn't exist
mkdir -p /opt

# Copy TheRock build to /opt/rocm
echo "[3/7] Copying TheRock build to $INSTALL_DIR..."
echo "  This will take a moment (copying 2.4GB)..."
cp -a "$THEROCK_BUILD" "$INSTALL_DIR"
echo "✓ Files copied successfully"

# Set proper ownership and permissions
echo "[4/7] Setting ownership and permissions..."
chown -R root:root "$INSTALL_DIR"
chmod -R a+rX "$INSTALL_DIR"
chmod -R u+w "$INSTALL_DIR"
echo "✓ Ownership set to root:root"

# Create system-wide environment configuration
echo "[5/7] Creating system environment configuration..."
cat > /etc/profile.d/rocm-therock.sh << 'ENVEOF'
# ROCm Environment - TheRock Build
# Native gfx1031 support for AMD RX 6700 XT

export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export PATH=/opt/rocm/bin:$PATH
export LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:${LD_LIBRARY_PATH}

# Remove any legacy override - we have native gfx1031 support!
unset HSA_OVERRIDE_GFX_VERSION
ENVEOF

chmod 644 /etc/profile.d/rocm-therock.sh
echo "✓ Created /etc/profile.d/rocm-therock.sh"

# Configure ldconfig for ROCm libraries
echo "[6/7] Configuring dynamic linker..."
cat > /etc/ld.so.conf.d/rocm-therock.conf << 'LDEOF'
/opt/rocm/lib
/opt/rocm/lib64
/opt/rocm/lib/llvm/lib
LDEOF

ldconfig
echo "✓ Updated ldconfig cache"

# Verify installation
echo "[7/7] Verifying installation..."
if /opt/rocm/bin/rocminfo --version > /dev/null 2>&1; then
    echo "✓ rocminfo works"
else
    echo "⚠ Warning: rocminfo test had issues (may need reboot/re-login)"
fi

if /opt/rocm/bin/hipconfig --version > /dev/null 2>&1; then
    echo "✓ hipconfig works"
else
    echo "⚠ Warning: hipconfig test had issues (may need reboot/re-login)"
fi

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Log out and log back in (to load environment)"
echo "  2. Run: rocminfo | grep 'Name:' | head -3"
echo "     Should show: gfx1031"
echo ""
echo "  3. Test with Ollama:"
echo "     systemctl --user restart ollama"
echo "     ollama run llama3.2"
echo ""
echo "Backup location: ${INSTALL_DIR}.${BACKUP_SUFFIX}"
echo "To restore backup: sudo mv ${INSTALL_DIR}.${BACKUP_SUFFIX} $INSTALL_DIR"
echo ""
echo "Installed components:"
echo "  - LLVM/Clang compiler toolchain"
echo "  - HIP runtime with native gfx1031 support"
echo "  - ROCm math libraries (rocBLAS, hipBLAS, etc.)"
echo "  - ROCm ML libraries (MIOpen)"
echo "  - All tools and utilities"
echo ""
