# Copyright (c) Azure Device Update for IoT Hub.
# Licensed under the MIT License.

SUMMARY = "ADU Boot Validation Service for A/B Updates"
DESCRIPTION = "Validates successful boot after A/B partition updates and provides manual override capability"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://adu-boot-validation.sh \
    file://adu-confirm-boot \
    file://adu-boot-validation.service \
    file://boot-validation.conf \
    file://check-example.sh \
"

S = "${WORKDIR}"

RDEPENDS:${PN} = " \
    bash \
    u-boot-fw-utils \
    systemd \
    coreutils \
    grep \
    findutils \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "adu-boot-validation.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Install validation script
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/adu-boot-validation.sh ${D}${bindir}/adu-boot-validation.sh
    
    # Install manual confirmation tool
    install -m 0755 ${WORKDIR}/adu-confirm-boot ${D}${bindir}/adu-confirm-boot
    
    # Install systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/adu-boot-validation.service ${D}${systemd_system_unitdir}/
    
    # Install configuration file to /usr/lib/adu (rootfs, not data partition)
    install -d ${D}${prefix}/lib/adu
    install -m 0644 ${WORKDIR}/boot-validation.conf ${D}${prefix}/lib/adu/boot-validation.conf
    
    # Create custom checks directory on rootfs
    install -d ${D}${prefix}/lib/adu/validation-checks.d
    
    # Install example custom check (not executable by default)
    install -m 0644 ${WORKDIR}/check-example.sh ${D}${prefix}/lib/adu/validation-checks.d/check-example.sh.disabled
}

FILES:${PN} += " \
    ${bindir}/adu-boot-validation.sh \
    ${bindir}/adu-confirm-boot \
    ${systemd_system_unitdir}/adu-boot-validation.service \
    ${prefix}/lib/adu/boot-validation.conf \
    ${prefix}/lib/adu/validation-checks.d \
    ${prefix}/lib/adu/validation-checks.d/check-example.sh.disabled \
"
