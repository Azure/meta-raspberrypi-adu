# Install custom timesyncd.conf for Raspberry Pi ADU devices
# This ensures accurate time synchronization which is critical for:
# - TLS certificate validation (notBefore/notAfter checks)
# - Azure IoT Hub connection and authentication
# - Update package signature verification

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://timesyncd.conf"

do_install:append() {
    # Only install if systemd-timesyncd is enabled
    if ${@bb.utils.contains('PACKAGECONFIG', 'timesyncd', 'true', 'false', d)}; then
        install -d ${D}${sysconfdir}/systemd
        install -m 0644 ${WORKDIR}/timesyncd.conf ${D}${sysconfdir}/systemd/timesyncd.conf
    fi
}

# Only add the file to the package if timesyncd is enabled
FILES:${PN} += "${@bb.utils.contains('PACKAGECONFIG', 'timesyncd', '${sysconfdir}/systemd/timesyncd.conf', '', d)}"
