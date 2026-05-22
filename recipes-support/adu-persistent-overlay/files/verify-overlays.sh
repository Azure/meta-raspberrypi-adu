#!/bin/bash
# Verify overlayfs and bind mounts are active

# Load configuration
source /adu/conf/overlay.conf 2>/dev/null || {
    echo "ERROR: Cannot load configuration"
    exit 1
}

echo "============================================"
echo "   ADU Overlay Verification"
echo "============================================"
echo ""

EXIT_CODE=0

# Check overlay mounts
echo "Checking Overlayfs Mounts:"
echo "----------------------------------------"
for dir in "${OVERLAY_DIRS[@]}"; do
    if mountpoint -q "${dir}"; then
        mount_info=$(mount | grep "on ${dir} type overlay")
        echo "✓ ${dir}"
        echo "  ${mount_info}"
        
        # Check for active marker
        if [ -f "${dir}/.adu-overlay-active" ]; then
            echo "  [Active marker present]"
        fi
    else
        echo "✗ ${dir} - NOT MOUNTED"
        EXIT_CODE=1
    fi
    echo ""
done

# Check bind mounts
echo "Checking Bind Mounts:"
echo "----------------------------------------"
for mount_spec in "${BIND_MOUNTS[@]}"; do
    IFS=':' read -r source_rel target <<< "$mount_spec"
    source_path="${SYSTEM_DIR}/${source_rel}"
    
    if mountpoint -q "${target}"; then
        mount_info=$(mount | grep "${target}")
        echo "✓ ${target}"
        echo "  ${mount_info}"
        
        # Verify source and target are same
        if [ "$(stat -c %i ${source_path})" = "$(stat -c %i ${target})" ]; then
            echo "  [Source and target inodes match]"
        else
            echo "  WARNING: Inodes don't match, may not be properly bound"
        fi
    else
        echo "✗ ${target} - NOT MOUNTED"
        EXIT_CODE=1
    fi
    echo ""
done

# Check persistent storage
echo "Persistent Storage Status:"
echo "----------------------------------------"
echo "Base directory: ${PERSIST_BASE}"
df -h "${PERSIST_BASE}" | tail -1
echo ""
echo "Overlay data: $(du -sh ${OVERLAY_BASE} 2>/dev/null | cut -f1)"
echo "System files: $(du -sh ${SYSTEM_DIR} 2>/dev/null | cut -f1)"
echo ""

# List critical file versions
echo "Critical File Status:"
echo "----------------------------------------"
for mount_spec in "${BIND_MOUNTS[@]}"; do
    IFS=':' read -r source_rel target <<< "$mount_spec"
    source_path="${SYSTEM_DIR}/${source_rel}"
    
    if [ -f "${source_path}" ]; then
        perms=$(stat -c "%a %U:%G" "${source_path}")
        echo "${target}: ${perms}"
    fi
done
echo ""

# Summary
echo "============================================"
if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ All overlays and bind mounts are active"
else
    echo "✗ Some mounts are missing or inactive"
fi
echo "============================================"

exit $EXIT_CODE
