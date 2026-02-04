SUMMARY = "Yocto A/B Update Handler Script for Raspberry Pi"
DESCRIPTION = "Platform-specific update handler script for A/B partition updates on Raspberry Pi. \
               This script is called by the SWUpdate handler to perform partition management, \
               boot configuration updates, and U-Boot environment modifications for A/B updates."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://yocto-a-b-update.sh"

S = "${WORKDIR}"

# This recipe provides the A/B update handler script
# It's Raspberry Pi specific and separate from the generic ADU agent
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}/usr/lib/adu
    install -m 0755 ${WORKDIR}/yocto-a-b-update.sh ${D}/usr/lib/adu/
}

FILES:${PN} = "/usr/lib/adu/yocto-a-b-update.sh"

# This script is required by the SWUpdate handler extension
RDEPENDS:${PN} = "bash azure-device-update u-boot-fw-utils"

# Allow the script to be packaged even though it's a shell script
INSANE_SKIP:${PN} = "already-stripped"
