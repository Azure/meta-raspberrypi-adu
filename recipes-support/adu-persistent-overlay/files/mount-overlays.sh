#!/bin/bash
# Mount overlayfs for configured directories

# Don't use set -e - we want to attempt all mounts even if some fail
set +e

# Load configuration from rootfs
source /etc/overlay/overlay.conf

echo "=== Mounting ADU Persistent Overlays ==="

# Clean up any stale temporary mounts from previous runs
echo "Cleaning up stale temporary mounts..."
for orig_mount in "${PERSIST_BASE}"/.orig/*; do
    if [ -d "${orig_mount}" ] && mountpoint -q "${orig_mount}" 2>/dev/null; then
        umount "${orig_mount}" 2>/dev/null && echo "  Cleaned: ${orig_mount}"
    fi
done

# Mount overlayfs for each configured directory
for dir in "${OVERLAY_DIRS[@]}"; do
    # Convert path to safe directory name
    safe_name=$(echo "$dir" | tr '/' '-' | sed 's/^-//')
    
    # Special handling for /var/lib/adu/* paths - map to /adu/data/*
    if [[ "$dir" == /var/lib/adu/* ]]; then
        # Extract subdirectory name (downloads, extensions, states, etc.)
        subdir=$(basename "$dir")
        lower_dir="/adu/data/${subdir}"
        
        # Verify the persistent directory exists
        if [ ! -d "${lower_dir}" ]; then
            echo "ERROR: Persistent directory missing: ${lower_dir}"
            continue
        fi
        
        # For /var/lib/adu/* we use the persistent directory directly as lower
        # No need for upper/work since we want direct writes to /adu/data
        upper_dir=""
        work_dir=""
    else
        # Standard overlay setup for other directories
        upper_dir="${OVERLAY_BASE}/${safe_name}"
        work_dir="${WORK_BASE}/${safe_name}"
        lower_dir=""
    fi
    
    # Check if already mounted
    if mountpoint -q "${dir}" 2>/dev/null; then
        echo "  ${dir} already mounted, skipping"
        continue
    fi
    
    # Handle /var/lib/adu/* paths - use bind mount to persistent storage
    if [[ "$dir" == /var/lib/adu/* ]]; then
        # Direct bind mount to persistent storage
        if ! mount --bind "${lower_dir}" "${dir}" 2>/dev/null; then
            echo "  [-] Failed to bind mount: ${dir} -> ${lower_dir}"
            continue
        fi
        echo "  [+] Bind mounted: ${dir} -> ${lower_dir}"
        continue
    fi
    
    # Verify directories exist for standard overlays
    if [ ! -d "${upper_dir}" ] || [ ! -d "${work_dir}" ]; then
        echo "ERROR: Overlay directories missing for ${dir}"
        continue
    fi
    
    # Save current contents to upperdir if first mount
    if [ -d "${dir}" ] && [ -z "$(ls -A ${upper_dir} 2>/dev/null)" ]; then
        echo "  Migrating existing content from ${dir} to overlay"
        cp -a "${dir}/." "${upper_dir}/" 2>/dev/null || true
    fi
    
    # Create temporary mount point for original content
    orig_mount="${PERSIST_BASE}/.orig${dir}"
    mkdir -p "${orig_mount}"
    
    # Bind mount original to temporary location (acts as lowerdir)
    mount --bind "${dir}" "${orig_mount}" 2>/dev/null
    
    # Mount overlay with original as lowerdir
    mount -t overlay overlay \
        -o lowerdir=${orig_mount},upperdir=${upper_dir},workdir=${work_dir} \
        "${dir}" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo "  [+] Mounted overlay: ${dir}"
        # Create marker in overlay to indicate it's active
        touch "${dir}/.adu-overlay-active" 2>/dev/null || true
    else
        echo "  [-] Failed to mount overlay: ${dir}"
        # Cleanup temp bind mount
        umount "${orig_mount}" 2>/dev/null || true
    fi
done

echo "Overlay mounting complete"
exit 0
