# Overrides the default boot loader script that is defined in meta-raspberrypi
# Implements Azure Device Update A/B partition management with automatic rollback
#
# IMPORTANT: This script expects specific partition layout:
#   Partition 1: /boot (FAT32, bootloader files)
#   Partition 2: /     (ext4, rootA - primary rootfs)
#   Partition 3: (none) (ext4, rootB - secondary rootfs for A/B updates)
#   Partition 4: /adu  (ext4, persistent ADU data)
#   Partition 5: /data (vfat, optional user data)
#
# The boot script uses these U-Boot environment variables:
#   - boot_partition: Which partition to boot from (rootA or rootB)
#   - boot_attempts: Current boot attempt counter (0-3)
#   - boot_result: Result of last boot (success/failed/unknown)
#   - boot_attempts_A/B: Per-partition boot attempt counters
#   - boot_result_A/B: Per-partition boot results
#   - boot_timestamp_A/B: Unix timestamps of last successful boots
#   - upgrade_available: Flag indicating update is pending validation (0 or 1)
#
# If partition numbers change in adu-raspberrypi.wks, you MUST update:
#   - This boot script's root=/dev/mmcblk0p2 and root=/dev/mmcblk0p3 references
#   - The base-files fstab to match new partition layout
#   - Any systemd mount units that reference partition numbers
#
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://check-uboot-rollback.sh \
            file://ADU-ERROR-REPORTING.md \
            "

# Install helper script to check for rollback errors
do_install:append() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/check-uboot-rollback.sh ${D}${bindir}/check-uboot-rollback
    
    # Install documentation
    install -d ${D}${docdir}/${PN}
    install -m 0644 ${WORKDIR}/ADU-ERROR-REPORTING.md ${D}${docdir}/${PN}/
}

