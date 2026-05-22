FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

inherit systemd

SRC_URI += "file://adu-setup.service"

SYSTEMD_SERVICE:${PN} = "adu-setup.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/adu-setup.service ${D}${systemd_system_unitdir}/
    
    # Create mount point for /data partition
    # Note: /adu is created by azure-device-update recipe (as ADUC_CONF_DIR=/adu)
    # /data is a new partition not created by any existing recipe, so we create it here.
    # This ensures the directory exists even if the partition mount fails (nofail option).
    # install -d ${D}/data
}

FILES:${PN} += "${systemd_system_unitdir}/adu-setup.service"
