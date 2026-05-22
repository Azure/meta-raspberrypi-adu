# Override postinst to remove /var/lib/adu/downloads symlink creation
# We handle /var/lib/adu differently - full directory symlink to /adu/data
# See: meta-raspberrypi-adu/recipes-support/adu-persistent-overlay/files/setup-overlay-dirs.sh

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Override the pkg_postinst_ontarget to skip /var/lib/adu/downloads symlink
# Keep /etc/adu and /var/log/adu symlinks as they don't conflict
pkg_postinst_ontarget:${PN}() {
    #!/bin/sh
    set -e
    
    # Function to safely create symlink
    create_symlink() {
        local target="$1"
        local link="$2"
        
        # If link already exists as a symlink pointing to target, nothing to do
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
            echo "Symlink $link -> $target already exists"
            return 0
        fi
        
        # If link exists but is not a symlink or points elsewhere
        if [ -e "$link" ] || [ -L "$link" ]; then
            echo "WARNING: $link exists but is not a symlink to $target"
            echo "  Backing up to ${link}.backup and creating symlink"
            mv "$link" "${link}.backup"
        fi
        
        # Create parent directory if needed
        mkdir -p "$(dirname "$link")"
        
        # Create the symlink
        ln -sf "$target" "$link"
        
        # Set ownership of the symlink itself (not the target)
        chown -h adu:adu "$link" 2>/dev/null || echo "WARNING: Could not set ownership on symlink $link"
        
        echo "Created symlink: $link -> $target"
        return 0
    }
    
    # Create /etc/adu -> /adu/conf symlink
    create_symlink "/adu/conf" "/etc/adu"
    chmod 0750 /adu/conf 2>/dev/null || echo "WARNING: Could not set permissions on /adu/conf"
    
    # Create /var/log/adu -> /adu/logs symlink
    create_symlink "/adu/logs" "/var/log/adu"
    
    # NOTE: We do NOT create /var/lib/adu/downloads symlink here
    # Instead, /var/lib/adu itself is a symlink to /adu/data (created by adu-persistent-overlay)
    # This provides better isolation and persistence across A/B updates
    
    echo "ADU configuration symlinks created successfully"
}
