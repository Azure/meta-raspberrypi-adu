SUMMARY = "ADU Boot Validator Service"
DESCRIPTION = "Service that detects boot rollbacks and validates partition before ADU agent starts"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://adu-boot-validator.service \
    file://adu-boot-validator.sh \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "adu-boot-validator.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "bash jq u-boot-fw-utils"

# Inherit useradd to ensure adu user exists
inherit useradd

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--gid 800 --system adu"
USERADD_PARAM:${PN} = "--uid 800 --system -g adu --no-create-home --shell /bin/false adu"

do_install() {
    # Install systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/adu-boot-validator.service ${D}${systemd_system_unitdir}/
    
    # Install validator script
    install -d ${D}${libdir}/adu
    install -m 0755 ${WORKDIR}/adu-boot-validator.sh ${D}${libdir}/adu/
    
    # Note: /var/lib/adu and subdirectories are created by azure-device-update recipe
    # Note: /var/lock is created at runtime by systemd (tmpfs)
    # The script will create lock file on demand
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/adu-boot-validator.service \
    ${libdir}/adu/adu-boot-validator.sh \
"
