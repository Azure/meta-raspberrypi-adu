# Creates the base image for ADU that can we used to flash an SD card.
# This image is also used to populate the ADU update image.

DESCRIPTION = "ADU base image"
SECTION = ""
LICENSE="CLOSED"

inherit core-image
inherit extrausers

# Provide virtual base image for meta-azure-device-update-samples layer
PROVIDES = "virtual/adu-base-image"

# Software version for the base image
# This version will be written to /etc/adu-version via adu-device-info-files recipe
# Default: 0.0.1.0 (factory/initial version for SD card flashing)
# Update images will override ADU_SOFTWARE_VERSION to force different versions
ADU_SOFTWARE_VERSION ??= "0.0.1.0"

# Set root password from build.sh (ADU_ROOT_PASSWD environment variable)
# Only set password if ADU_ROOT_PASSWD is non-empty
# Note: Password hash is already SHA512 encrypted by build.sh
def get_root_password_param(d):
    passwd = d.getVar('ADU_ROOT_PASSWD')
    if passwd:
        # Use single quotes to prevent shell interpretation of $ in hash
        return "usermod -p '%s' root;" % passwd
    return ''

EXTRA_USERS_PARAMS = "${@get_root_password_param(d)}"

# Remove quiet mode to show kernel messages during boot (helpful for debugging)
CMDLINE:remove = "quiet splash"

# For WIC image generation, we need kernel and bootloader files deployed
# Same dependencies as meta-raspberrypi/conf/machine/include/rpi-base.inc
do_image_wic[depends] += " \
    virtual/kernel:do_deploy \
    rpi-bootfiles:do_deploy \
    rpi-config:do_deploy \
    rpi-cmdline:do_deploy \
    ${@bb.utils.contains('RPI_USE_U_BOOT', '1', 'u-boot:do_deploy', '',d)} \
    ${@bb.utils.contains('RPI_USE_U_BOOT', '1', 'rpi-u-boot-scr:do_deploy', '',d)} \
    "

# .wks file is used to create partitions in image.
WKS_FILE:raspberrypi4 = "adu-raspberrypi.wks"
# wic.gz images are used to flash SD cards
# ext4.gz image is used to construct swupdate image.
# Generate both wic.gz (for SD card flashing) and ext4.gz (for OTA updates)
IMAGE_FSTYPES = "ext4.gz wic.gz wic.bmap"

# Add extra 256M to ensure enough space for future update payloads.
IMAGE_ROOTFS_EXTRA_SPACE = "262144"

# NOTE: do not add tools-profile feature. (Causing non obvious build error)

# Base image already include "splash ssh-server-openssh"
# 
#   package-management - for 'apt' support. This requires IMAGE_INSTALL += "apt" below.
#
IMAGE_FEATURES += " debug-tweaks tools-debug package-management"

# sudo    - provices sudo command
# connman - provides network connectivity.
# parted  - provides disk partitioning utility.
# fw-env-conf - installs fw_env.config file for fw utils. (fw_*)
# adu-swupdate-hw-compat - installs /etc/adu-swupdate-hw-compat file
# python3-setuptools - provides python3 related components
# apt  - provide apt, apt-*, and dpkg components
# nano - a basic text editor for convenience
# adu-boot-validation - UNIFIED: rollback detection + health checks + blacklisting (merged Feb 2026)
# adu-swap - creates 2GB swap file in /adu partition for delta reconstruction
# adu-config-setup - creates /adu/ directory structure and symlinks
# adu-persistent-overlay - hybrid overlayfs + bind mounts for data persistence
# adu-diskutil - interactive USB storage mount/unmount tool
# adu-boot-debug - DISABLED - captures boot logs when adu_debug=1 kernel parameter set
# adu-boot-menu - DISABLED - boot menu service
# REMOVED: adu-boot-health - replaced by adu-boot-validation
# REMOVED: adu-boot-validator - merged into adu-boot-validation (Feb 2026)
# REMOVED: adu-boot-splash - Plymouth boot splash (non-functional, deprecated Jan 2026)
IMAGE_INSTALL += " \
    sudo \
    parted \
    openssh \
    connman connman-client \
    fw-env-conf \
    adu-swupdate-hw-compat \
    u-boot-fw-utils \
    python3 \
    python3-modules \
    bsdiff \
    zstd \
    dpkg \
    apt \
    nano \
    binutils \
    kbd \
    terminus-font-consolefonts \
    adu-config-setup \
    adu-agent-service \
    adu-device-info-files \
    adu-boot-validation \
    adu-swap \
    adu-persistent-overlay \
    adu-tools \
    adu-diskutil \
    adu-diag \
    yocto-a-b-update \
    "

# Create empty directories in rootfs for bind mount targets
# These will be mounted to /adu/data/* by adu-persistent-overlay.service
ROOTFS_POSTPROCESS_COMMAND += "create_adu_bind_targets ; "

create_adu_bind_targets() {
    # Create /var/lib/adu subdirectories in rootfs (bind mount targets)
    install -d -m 0770 -o 800 -g 800 ${IMAGE_ROOTFS}/var/lib/adu/downloads
    install -d -m 0770 -o 800 -g 800 ${IMAGE_ROOTFS}/var/lib/adu/extensions
    install -d -m 0770 -o 800 -g 800 ${IMAGE_ROOTFS}/var/lib/adu/states
    # Delta source cache directory used by microsoft-delta-download-handler
    # Defined in ADU agent CMakeLists.txt: ADUC_DELTA_DOWNLOAD_HANDLER_SOURCE_UPDATE_CACHE_DIR = ${ADUC_DATA_FOLDER}/sdc
    install -d -m 0770 -o 800 -g 800 ${IMAGE_ROOTFS}/var/lib/adu/sdc
    # API directory for FIFOs: apireq.fifo lives here (defined in CMakeLists.txt: ${ADUC_DATA_FOLDER}/api/apireq.fifo)
    install -d -m 0770 -o 800 -g 800 ${IMAGE_ROOTFS}/var/lib/adu/api
    
    bbnote "Created /var/lib/adu/{downloads,extensions,states,sdc,api} in rootfs for bind mounts"
}
   
export IMAGE_NAME_SUFFIX = ""
export IMAGE_BASENAME = "adu-base-image"
