SUMMARY = "ADU System Diagnostic Tool"
DESCRIPTION = "Comprehensive diagnostic tool for troubleshooting Azure Device Update system issues. \
               Collects information about services, mounts, configurations, and logs. \
               Includes adu-health-check for quick validation without early exits."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://adu-diag \
    file://adu-health-check \
"

S = "${WORKDIR}"

do_install() {
    # Install diagnostic scripts to /usr/bin so they're in PATH
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/adu-diag ${D}${bindir}/
    install -m 0755 ${WORKDIR}/adu-health-check ${D}${bindir}/
}

FILES:${PN} = "${bindir}/adu-diag ${bindir}/adu-health-check"

# Runtime dependencies
RDEPENDS:${PN} = "bash coreutils util-linux"

inherit allarch
