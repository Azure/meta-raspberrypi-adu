#!/bin/bash
# Setup overlay directory structure and initialize files

set -e

# Load configuration from rootfs
CONFIG_FILE="/etc/overlay/overlay.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

PERSIST_BASE="${PERSIST_BASE:-/adu}"
OVERLAY_BASE="${OVERLAY_BASE:-${PERSIST_BASE}/overlay}"
WORK_BASE="${WORK_BASE:-${PERSIST_BASE}/work}"
SYSTEM_DIR="${SYSTEM_DIR:-${PERSIST_BASE}/system}"

echo "=== ADU Persistent Overlay Setup ==="
echo "Persistent base: ${PERSIST_BASE}"

# NOTE: /adu partition structure is created by adu-filesystem-layout service
# This service runs after adu-filesystem-layout, so /adu/* directories already exist
# We only verify and ensure correct ownership here

# Ensure base directories exist (they should already be created by adu-filesystem-layout)
mkdir -p "${OVERLAY_BASE}"
mkdir -p "${WORK_BASE}"
mkdir -p "${SYSTEM_DIR}"
mkdir -p "${PERSIST_BASE}/.backups"

# CRITICAL: Copy overlay.conf to /adu/conf if not already present
# This ensures mount-critical-binds.sh and other scripts can find the config
# even after an A/B update where /etc/adu symlink points to /adu/conf
PERSIST_CONFIG="${PERSIST_BASE}/conf/overlay.conf"
if [ ! -f "${PERSIST_CONFIG}" ]; then
    echo "Copying overlay.conf to persistent storage: ${PERSIST_CONFIG}"
    mkdir -p "${PERSIST_BASE}/conf"
    cp "${CONFIG_FILE}" "${PERSIST_CONFIG}"
    chmod 0644 "${PERSIST_CONFIG}"
    chown root:adu "${PERSIST_CONFIG}" 2>/dev/null || true
    echo "✓ overlay.conf copied to ${PERSIST_CONFIG}"
elif ! cmp -s "${CONFIG_FILE}" "${PERSIST_CONFIG}"; then
    # Config in rootfs is newer - update persistent copy
    echo "Updating overlay.conf in persistent storage (rootfs version is newer)"
    cp "${CONFIG_FILE}" "${PERSIST_CONFIG}"
    chmod 0644 "${PERSIST_CONFIG}"
    chown root:adu "${PERSIST_CONFIG}" 2>/dev/null || true
    echo "✓ overlay.conf updated in ${PERSIST_CONFIG}"
fi

# NOTE: /adu/data directory structure is created by adu-filesystem-layout service
# This service (adu-persistent-overlay) runs after adu-filesystem-layout
# We just verify the directories exist and fix ownership if needed
if [ -d "${PERSIST_BASE}/data" ]; then
    echo "Verifying /adu/data ownership and permissions..."
    chown -R adu:adu "${PERSIST_BASE}/data" 2>/dev/null || echo "WARNING: adu user not found, skipping ownership"
    chmod 0770 "${PERSIST_BASE}/data"
    # Ensure subdirectories have correct permissions
    for subdir in states downloads extensions; do
        if [ -d "${PERSIST_BASE}/data/$subdir" ]; then
            chmod 0770 "${PERSIST_BASE}/data/$subdir"
        fi
    done
    echo "✓ /adu/data ownership verified"
else
    echo "ERROR: ${PERSIST_BASE}/data not found - adu-filesystem-layout must run first"
    exit 1
fi

# Create symlink /var/lib/adu → /adu/data (same pattern as /var/log/adu → /adu/logs)
# Remove existing directory if present (first boot migration)
if [ -d "/var/lib/adu" ] && [ ! -L "/var/lib/adu" ]; then
    echo "Migrating /var/lib/adu to ${PERSIST_BASE}/data"
    # Copy existing content to persistent storage (but skip if circular symlinks exist)
    find /var/lib/adu -maxdepth 1 -type d -exec basename {} \; | while read -r subdir; do
        if [ "$subdir" != "adu" ] && [ -d "/var/lib/adu/$subdir" ] && [ ! -L "/var/lib/adu/$subdir" ]; then
            cp -a "/var/lib/adu/$subdir" "${PERSIST_BASE}/data/" 2>/dev/null || true
        fi
    done
    # Remove original directory
    rm -rf /var/lib/adu
fi

# Create or update symlink
if [ ! -e "/var/lib/adu" ]; then
    ln -sf "${PERSIST_BASE}/data" /var/lib/adu
    echo "Created symlink: /var/lib/adu → ${PERSIST_BASE}/data"
elif [ -L "/var/lib/adu" ]; then
    # Verify symlink points to correct location
    current_target=$(readlink /var/lib/adu)
    if [ "$current_target" != "${PERSIST_BASE}/data" ]; then
        ln -sf "${PERSIST_BASE}/data" /var/lib/adu
        echo "Updated symlink: /var/lib/adu → ${PERSIST_BASE}/data"
    fi
fi

echo "Created base directories"

# Create overlay directories for each path
if [ -n "${OVERLAY_DIRS}" ]; then
    for dir in "${OVERLAY_DIRS[@]}"; do
        # Convert path to safe directory name
        safe_name=$(echo "$dir" | tr '/' '-' | sed 's/^-//')
        
        mkdir -p "${OVERLAY_BASE}/${safe_name}"
        mkdir -p "${WORK_BASE}/${safe_name}"
        
        echo "  Created overlay structure for: ${dir}"
    done
fi

# Initialize critical files if they don't exist
if [ -n "${BIND_MOUNTS}" ]; then
    for mount_spec in "${BIND_MOUNTS[@]}"; do
        IFS=':' read -r source_rel target <<< "$mount_spec"
        source_path="${SYSTEM_DIR}/${source_rel}"
        
        if [ ! -e "${source_path}" ]; then
            # Get parent directory
            source_dir=$(dirname "${source_path}")
            mkdir -p "${source_dir}"
            
            # Copy from rootfs if target exists
            if [ -e "${target}" ]; then
                echo "Initializing ${source_path} from ${target}"
                cp -a "${target}" "${source_path}"
                
                # For files, set proper permissions based on type
                if [ -f "${source_path}" ]; then
                    case "$(basename ${target})" in
                        shadow|gshadow)
                            chmod 640 "${source_path}"
                            chown root:shadow "${source_path}" 2>/dev/null || chown root:root "${source_path}"
                            ;;
                        passwd|group)
                            chmod 644 "${source_path}"
                            chown root:root "${source_path}"
                            ;;
                        machine-id)
                            chmod 444 "${source_path}"
                            chown root:root "${source_path}"
                            ;;
                        *)
                            # Preserve original permissions
                            ;;
                    esac
                fi
            else
                echo "WARNING: Target ${target} does not exist, creating placeholder"
                if [[ "${target}" == */ ]] || [ -d "$(dirname ${target})/$(basename ${target})" ]; then
                    mkdir -p "${source_path}"
                else
                    touch "${source_path}"
                fi
            fi
        else
            # File exists in persistent storage - preserve user changes
            # We do NOT overwrite persistent passwd/shadow files with rootfs versions
            # because user may have changed passwords or added users.
            #
            # IMPORTANT: If you need to reset passwords via an A/B update image,
            # either:
            #   1. Delete /adu/system/passwd and /adu/system/shadow before update
            #   2. Use factory-reset.sh before deploying the new image
            #   3. Add a version marker file that triggers reset
            #
            # This ensures user password changes persist across A/B updates.
            case "$(basename ${target})" in
                shadow|passwd|group|gshadow)
                    echo "  Preserving existing persistent ${target} (user changes persist)"
fi

# Run migration if enabled and not yet completed
if [ "${AUTO_MIGRATE}" = "yes" ] && [ ! -f "${PERSIST_BASE}/.migration-complete" ]; then
    echo "Running first-time migration..."
    /usr/lib/adu/migrate-to-overlay.sh || {
        echo "WARNING: Migration failed, continuing anyway"
    }
fi

echo "Setup complete"
exit 0
