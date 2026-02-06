# Porting Guide: Bring Your Own Board

> **DISCLAIMER:**  
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

## Overview

This guide helps you **adapt meta-raspberrypi-adu to your hardware platform**. It focuses on the Raspberry Pi-specific implementation details that need customization for your board.

**For platform-agnostic A/B update concepts**, see: **[ADU A/B Update Architecture Guide](architecture.md)**

**Prerequisites**:
- Your BSP (Board Support Package) for Yocto/OpenEmbedded
- Bootloader supporting persistent environment variables (U-Boot, GRUB, custom)
- Sufficient storage for dual rootfs + ADU partition (see [storage requirements](architecture.md#minimum-storage-calculation))
- Familiarity with Yocto meta layers

**Work with your BSP provider** to determine bootloader capabilities and partition layout constraints.

---

## Quick Checklist

Use this checklist to track your porting progress:

- [ ] **Bootloader**: Implement A/B boot logic with rollback
- [ ] **Partitions**: Create boot + rootA + rootB + ADU partitions
- [ ] **fstab**: Mount ADU partition with correct permissions
- [ ] **Hardware Compatibility**: Create `/etc/adu-swupdate-hw-compat` file
- [ ] **Image Recipe**: Define base image with ADU components
- [ ] **SWUpdate Package**: Create `.swu` generation recipe with sw-description
- [ ] **Boot Health**: Implement health check service
- [ ] **Testing**: Verify update, rollback, and delta (if enabled)

--- 

## Raspberry Pi Implementation Reference

This section describes **RPi-specific implementations** in meta-raspberrypi-adu. Use these as examples for your platform.

### recipes-bsp: Bootloader (U-Boot)

**What RPi does**: Appends custom U-Boot script ([boot.cmd.in](../recipes-bsp/rpi-u-boot-scr/files/boot.cmd.in)) that:
- Reads `rpipart` variable (2=rootA, 3=rootB)
- Sets kernel command line: `root=/dev/mmcblk0p${rpipart}`
- Implements 3-attempt rollback logic
- Uses fw_env.config for environment storage in SD card

**Key RPi-specific details**:
```u-boot
# boot.cmd.in snippet (simplified)
if test "${boot_attempts}" = "3"; then
    # Rollback: toggle partition
    if test "${rpipart}" = "2"; then
        setenv rpipart 3  # Switch to rootB
    else
        setenv rpipart 2  # Switch to rootA
    fi
    setenv boot_attempts 0
fi

setenv bootargs "${bootargs} root=/dev/mmcblk0p${rpipart}"
setenv boot_attempts boot_attempts + 1
```

**For your platform**:
1. Determine bootloader (U-Boot, GRUB, Barebox, custom)
2. Find environment storage method (file, raw flash, EEPROM)
3. Implement boot selection logic (see [Architecture Guide - Bootloader Integration](architecture.md#bootloader-integration))
4. Add rollback after N failed attempts (see [Architecture Guide - Bootloader Integration](architecture.md#bootloader-integration))

**Security enhancements for production**:
- Hash verification before boot (prevent flash injection)
- Kernel panic detection and rollback
- Secure boot integration (if available)

---

### recipes-core: Partition Layout and Mounting

**What RPi does**: 

1. **Custom fstab** ([base-files/fstab](../recipes-core/base-files/base-files/raspberrypi4-64/fstab)):
   ```
   /dev/mmcblk0p1  /boot   vfat  defaults,sync  0  2
   /dev/mmcblk0p4  /adu    ext4  defaults        0  2
   /dev/mmcblk0p5  /data   vfat  defaults        0  2
   ```

2. **WIC partition table** ([adu-raspberrypi.wks](../wic/adu-raspberrypi.wks)):
   ```wks
   part /boot --source bootimg-partition --fstype=vfat --size 2048M
   part /     --source rootfs --fstype=ext4 --extra-space 512  # rootA
   part /     --source rootfs --fstype=ext4 --extra-space 512  # rootB
   part /adu  --source empty --fstype=ext4 --size 8192M
   # part /data --source empty --fstype=vfat --size 1024M  # optional, requires GPT
   ```

3. **Base image recipe** ([adu-base-image.bb](../recipes-core/images/adu-base-image.bb)):
   - Installs ADU agent, SWUpdate, boot health service
   - Uses WKS file for partition generation
   - Inherits from `core-image`

**For your platform**:
- **If using WIC**: Adapt .wks file for your storage device (eMMC, NAND, SD, etc.)
- **If not using WIC**: Use BSP-provided partitioning tool
- **Partition sizes**: Calculate based on your rootfs size (see [Architecture Guide - Storage Requirements](architecture.md#minimum-storage-calculation))

**Differences from Raspberry Pi**:
- Device naming: Your board may use `/dev/sda`, `/dev/mmcblk1`, etc.
- Boot partition: Some platforms use ext4 instead of FAT32
- Storage constraints: Adjust sizes based on flash/eMMC capacity

---

### recipes-extended: SWUpdate Package Generation

**What RPi does**: Creates `.swu` update packages with:
- Compressed rootfs image (`.ext4.gz`)
- sw-description manifest (partition selection, version, hash)
- Signature for verification

**sw-description snippet** ([sw-description](../recipes-extended/images/adu-update-image/raspberrypi4-64/sw-description)):
```
software =
{
    version = "1.0.1";
    raspberrypi4-64 = {
        hardware-compatibility: [ "1.0" ];
        images: (
            {
                filename = "adu-base-image-raspberrypi4-64.ext4.gz";
                type = "image";
                device = "/dev/mmcblk0p3";  # rootB partition
                sha256 = "@adu-base-image-raspberrypi4-64.ext4.gz";
                compressed = "zlib";
            }
        );
        scripts: (
            {
                filename = "10-setup-bootloader.sh";
                type = "shellscript";
            }
        );
    }
}
```

**For your platform**:
1. Copy `recipes-extended/images/adu-update-image.bb` structure
2. Create your board's sw-description file
3. Update device paths (`/dev/mmcblk0pX` → your device)
4. Set hardware-compatibility string (see next section)

---

### recipes-support: Hardware Compatibility

**What RPi does**: Installs `/etc/adu-swupdate-hw-compat` with version string:
```bash
# adu-swupdate-hw-compat.bb
do_install() {
    install -d ${D}${sysconfdir}
    echo "1.0" > ${D}${sysconfdir}/adu-swupdate-hw-compat
}
```

**Purpose**: SWUpdate verifies this file matches `hardware-compatibility` field in sw-description before installing update.

**For your platform**:
- Use meaningful identifier: board model, CPU variant, etc.
- **Example**: "myboard-v2.1", "imx8mm-revB", "stm32mp1"
- Keep consistent across all devices of same hardware revision
- Update when hardware changes (incompatible updates)

**SWUpdate defconfig** ([defconfig](../recipes-support/swupdate/swupdate/raspberrypi4-64/defconfig)):
- RPi uses ZSTD compression for faster decompression
- Enables software selection, bootloader hooks
- See [SWUpdate documentation](https://sbabic.github.io/swupdate/) for all options

---

### wic: Partition Generation Tool

**What RPi does**: Uses OpenEmbedded's WIC tool to generate partitioned `.wic` images

**Supported by**: Most Yocto-based BSPs

**If your BSP doesn't support WIC**:
- Check BSP documentation for alternative (genimage, imx-boot-tools, etc.)
- You'll need to adapt partition creation logic
- **Goal remains the same**: boot + rootA + rootB + ADU partitions

---

## Patches in This Repo

The layer contains patches for `meta-raspberrypi` BSP (GCC issues, device tree tweaks).

**For your port**: You can safely **ignore all patches**. They're RPi-specific and won't apply to your BSP. You may need your own patches based on BSP issues.

---

## Essential ADU Components

Your image **must include** (from [meta-azure-device-update](https://github.com/Azure/meta-azure-device-update)):

| Package | Purpose |
|---------|---------|
| `azure-device-update` | ADU agent service |
| `adu-swupdate-hw-compat` | Hardware compatibility file |
| `adu-device-info-files` | Device information for Azure |
| `swupdate` | Update engine |
| `u-boot-fw-utils` | Bootloader environment tools (fw_setenv/fw_printenv) |

**In your image recipe** (`.bb` file):
```bitbake
IMAGE_INSTALL:append = " \
    azure-device-update \
    adu-swupdate-hw-compat \
    adu-device-info-files \
    swupdate \
    u-boot-fw-utils \
    adu-boot-validation \
    "
```

---

## Boot Health Validation

**What RPi does**: systemd service ([adu-boot-validation](../recipes-support/adu-boot-validation/)) that:
1. Runs after boot reaches multi-user.target
2. Checks services, filesystems, network, disk space
3. On success: `fw_setenv boot_attempts 0` (marks boot successful)
4. On failure: Reboots (increments attempt counter, triggers rollback after 3)

**For your platform**:
- Adapt script for your hardware-specific checks
- Use your bootloader's environment tool (instead of `fw_setenv`)
- See [Architecture Guide - Boot Health Verification](architecture.md#boot-health-verification)

---

## Testing Your Port

### 1. Build and Flash
```bash
bitbake your-base-image
# Flash .wic to your device
```

### 2. Verify Partitions
```bash
lsblk  # Should show boot, rootA, rootB, adu, data
df -h  # Check mounts
```

### 3. Test Bootloader Switching
```bash
# Manually switch partition
fw_setenv rpipart 3  # Or your equivalent
reboot
# Verify booted from correct partition
mount | grep "on / "
```

### 4. Test Update
```bash
# Create update package
bitbake your-update-image

# Install locally (without Azure)
swupdate -i your-update-image.swu

# Should switch partition and reboot
```

### 5. Test Rollback
```bash
# Simulate boot failure
fw_setenv boot_attempts 3
reboot
# Should automatically rollback to previous partition
```

---

## Differences from Raspberry Pi

| Aspect | Raspberry Pi | Your Platform |
|--------|--------------|---------------|
| **Storage** | SD card (`/dev/mmcblk0`) | May be eMMC, NAND, SSD |
| **Bootloader** | U-Boot | U-Boot, GRUB, Barebox, or custom |
| **Boot Partition** | FAT32 (firmware requirement) | Depends on bootloader |
| **Device Tree** | Separate .dtb files | May be in FIT image or appended |
| **Firmware** | start4.elf, fixup4.dat (GPU) | Platform-specific bootloaders |
| **U-Boot Env** | File in FAT32 (`/boot/uboot.env`) | May be raw flash offset |

**Key takeaway**: Focus on the **functional requirements** (A/B partitions, boot switching, health checks), not the RPi-specific implementation details.

---

## Additional Resources

- **[ADU A/B Update Architecture Guide](architecture.md)**: Platform-agnostic design patterns
- **[meta-azure-device-update](https://github.com/Azure/meta-azure-device-update)**: ADU agent layer
- **[SWUpdate Documentation](https://sbabic.github.io/swupdate/)**: Update engine details
- **[Yocto WIC Tool](https://docs.yoctoproject.org/dev-manual/wic.html)**: Partition image creation

---

## Getting Help

**If you're stuck**:
1. Check your BSP documentation for bootloader and partition tools
2. Review [Architecture Guide](architecture.md) for concept clarification
3. Contact Azure Device Update team (see SUPPORT.md)
4. Ask your BSP provider about bootloader capabilities

**Common questions**:
- "How do I adapt the U-Boot script?" → Work with BSP provider, see bootloader docs
- "My board uses GRUB, not U-Boot" → See [Architecture Guide - GRUB example](architecture.md#grub-implementation-example)
- "Can I use fewer partitions?" → No, A/B requires: boot + rootA + rootB + ADU (minimum 4)

---

**Document Version**: 2.0 (Streamlined)  
**Last Updated**: January 12, 2026 

You will also need to pass the ADU partition's mounting path to the `meta-azure-device-update` build system so the agent knows where to go to look for configuration files. By default we use `/adu/`. 