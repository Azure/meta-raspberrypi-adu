# Prevent packagegroup-base from pulling in WiFi/Bluetooth firmware
# when ENABLE_WIFI_BLUETOOTH is not set

# Remove the problematic firmware from bad recommendations when feature is disabled
BAD_RECOMMENDATIONS:append = "${@'' if d.getVar('ENABLE_WIFI_BLUETOOTH') == '1' else ' linux-firmware-rpidistro-bcm43455'}"
