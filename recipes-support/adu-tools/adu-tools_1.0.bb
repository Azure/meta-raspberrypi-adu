# Recipe: adu-tools
# Description: Azure Device Update diagnostic and utility tools
# Installs: /adu/tools/ directory with WiFi diagnostics and other utilities

SUMMARY = "Azure Device Update diagnostic and utility tools"
DESCRIPTION = "Collection of diagnostic scripts and utilities for troubleshooting \
               Azure Device Update images, including WiFi/Bluetooth diagnostics."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://adu-wifi-diagnostics.sh \
"

S = "${WORKDIR}"

# Dependencies
RDEPENDS:${PN} = " \
    bash \
    iw \
    wireless-tools \
    rfkill \
    util-linux \
    coreutils \
"

# Optional dependencies (should be present if WiFi/BT enabled, but not required)
RRECOMMENDS:${PN} = " \
    connman \
    connman-client \
    wpa-supplicant \
    bluez5 \
"

do_install() {
    # Create /adu/tools directory (safe if already exists from other recipes)
    # Note: install -d is idempotent and won't conflict with other recipes
    # as long as each recipe only claims its own files in FILES:${PN}
    install -d ${D}/adu/tools
    
    # Install WiFi diagnostics script
    install -m 0755 ${WORKDIR}/adu-wifi-diagnostics.sh ${D}/adu/tools/
    
    # Create diagnostics output directory on boot partition
    # Note: /boot is mounted from mmcblk0p1, accessible from any system
    install -d ${D}/boot/adu-diags
    
    # Create a README in /adu/tools
    cat > ${D}/adu/tools/README.txt << 'EOF'
ADU Tools Directory
===================

This directory contains diagnostic and utility tools for Azure Device Update images.

Available Tools:
----------------

1. adu-wifi-diagnostics.sh
   - Comprehensive WiFi/Bluetooth diagnostic collection
   - Usage: sudo /adu/tools/adu-wifi-diagnostics.sh
   - Output: /boot/adu-diags/wifi-diag-YYYYMMDD-HHMMSS.txt
   - Access output from another PC by mounting boot partition

Documentation:
--------------
For detailed WiFi/Bluetooth troubleshooting, see:
- /adu/tools/README-TSG-WIFI.md (if available)
- https://github.com/Azure/iot-hub-device-update-yocto

Output Location:
----------------
Diagnostics are saved to /boot/adu-diags/ which is on the boot partition.
This allows you to:
1. Remove SD card if device not accessible
2. Mount boot partition on another PC
3. Read diagnostic files to troubleshoot

Example:
  sudo mount /dev/sdX1 /mnt
  ls /mnt/adu-diags/
  cat /mnt/adu-diags/wifi-diag-*.txt

EOF
}

# Package files
FILES:${PN} = " \
    /adu/tools/adu-wifi-diagnostics.sh \
    /adu/tools/README.txt \
    /boot/adu-diags \
"

# Make sure /adu/tools is owned by root with proper permissions
# /boot/adu-diags should be world-writable so scripts can write to it
do_install:append() {
    # /adu/tools owned by root, readable by all, writable by root
    chown -R root:root ${D}/adu/tools
    chmod 755 ${D}/adu/tools
    chmod 755 ${D}/adu/tools/*.sh
    chmod 644 ${D}/adu/tools/README.txt
    
    # /boot/adu-diags writable by all (scripts need to create files)
    chmod 777 ${D}/boot/adu-diags
}

# No need for systemd or sysvinit services - these are manual tools
inherit allarch
