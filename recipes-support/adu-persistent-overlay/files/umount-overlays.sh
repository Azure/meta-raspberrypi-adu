#!/bin/bash
# Unmount overlays and bind mounts (for service stop/restart)

# Load configuration
source /adu/conf/overlay.conf 2>/dev/null || {
    # Fallback defaults if config not available
    OVERLAY_DIRS=("/etc" "/var/log")
    BIND_MOUNTS=("passwd:/etc/passwd" "shadow:/etc/shadow" "group:/etc/group" "gshadow:/etc/gshadow")
    PERSIST_BASE="/adu"
}

echo "=== Unmounting ADU Overlays and Bind Mounts ==="

# Unmount bind mounts first
for mount_spec in "${BIND_MOUNTS[@]}"; do
    IFS=':' read -r source_rel target <<< "$mount_spec"
    
    if mountpoint -q "${target}"; then
        umount "${target}" && echo "  Unmounted bind: ${target}"
    fi
done

# Unmount overlays
for dir in "${OVERLAY_DIRS[@]}"; do
    if mountpoint -q "${dir}"; then
        umount "${dir}" && echo "  Unmounted overlay: ${dir}"
        
        # Also unmount the temporary bind mount used as lowerdir
        orig_mount="${PERSIST_BASE}/.orig${dir}"
        if mountpoint -q "${orig_mount}" 2>/dev/null; then
            umount "${orig_mount}" && echo "  Unmounted temp bind: ${orig_mount}"
        fi
    fi
done

echo "Unmounting complete"
exit 0
