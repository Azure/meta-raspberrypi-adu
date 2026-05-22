SUMMARY = "ADU Persistent Overlay and Bind Mounts"
DESCRIPTION = "Hybrid approach using overlayfs for directories and bind mounts for critical files to persist data across A/B rootfs updates. \
               This is the advanced persistence strategy with overlayfs + runtime symlinks."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# This recipe provides ADU persistence strategy
PROVIDES = "adu-persistence-strategy"
RPROVIDES:${PN} = "adu-persistence-strategy"

# Conflicts with simple symlinks strategy
RCONFLICTS:${PN} = "adu-persistence-symlinks"

SRC_URI = " \
    file://adu-persistent-overlay.service \
    file://setup-overlay-dirs.sh \
    file://mount-overlays.sh \
    file://umount-overlays.sh \
    file://mount-critical-binds.sh \
    file://migrate-to-overlay.sh \
    file://overlay.conf \
    file://verify-overlays.sh \
    file://factory-reset.sh \
    file://setup-apt-repos.sh \
    file://README.md \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "adu-persistent-overlay.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    # Install systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/adu-persistent-overlay.service ${D}${systemd_system_unitdir}/
    
    # Install scripts
    install -d ${D}${libdir}/adu
    install -m 0755 ${WORKDIR}/setup-overlay-dirs.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/mount-overlays.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/umount-overlays.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/mount-critical-binds.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/migrate-to-overlay.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/verify-overlays.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/factory-reset.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/setup-apt-repos.sh ${D}${libdir}/adu/
    
    # Install overlay.conf to /etc/overlay in the rootfs
    install -d ${D}${sysconfdir}/overlay
    install -m 0644 ${WORKDIR}/overlay.conf ${D}${sysconfdir}/overlay/
    
    # Install overlay.conf to /etc/adu (system configuration in rootfs)
    install -d ${D}${sysconfdir}/adu
    install -m 0644 ${WORKDIR}/overlay.conf ${D}${sysconfdir}/adu/
    
    # Install documentation
    install -d ${D}${docdir}/${PN}
    install -m 0644 ${WORKDIR}/README.md ${D}${docdir}/${PN}/
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/adu-persistent-overlay.service \
    ${libdir}/adu/setup-overlay-dirs.sh \
    ${libdir}/adu/mount-overlays.sh \
    ${libdir}/adu/umount-overlays.sh \
    ${libdir}/adu/mount-critical-binds.sh \
    ${libdir}/adu/migrate-to-overlay.sh \
    ${libdir}/adu/verify-overlays.sh \
    ${libdir}/adu/factory-reset.sh \
    ${libdir}/adu/setup-apt-repos.sh \
    ${sysconfdir}/adu/overlay.conf \
    ${docdir}/${PN}/README.md \
"

# Dependencies
# Provides /adu partition structure
RDEPENDS:${PN} += "adu-filesystem-layout"
# Creates adu user/group
RDEPENDS:${PN} += "azure-device-update"
RDEPENDS:${PN} += "bash"

# Set ownership at runtime when adu group exists
pkg_postinst_ontarget:${PN}() {
    #!/bin/sh
    # Set permissions on /etc/adu/overlay.conf
    if [ -d /etc/adu ]; then
        chown root:adu /etc/adu
        chmod 0755 /etc/adu
        if [ -f /etc/adu/overlay.conf ]; then
            chown root:adu /etc/adu/overlay.conf
            chmod 0644 /etc/adu/overlay.conf
        fi
    fi
}
