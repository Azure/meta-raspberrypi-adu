#!/bin/bash
# Migrate existing device to persistent overlay system

set -e

# Load configuration
# Use direct path to avoid dependency on /etc/adu symlink creation
source /adu/conf/overlay.conf

echo "============================================"
echo "   ADU Overlay Migration Utility"
echo "============================================"
echo ""

# Safety check
if [ -f "${PERSIST_BASE}/.migration-complete" ]; then
    echo "Migration already completed on: $(cat ${PERSIST_BASE}/.migration-complete)"
    echo "To re-run migration, delete: ${PERSIST_BASE}/.migration-complete"
    exit 0
fi

echo "This will migrate authentication and configuration files to persistent storage."
echo ""

# Create backup directory
BACKUP_DIR="${PERSIST_BASE}/.backups/migration-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}"

echo "Step 1: Backing up critical files..."
for mount_spec in "${BIND_MOUNTS[@]}"; do
    IFS=':' read -r source_rel target <<< "$mount_spec"
    
    if [ -f "${target}" ]; then
        cp -a "${target}" "${BACKUP_DIR}/"
        echo "  ✓ Backed up: $(basename ${target})"
    fi
done

echo ""
echo "Step 2: Copying files to persistent storage..."
for mount_spec in "${BIND_MOUNTS[@]}"; do
    IFS=':' read -r source_rel target <<< "$mount_spec"
    dest_path="${SYSTEM_DIR}/${source_rel}"
    
    if [ -f "${dest_path}" ]; then
        echo "  ${dest_path} already exists, skipping"
        continue
    fi
    
    if [ ! -f "${target}" ]; then
        echo "  WARNING: ${target} not found, skipping"
        continue
    fi
    
    # Ensure parent directory exists
    mkdir -p "$(dirname ${dest_path})"
    
    # Copy file preserving attributes
    cp -a "${target}" "${dest_path}"
    
    # Set proper permissions
    case "$(basename ${target})" in
        shadow|gshadow)
            chmod 640 "${dest_path}"
            chown root:shadow "${dest_path}" 2>/dev/null || chown root:root "${dest_path}"
            ;;
        passwd|group)
            chmod 644 "${dest_path}"
            chown root:root "${dest_path}"
            ;;
    esac
    
    echo "  ✓ Migrated: ${target} → ${dest_path}"
done

# Mark migration complete
date > "${PERSIST_BASE}/.migration-complete"
echo "Migration completed at: $(date)" >> "${PERSIST_BASE}/.migration-complete"

echo ""
echo "============================================"
echo "   Migration Complete"
echo "============================================"
echo "Backup stored in: ${BACKUP_DIR}"
echo ""
echo "Next steps:"
echo "  1. Verify files in ${SYSTEM_DIR}"
echo "  2. Reboot to activate overlays and bind mounts"
echo "  3. Test with: /usr/lib/adu/verify-overlays.sh"
echo ""
