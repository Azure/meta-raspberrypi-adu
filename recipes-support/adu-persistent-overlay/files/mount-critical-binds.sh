#!/bin/bash
# Mount critical files using bind mounts (takes precedence over overlayfs)

# Don't use set -e - we want to attempt all mounts even if some fail
set +e

# Load configuration from multiple locations (fallback chain)
# Priority: /adu/conf (persistent) → /etc/overlay (rootfs) → /etc/adu (symlink)
CONFIG_LOADED=0
for config_path in "/adu/conf/overlay.conf" "/etc/overlay/overlay.conf" "/etc/adu/overlay.conf"; do
    if [ -f "${config_path}" ]; then
        echo "Loading configuration from: ${config_path}"
        source "${config_path}"
        CONFIG_LOADED=1
        break
    fi
done

if [ "${CONFIG_LOADED}" -eq 0 ]; then
    echo "ERROR: Cannot find overlay.conf in any location"
    echo "  Searched: /adu/conf/overlay.conf, /etc/overlay/overlay.conf, /etc/adu/overlay.conf"
    exit 1
fi

echo "=== Mounting ADU Critical Bind Mounts ==="

# Mount each critical file or directory
for mount_spec in "${BIND_MOUNTS[@]}"; do
    IFS=':' read -r source_rel target <<< "$mount_spec"
    source_path="${SYSTEM_DIR}/${source_rel}"
    
    # Verify source exists (file or directory)
    if [ ! -e "${source_path}" ]; then
        echo "  [-] Source missing: ${source_path}, skipping ${target}"
        continue
    fi
    
    # Check if target exists, create if needed
    if [ -d "${source_path}" ]; then
        # Source is directory
        if [ ! -d "${target}" ]; then
            echo "  Creating directory: ${target}"
            mkdir -p "${target}"
        fi
    else
        # Source is file
        if [ ! -f "${target}" ]; then
            echo "  WARNING: Target ${target} does not exist, creating placeholder"
            mkdir -p "$(dirname ${target})"
            touch "${target}"
        fi
    fi
    
    # Check if already mounted
    if mountpoint -q "${target}" 2>/dev/null; then
        echo "  ${target} already mounted, skipping"
        continue
    fi
    
    # Backup original (once)
    if [ ! -e "${target}.rootfs-original" ]; then
        cp -a "${target}" "${target}.rootfs-original" 2>/dev/null || true
        echo "  Backed up: ${target}.rootfs-original"
    fi
    
    # Create bind mount
    mount --bind "${source_path}" "${target}" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        if [ -d "${source_path}" ]; then
            echo "  [+] Bind mounted (dir): ${source_path} -> ${target}"
        else
            echo "  [+] Bind mounted (file): ${source_path} -> ${target}"
        fi
    else
        echo "  [-] Failed to bind mount: ${target}"
    fi
done

echo "Bind mounting complete"
exit 0
