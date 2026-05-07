# Copyright (c) Azure Device Update for IoT Hub.
# Licensed under the MIT License.

SUMMARY = "ADU Boot Validation Service for A/B Updates"
DESCRIPTION = "Unified boot validation service that provides: \
               1) Rollback detection - detects U-Boot auto-rollback and blacklists failed workflows \
               2) Flapping prevention - detects rapid partition switching and stabilizes system \
               3) Health checks - configurable validation checks with custom plugin support \
               4) Manual override - allows operators to confirm boot manually"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://adu-boot-validation.sh \
    file://adu-confirm-boot \
    file://adu-boot-validation.service \
    file://boot-validation.conf \
    file://check-example.sh \
    file://adu-agent-watchdog.sh \
    file://adu-agent-watchdog.service \
    file://adu-agent-watchdog.timer \
"

S = "${WORKDIR}"

RDEPENDS:${PN} = " \
    bash \
    jq \
    u-boot-fw-utils \
    systemd \
    coreutils \
    grep \
    findutils \
    adu-board-config \
"

# Inherit useradd to ensure adu user exists (needed for state directory ownership)
inherit systemd useradd

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--gid 800 --system adu"
USERADD_PARAM:${PN} = "--uid 800 --system -g adu --no-create-home --shell /bin/false adu"

SYSTEMD_SERVICE:${PN} = "adu-boot-validation.service adu-agent-watchdog.timer adu-agent-watchdog.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Install validation script
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/adu-boot-validation.sh ${D}${bindir}/adu-boot-validation.sh
    
    # Install manual confirmation tool
    install -m 0755 ${WORKDIR}/adu-confirm-boot ${D}${bindir}/adu-confirm-boot
    
    # Install agent watchdog script
    install -m 0755 ${WORKDIR}/adu-agent-watchdog.sh ${D}${bindir}/adu-agent-watchdog.sh
    
    # Install systemd services and timer
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/adu-boot-validation.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/adu-agent-watchdog.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/adu-agent-watchdog.timer ${D}${systemd_system_unitdir}/
    
    # Install configuration file to /usr/lib/adu (rootfs, not data partition)
    install -d ${D}${prefix}/lib/adu
    install -m 0644 ${WORKDIR}/boot-validation.conf ${D}${prefix}/lib/adu/boot-validation.conf
    
    # Create custom checks directory on rootfs
    install -d ${D}${prefix}/lib/adu/validation-checks.d
    
    # Install example custom check (not executable by default)
    install -m 0644 ${WORKDIR}/check-example.sh ${D}${prefix}/lib/adu/validation-checks.d/check-example.sh.disabled
    
    # Create state directories (will be owned by adu user)
    install -d ${D}/var/lib/adu/states
    chown -R 800:800 ${D}/var/lib/adu 2>/dev/null || true
    chmod 770 ${D}/var/lib/adu/states 2>/dev/null || true
}

FILES:${PN} += " \
    ${bindir}/adu-boot-validation.sh \
    ${bindir}/adu-confirm-boot \
    ${bindir}/adu-agent-watchdog.sh \
    ${systemd_system_unitdir}/adu-boot-validation.service \
    ${systemd_system_unitdir}/adu-agent-watchdog.service \
    ${systemd_system_unitdir}/adu-agent-watchdog.timer \
    ${prefix}/lib/adu/boot-validation.conf \
    ${prefix}/lib/adu/validation-checks.d \
    ${prefix}/lib/adu/validation-checks.d/check-example.sh.disabled \
    /var/lib/adu/states \
"
