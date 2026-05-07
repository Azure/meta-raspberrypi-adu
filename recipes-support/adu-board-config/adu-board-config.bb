SUMMARY = "ADU Board Configuration for Raspberry Pi 4"
DESCRIPTION = "Installs board-specific partition and boot media configuration for ADU scripts"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://board.conf"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/adu
    install -m 0644 ${WORKDIR}/board.conf ${D}${sysconfdir}/adu/board.conf
}

FILES:${PN} = "${sysconfdir}/adu/board.conf"
