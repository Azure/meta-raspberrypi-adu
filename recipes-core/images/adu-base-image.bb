# Creates the base image for ADU that can we used to flash an SD card.
# This image is also used to populate the ADU update image.

DESCRIPTION = "ADU base image"
SECTION = ""
LICENSE="CLOSED"

inherit core-image

# Disable Plymouth splash screen and quiet mode for interactive boot menu
# The boot menu needs console access and visible kernel messages
CMDLINE:remove = "quiet splash"
CMDLINE:append = " plymouth.enable=0"

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
# adu-boot-health - validates successful boot and marks boot_attempts=0
# adu-swap - creates 2GB swap file in /adu partition for delta reconstruction
# adu-config-setup - creates /adu/ directory structure and symlinks
# adu-boot-validation - comprehensive boot validation with manual override
# adu-boot-debug - DISABLED - captures boot logs when adu_debug=1 kernel parameter set
# adu-boot-menu - DISABLED - boot menu service
# adu-boot-splash - DISABLED - customizes boot splash (disables Plymouth, shows kernel messages)
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
    adu-boot-health \
    adu-boot-validation \
    adu-swap \
    adu-tools \
    "
   
export IMAGE_NAME_SUFFIX = ""
export IMAGE_BASENAME = "adu-base-image"
