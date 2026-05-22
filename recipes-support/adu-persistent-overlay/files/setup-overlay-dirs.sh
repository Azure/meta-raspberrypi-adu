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
            # File exists - check if we should update from rootfs (e.g., password changed in image)
            # For authentication files, update if rootfs version is different and not default
            case "$(basename ${target})" in
                shadow|passwd)
                    if [ -f "${target}" ] && [ -f "${source_path}" ]; then
                        # Compare with rootfs version - if different, it may be an intentional update
                        if ! cmp -s "${target}" "${source_path}" 2>/dev/null; then
                            # Check if rootfs shadow has non-empty password for root
                            if [ "$(basename ${target})" = "shadow" ]; then
                                root_hash=$(grep "^root:" "${target}" | cut -d: -f2)
                                if [ -n "$root_hash" ] && [ "$root_hash" != "*" ] && [ "$root_hash" != "!" ]; then
                                    echo "Updating ${source_path} from rootfs (password changed in image)"
                                    cp -a "${target}" "${source_path}"
                                    chmod 640 "${source_path}"
                                    chown root:shadow "${source_path}" 2>/dev/null || chown root:root "${source_path}"
                                fi
                            fi
                        fi
                    fi
                    ;;
            esac
        fi
    done
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
