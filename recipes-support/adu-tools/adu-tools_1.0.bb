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
    file://adu-wifi-setup.sh \
    file://adu-splash-screen-diagnostics.sh \
    file://adu-motd.sh \
    file://adu-ctl \
    file://GETTING-STARTED.txt \
"

S = "${WORKDIR}"

# No systemd inherit - we'll manually install the service file and enable it

# Dependencies
RDEPENDS:${PN} = " \
    bash \
    iw \
    rfkill \
    util-linux \
    coreutils \
    git \
"

# Optional dependencies (should be present if WiFi/BT enabled, but not required)
RRECOMMENDS:${PN} = " \
    connman \
    connman-client \
    wpa-supplicant \
    bluez5 \
"

do_install() {
    # Install executables to /usr/sbin/ (FHS-compliant location for system admin scripts)
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/adu-wifi-diagnostics.sh ${D}${sbindir}/
    install -m 0755 ${WORKDIR}/adu-wifi-setup.sh ${D}${sbindir}/
    install -m 0755 ${WORKDIR}/adu-splash-screen-diagnostics.sh ${D}${sbindir}/
    install -m 0755 ${WORKDIR}/adu-motd.sh ${D}${sbindir}/
    
    # Install adu-ctl to /usr/bin/ (user-facing command)
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/adu-ctl ${D}${bindir}/
    
    # Install MOTD profile.d script
    install -d ${D}${sysconfdir}/profile.d
    echo '#!/bin/sh' > ${D}${sysconfdir}/profile.d/adu-motd.sh
    echo '# Display ADU device information on login' >> ${D}${sysconfdir}/profile.d/adu-motd.sh
    echo 'if [ -n "$PS1" ]; then' >> ${D}${sysconfdir}/profile.d/adu-motd.sh
    echo '    /usr/sbin/adu-motd.sh 2>/dev/null || true' >> ${D}${sysconfdir}/profile.d/adu-motd.sh
    echo 'fi' >> ${D}${sysconfdir}/profile.d/adu-motd.sh
    chmod 0755 ${D}${sysconfdir}/profile.d/adu-motd.sh
    
    # ADU bashrc disabled - conflicts with base-files package
    # To re-enable, need to use bbappend approach instead of direct replacement
    # install -d ${D}${sysconfdir}/skel
    # install -m 0644 ${WORKDIR}/adu-bashrc ${D}${sysconfdir}/skel/.bashrc
    
    # Install documentation to /usr/share/doc/adu/
    install -d ${D}${docdir}/adu
    install -m 0644 ${WORKDIR}/GETTING-STARTED.txt ${D}${docdir}/adu/
    
    # Create a README
    cat > ${D}${docdir}/adu/README.txt << 'EOF'
ADU Tools & Documentation
=========================

This directory contains documentation for Azure Device Update images.
Utility scripts are installed in /usr/sbin/.

Available Tools:
----------------

1. adu-wifi-setup.sh (RECOMMENDED FOR FIRST TIME SETUP)
   - Interactive WiFi connection wizard
   - Usage: sudo adu-wifi-setup.sh
   - Location: /usr/sbin/adu-wifi-setup.sh
   - Guides you through connecting to WiFi networks

2. adu-wifi-diagnostics.sh
   - Comprehensive WiFi/Bluetooth diagnostic collection
   - Usage: sudo adu-wifi-diagnostics.sh
   - Location: /usr/sbin/adu-wifi-diagnostics.sh
   - Output: /boot/adu-diags/wifi-diag-YYYYMMDD-HHMMSS.txt
   - Access output from another PC by mounting boot partition

3. adu-ctl
   - ADU Agent control and management tool
   - Usage: adu-ctl <command> [options]
   - Location: /usr/bin/adu-ctl
   - Commands:
     * service start|stop|restart|status - Manage ADU service
     * journal [-f] - View agent logs
     * run [options] - Run agent in standalone mode
     * health - Quick health check
     * diag [-v] - Create support bundle
     * config - Validate configuration
     * info - Show device information
     See 'adu-ctl help' for full list

4. GETTING-STARTED.txt
   - Complete user manual for setting up your ADU device
   - Covers WiFi setup, IoT Hub connection, and first update
   - Usage: cat /usr/share/doc/adu/GETTING-STARTED.txt

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
    ${sbindir}/adu-wifi-diagnostics.sh \
    ${sbindir}/adu-wifi-setup.sh \
    ${sbindir}/adu-splash-screen-diagnostics.sh \
    ${sbindir}/adu-motd.sh \
    ${bindir}/adu-ctl \
    ${sysconfdir}/profile.d/adu-motd.sh \
    ${docdir}/adu/GETTING-STARTED.txt \
    ${docdir}/adu/README.txt \
"

# Note: /boot/adu-diags directory is created on-demand by scripts that need it (mkdir -p)
# No need to pre-create the directory or use systemd services for this.

# Make sure permissions are correct at packaging time
# Note: chown operations in do_install are not recommended in Yocto
#       File ownership is handled by the packaging system

