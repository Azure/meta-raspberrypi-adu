# Remove the .NET DiffGenTool dependency
# We use Python bsdiff in adu-delta-image.bb instead

RDEPENDS:${PN}:remove = "iot-hub-device-update-delta-diff-generation"

# Note: /adu/data/states directory is created at runtime by adu-persistent-overlay
# See: meta-raspberrypi-adu/recipes-support/adu-persistent-overlay/files/setup-overlay-dirs.sh

# Fix: Do not create /var/lib/adu/downloads as a real directory in the image
#
# Problem: The base azure-device-update_git.bb creates /var/lib/adu/downloads as
# a real directory in the rootfs. However, the adu-config-setup recipe creates it
# as a symlink to /adu/data/downloads for persistence across A/B updates.
#
# When the update image is applied via SWUpdate, it extracts the new rootfs which
# contains a real directory, overwriting the symlink. This breaks the persistence
# strategy because downloads go to the read-only rootfs instead of /adu partition.
#
# Solution: Remove the downloads directory from the image. The adu-config-setup
# service will create it as a symlink at runtime during first boot.
#
# Related recipes:
# - adu-filesystem-layout: Creates /adu/data/downloads on the persistent partition
# - adu-config-setup: Creates symlink /var/lib/adu/downloads -> /adu/data/downloads
#
# Date: 2026-01-12
# Reason: Fix broken downloads directory after OTA update to adu-update-image-v1

do_install:append() {
    # Remove the downloads directory created by the base recipe
    # It will be created as a symlink by adu-config-setup at runtime
    if [ -d "${D}${ADUC_DOWNLOADS_DIR}" ]; then
        rm -rf "${D}${ADUC_DOWNLOADS_DIR}"
        bbnote "Removed ${ADUC_DOWNLOADS_DIR} directory - will be created as symlink by adu-config-setup"
    fi
}

# Note: The parent /var/lib/adu directory is still created by azure-device-update,
# which is correct. Only the downloads subdirectory needs to be removed.

