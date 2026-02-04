SUMMARY = "ADU Disk Utility - Interactive USB storage management tool"
DESCRIPTION = "Command-line tool to scan, mount, and unmount USB storage devices interactively"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://adu-diskutil"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/adu-diskutil ${D}${bindir}/adu-diskutil
}

FILES:${PN} = "${bindir}/adu-diskutil"

RDEPENDS:${PN} = "bash util-linux e2fsprogs"
