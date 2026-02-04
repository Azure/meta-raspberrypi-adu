#!/bin/bash
# Setup APT repositories for Raspberry Pi

set -e

ARCH=$(dpkg --print-architecture 2>/dev/null || echo "arm64")
SOURCES_DIR="/etc/apt/sources.list.d"

# Detect Yocto/Poky version for suite name
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_CODENAME="${VERSION_CODENAME:-bookworm}"
else
    DISTRO_CODENAME="bookworm"
fi

echo "=== Setting up APT repositories ==="
echo "Architecture: ${ARCH}"
echo "Codename: ${DISTRO_CODENAME}"

# Create sources directory if it doesn't exist
mkdir -p "${SOURCES_DIR}"

# Option 1: Debian repositories (arm64/aarch64)
if [ "${ARCH}" = "arm64" ]; then
    cat > "${SOURCES_DIR}/debian.list" <<EOF
# Debian ${DISTRO_CODENAME} repositories
deb http://deb.debian.org/debian ${DISTRO_CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DISTRO_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DISTRO_CODENAME}-security main contrib non-free non-free-firmware
EOF
    echo "✓ Added Debian ${DISTRO_CODENAME} repositories for ${ARCH}"
fi

# Option 2: Raspbian repositories (armhf only)
if [ "${ARCH}" = "armhf" ]; then
    cat > "${SOURCES_DIR}/raspbian.list" <<EOF
# Raspbian ${DISTRO_CODENAME} repositories
deb http://raspbian.raspberrypi.org/raspbian/ ${DISTRO_CODENAME} main contrib non-free rpi
EOF
    echo "✓ Added Raspbian ${DISTRO_CODENAME} repositories for ${ARCH}"
fi

# Option 3: Raspberry Pi OS repositories (both architectures)
cat > "${SOURCES_DIR}/raspi.list" <<EOF
# Raspberry Pi OS repositories
deb http://archive.raspberrypi.org/debian/ ${DISTRO_CODENAME} main
EOF
echo "✓ Added Raspberry Pi OS ${DISTRO_CODENAME} repositories"

# Update package lists
echo ""
echo "Updating package lists..."
if apt-get update; then
    echo "✓ APT repositories configured successfully"
    echo ""
    echo "You can now use:"
    echo "  apt-get update          - Update package lists"
    echo "  apt-get install <pkg>   - Install packages"
    echo "  apt-cache search <term> - Search packages"
else
    echo "✗ apt-get update failed - check repository configuration"
    exit 1
fi

exit 0
