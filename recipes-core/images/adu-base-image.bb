# Creates the base image for ADU that can we used to flash an SD card.
# This image is also used to populate the ADU update image.

DESCRIPTION = "ADU base image"
SECTION = ""
LICENSE="CLOSED"

inherit core-image

# .wks file is used to create partitions in image.
WKS_FILE:raspberrypi4 = "adu-raspberrypi.wks"
# wic* images our used to flash SD cards
# ext4.gz image is used to construct swupdate image.
IMAGE_FSTYPES += "wic wic.gz ext4.gz"

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
IMAGE_INSTALL += " \
    sudo \
    parted \
    openssh \
    connman connman-client \
    fw-env-conf \
    adu-swupdate-hw-compat \
    u-boot-fw-utils \
    python3-setuptools \
    dpkg \
    apt \
    nano \
    binutils \
    adu-agent-service \
    adu-device-info-files \
    "
   
export IMAGE_NAME_SUFFIX = ""
export IMAGE_BASENAME = "adu-base-image"
