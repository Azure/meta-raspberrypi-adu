#!/bin/bash
# Factory reset - remove all persistent changes and revert to pristine rootfs state

# Load configuration
source /adu/conf/overlay.conf 2>/dev/null || {
    PERSIST_BASE="/adu"
    OVERLAY_BASE="${PERSIST_BASE}/overlay"
    SYSTEM_DIR="${PERSIST_BASE}/system"
}

echo "============================================"
echo "   ADU Overlay Factory Reset"
echo "============================================"
echo ""
echo "WARNING: This will DELETE all persistent changes!"
echo "  - All changes in /etc will be lost"
echo "  - All logs in /var/log will be lost"
echo "  - User accounts/passwords will be reset"
echo "  - Configuration files will revert to defaults"
echo ""
echo "A backup will be created before deletion."
echo ""

read -p "Are you sure you want to continue? (type 'yes' to confirm): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Factory reset cancelled."
    exit 0
fi

echo ""
echo "Creating backup before reset..."

# Create final backup
BACKUP_DIR="${PERSIST_BASE}/.backups/factory-reset-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}"

if [ -d "${OVERLAY_BASE}" ]; then
    cp -a "${OVERLAY_BASE}" "${BACKUP_DIR}/" 2>/dev/null || true
    echo "  Backed up overlay data"
fi

if [ -d "${SYSTEM_DIR}" ]; then
    cp -a "${SYSTEM_DIR}" "${BACKUP_DIR}/" 2>/dev/null || true
    echo "  Backed up system files"
fi

echo ""
echo "Removing persistent data..."

# Remove overlay data
if [ -d "${OVERLAY_BASE}" ]; then
    rm -rf "${OVERLAY_BASE}"/*
    echo "  ✓ Cleared overlay data"
fi

# Remove system files
if [ -d "${SYSTEM_DIR}" ]; then
    rm -rf "${SYSTEM_DIR}"/*
    echo "  ✓ Cleared system files"
fi

# Remove migration marker
rm -f "${PERSIST_BASE}/.migration-complete"

echo ""
echo "============================================"
echo "   Factory Reset Complete"
echo "============================================"
echo "Backup stored in: ${BACKUP_DIR}"
echo ""
echo "IMPORTANT: Reboot the system to apply changes"
echo "  After reboot, the system will use pristine rootfs state"
echo ""
read -p "Reboot now? (y/n): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo "Please reboot manually to complete factory reset"
fi
