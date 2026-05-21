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

inherit deploy

do_install() {
    install -d ${D}/usr/lib/adu
    install -m 0755 ${WORKDIR}/yocto-a-b-update.sh ${D}/usr/lib/adu/
}

# Also publish the script to DEPLOY_DIR_IMAGE so packaging recipes
# (e.g. adu-delta-test-package in meta-azure-device-update-samples) can
# consume it via an explicit do_deploy dependency without scraping a
# rootfs. Mirrors the same task in meta-azure-device-update-bsp's copy
# of this recipe so adu-delta-test-package works on either layer set.
do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0755 ${WORKDIR}/yocto-a-b-update.sh ${DEPLOYDIR}/yocto-a-b-update.sh
}
addtask do_deploy after do_install before do_build

FILES:${PN} = "/usr/lib/adu/yocto-a-b-update.sh"

# This script is required by the SWUpdate handler extension
RDEPENDS:${PN} = "bash azure-device-update u-boot-fw-utils"

# Allow the script to be packaged even though it's a shell script
INSANE_SKIP:${PN} = "already-stripped"
