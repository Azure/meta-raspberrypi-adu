SUMMARY = "ADU Swap File Service"
DESCRIPTION = "Service that creates and activates a swap file for delta update operations"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://adu-swap.service \
    file://setup-swap.sh \
"

S = "${WORKDIR}"

inherit systemd

RDEPENDS:${PN} += "bash"

SYSTEMD_SERVICE:${PN} = "adu-swap.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/setup-swap.sh ${D}${sbindir}/adu-setup-swap

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/adu-swap.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} = "${sbindir}/adu-setup-swap ${systemd_system_unitdir}/adu-swap.service"
