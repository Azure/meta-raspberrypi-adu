# ADU Integration Troubleshooting Guide

This document captures troubleshooting solutions for issues encountered when implementing a meta layer for integrating Azure Device Update (ADU) Agent into custom Yocto-based systems. While focused on Raspberry Pi 4, many solutions apply to other hardware platforms.

## Table of Contents

- [Build Environment Issues](#build-environment-issues)
- [Build Dependencies Issues](#build-dependencies-issues)
- [Runtime Dependencies Issues](#runtime-dependencies-issues)
- [Image Generation Issues](#image-generation-issues)
- [Image Boot Issues](#image-boot-issues)
- [U-Boot A/B Partition Issues](#u-boot-ab-partition-issues)

---

## Build Environment Issues

### BitBake Parse Errors

#### Error: "not a BitBake file"

**Symptom:**
```
ParseError: /path/to/recipe.bbappend: not a BitBake file
```

**Root Cause:**
- Using `require` directive to include a `.bbappend` file from another `.bbappend`
- BitBake expects `require` to reference `.bb` or `.inc` files, not `.bbappend`

**Investigation:**
```bash
# Check for circular or invalid require statements
grep -r "require.*\.bbappend" meta-layer/recipes-*
```

**Solution:**
1. Create a `.inc` file with shared code:
   ```bitbake
   # common-code.inc
   inherit deploy
   do_deploy() {
       # shared deployment logic
   }
   ```
2. Update bbappend files to require the `.inc`:
   ```bitbake
   # recipe-v1.bbappend
   require common-code.inc
   ```

---

## Build Dependencies Issues

### Missing Runtime Dependencies

#### QA Error: Package requires /bin/bash

**Symptom:**
```
ERROR: package-name do_package_qa: QA Issue: /usr/sbin/script contained in package requires /bin/bash, but no providers found in RDEPENDS
```

**Root Cause:**
- Script uses `#!/bin/bash` but bash not declared in `RDEPENDS`
- Multiple `RDEPENDS` lines where later uses `=` instead of `+=`, overwriting previous

**Investigation:**
```bash
# Check script shebang
head -1 files/script.sh

# Check RDEPENDS in recipe
grep RDEPENDS recipe.bb
```

**Solution:**
```bitbake
# Use += to append, not = to assign
RDEPENDS:${PN} += "bash"

# If multiple dependencies needed:
RDEPENDS:${PN} += "bash u-boot-fw-utils"
```

---

## Runtime Dependencies Issues

### Systemd Service Failures

#### Service fails to start - Missing dependencies

**Symptom:**
```
systemctl status service-name
● service-name.service - Description
   Loaded: loaded
   Active: failed
```

**Investigation:**
```bash
# Check service logs
journalctl -u service-name.service -n 50

# Check if dependencies are installed
which bash
which fw_printenv

# Verify service file requirements
systemctl cat service-name.service
```

**Solution:**
Add required packages to recipe's `RDEPENDS`:
```bitbake
RDEPENDS:${PN} += "bash u-boot-fw-utils systemd"
```

---

## Image Generation Issues

### WIC Image Creation Failures

#### ERROR: cannot stat device tree file

**Symptom:**
```
ERROR: _exec_cmd: install -m 0644 -D .../bcm2711-rpi-4-b.dtb ... returned '1'
install: cannot stat '.../bcm2711-rpi-4-b.dtb': No such file or directory
Task do_image_wic failed
```

**Root Cause:**
- Kernel not built before WIC image generation
- Device tree files not deployed to DEPLOYDIR

**Investigation:**
```bash
# Check if device tree files exist
find tmp/deploy/images/raspberrypi4-64 -name "*.dtb"

# Check WIC dependencies
bitbake -e image-name | grep "do_image_wic\[depends\]"
```

**Solution:**
Add kernel and bootloader dependencies to image recipe:
```bitbake
do_image_wic[depends] += " \
    virtual/kernel:do_deploy \
    rpi-bootfiles:do_deploy \
    ${@bb.utils.contains('RPI_USE_U_BOOT', '1', 'u-boot:do_deploy', '',d)} \
    "
```

Force clean rebuild if using stale sstate-cache:
```bash
bitbake -c cleansstate virtual/kernel
bitbake virtual/kernel
```

#### ERROR: cannot stat boot.scr

**Symptom:**
```
ERROR: _exec_cmd: install -m 0644 -D .../boot.scr ... returned '1'
install: cannot stat '.../boot.scr': No such file or directory
```

**Root Cause:**
- U-Boot boot script not built/deployed
- rpi-u-boot-scr recipe not in dependency chain

**Investigation:**
```bash
# Check if boot.scr exists
find tmp/deploy/images/raspberrypi4-64 -name "boot.scr"

# Check U-Boot configuration
bitbake -e image-name | grep RPI_USE_U_BOOT
```

**Solution:**
Add U-Boot script dependency:
```bitbake
do_image_wic[depends] += " \
    ${@bb.utils.contains('RPI_USE_U_BOOT', '1', 'rpi-u-boot-scr:do_deploy', '',d)} \
    "
```

Rebuild:
```bash
bitbake -c clean rpi-u-boot-scr
bitbake rpi-u-boot-scr
```

#### Shared File Conflict - SWU Images

**Symptom:**
```
ERROR: Recipe is trying to install files into a shared area when those files already exist
  /path/to/adu-update-image-v1.swu
  (matched in manifest-raspberrypi4_64-adu-update-image-v1.deploy)
```

**Root Cause:**
- Old deployment manifests and files conflict with new build
- BitBake's sstate mechanism preventing file overwrite

**Investigation:**
```bash
# Check for old manifests
ls -la tmp/deploy/images/*/manifest-*-adu-update*.deploy

# Check timestamps of SWU files
ls -lh tmp/deploy/images/*/*.swu
```

**Solution:**
```bash
# Remove old SWU files and manifests
rm -f tmp/deploy/images/raspberrypi4-64/adu-update-image-v*.swu
rm -f tmp/deploy/images/raspberrypi4-64/manifest-*-adu-update-image-v*.deploy

# Rebuild
./scripts/build.sh
```

---

### 4.6 SState Cache Not Invalidating for Dependent Recipes

**Symptom**: After rebuilding `adu-base-image`, the `adu-update-image-v1/v2/v3` recipes don't rebuild even though they depend on the base image. The SWU files contain the old base image without recent changes (like config.txt).

**Root Cause**: BitBake's `cleansstate` only cleans the specified recipe's sstate cache, not its dependents. While dependency checksums should detect changes, they don't always properly track filesystem-level changes in image artifacts.

**Investigation**:
```bash
# Check timestamps - base image should be newer than update images
ls -lht ~/adu_yocto/out/build/build/tmp/deploy/images/raspberrypi4-64/ | \
  grep -E "adu-base-image.*\.wic\.gz|adu-update-image.*\.swu"

# Check specific timestamps
ls -lt ~/adu_yocto/out/build/build/tmp/deploy/images/raspberrypi4-64/adu-base-image*.rootfs.ext4.gz
ls -lt ~/adu_yocto/out/build/build/tmp/deploy/images/raspberrypi4-64/adu-update-image*.swu

# If update images are older than base image, they weren't rebuilt
```

**Solution**:
```bash
# Option 1: Use --rebuild-base-image which now cleans all dependents and deploy artifacts
./scripts/build.sh -o ~/adu_yocto/out/build --rebuild-base-image

# Option 2: Manually clean deployed artifacts and rebuild
rm -f tmp/deploy/images/raspberrypi4-64/adu-update-image-v*.swu
rm -f tmp/deploy/images/raspberrypi4-64/adu-delta*.diff
rm -f tmp/deploy/images/raspberrypi4-64/manifest-*-adu-update-image-v*.deploy
bitbake -c cleansstate adu-base-image adu-update-image-v1 adu-update-image-v2 adu-update-image-v3 adu-delta-image
bitbake adu-base-image
bitbake adu-update-image-v1 adu-update-image-v2 adu-update-image-v3
bitbake adu-delta-image

# Option 3: Use cleanall instead of cleansstate (more aggressive, slower)
./scripts/build.sh -o ~/adu_yocto/out/build -c
```

**Prevention**: 
- The `--rebuild-base-image` option automatically cleans deployed artifacts and all dependent recipes to avoid this issue.
- The build system now includes timestamp validation that will fail the build if update images are older than the base image.

**Why cleansstate doesn't clean deploy directory:**
BitBake's `cleansstate` task only cleans:
- Recipe-specific sstate cache entries
- Recipe's work directory (`tmp/work/.../recipe/`)

It does NOT clean:
- Deploy directory (`tmp/deploy/images/`) - this is a shared area
- Deployed artifacts (SWU files, WIC files, etc.)

This is by design because the deploy directory is shared across multiple recipes. BitBake uses deployment manifests to track file ownership.

**Dual-layer protection mechanism:**

The build system uses TWO complementary mechanisms to prevent stale artifacts:

**1. Automatic Deployment Cleanup (`do_clean_old_deploys` task):**
- Removes old deployed files from `tmp/deploy/images/` before deploying new ones
- Integrated into BitBake task chain: runs before `do_deploy`
- Prevents file conflict errors during deployment
- Implementation:
  ```bitbake
  # In adu-update-image-common.inc and adu-delta-image.bb
  python do_clean_old_deploys() {
      # Remove old SWU/diff files and manifests for this recipe
      ...
  }
  addtask clean_old_deploys before do_deploy after do_swuimage
  ```

**2. Timestamp Validation (`do_validate_timestamps` task):**
- **Only active when `--with-delta-update '1'` (default)**
- Detects when BitBake deploys **cached artifacts** (from sstate) containing stale base images
- Critical safety net against sstate cache reusing old artifacts
- Fails build with clear error if artifact timestamps are older than base image
- Example scenario this catches:
  ```
  00:52 - Built adu-update-image-v1 (contains base WITHOUT config.txt)
  22:12 - Rebuilt base image (now WITH config.txt)
  23:00 - Build without --rebuild-base-image:
          → do_clean_old_deploys removes old files ✓
          → BitBake finds CACHED sstate from 00:52 ✗  
          → Deploys cached artifact (contains OLD base) ✗
          → do_validate_timestamps detects mismatch → FAILS BUILD ✓
  ```

**Why both are needed:**
- `do_clean_old_deploys`: Solves deployment conflicts (technical)
- `do_validate_timestamps`: Prevents deploying functionally incorrect artifacts (safety)

Without timestamp validation, you could deploy SWU files containing the old base image without config.txt, leading to subtle boot failures that are hard to debug.

**What to look out for:**

When building delta images, watch for these validation failures:

1. **"Base image doesn't exist but artifacts found"**:
   - Means: Update/delta artifacts exist from cache but base image is missing or being rebuilt
   - Action: Run `./scripts/build.sh --rebuild-base-image` to rebuild entire chain

2. **"Artifact is older than base image"**:
   - Means: Base image was rebuilt but update/delta images weren't
   - Action: Run `./scripts/build.sh --rebuild-base-image` to force rebuild

3. **Build succeeds but no validation messages**:
   - If delta feature disabled (`--with-delta-update '0'`): Validation skipped (normal)
   - If delta feature enabled: Check that base image and artifacts all have matching timestamps

**Disabling timestamp validation:**
```bash
# If you don't need delta updates, disable the feature to skip validation
./scripts/build.sh --with-delta-update '0' ...
```

This is safe for simple full-image OTA updates without delta support.

**Root Cause Details**: BitBake's sstate cache uses checksums of:
- Recipe content and variables
- Input file checksums
- Dependency task signatures

However, when only the *contents* of an image file change (like adding config.txt to the boot partition), but the recipe itself hasn't changed, BitBake may not detect this as requiring a rebuild of dependent recipes. The sstate checksums are based on the recipe's tasks and inputs, not the final image file contents. The `cleansstate` approach forces a clean rebuild of specific recipes and their outputs.

**Automatic Detection**: Since this is a common pitfall, a timestamp validation class (`adu-timestamp-check.bbclass`) has been added that automatically validates artifact timestamps during build. If an update image or delta file is older than the base image, the build will fail with a clear error message instructing you to use `--rebuild-base-image`.

---

## Image Boot Issues

| Symptom | Root Cause | Investigation | Solution |
|---------|-----------|---------------|----------|
| **Rainbow screen on boot, device hangs** | Missing `config.txt` in boot partition. Raspberry Pi firmware cannot initialize without it. | 1. Mount SD card boot partition on Linux/Mac<br>2. `ls -la /mount/boot/`<br>3. Check if `config.txt` exists<br>4. On build system: `ls tmp/deploy/images/raspberrypi4-64/bootfiles/config.txt` | Add boot file dependencies to image recipe:<br>`do_image_wic[depends] += " \`<br>`    rpi-config:do_deploy \`<br>`    rpi-cmdline:do_deploy \`<br>`    "`<br><br>Clean and rebuild:<br>`bitbake -c cleansstate rpi-bootfiles rpi-config rpi-cmdline`<br>`bitbake rpi-bootfiles`<br>`./scripts/build.sh` |
| **Device boots but fails to mount /adu partition** | 1. Partition not created in WKS file<br>2. Partition created but not formatted<br>3. Wrong partition number in fstab | 1. Check WKS file has partition defined<br>2. Boot device and check: `lsblk`<br>3. Check partition exists: `fdisk -l /dev/mmcblk0`<br>4. Check fstab: `cat /etc/fstab`<br>5. Try manual mount: `mount /dev/mmcblk0p4 /adu` | **WKS file** (meta-layer/wic/image.wks):<br>`part /adu --ondisk mmcblk0 --fstype=ext4 --label adu --align 4096 --size 4096`<br><br>**fstab** (base-files bbappend):<br>`/dev/mmcblk0p4  /adu  ext4  defaults  0  2`<br><br>Rebuild image with proper partition layout |
| **Device boots but fails to mount /data partition** | Same as /adu - partition layout mismatch | Same investigation as /adu | **WKS file**:<br>`part /data --ondisk mmcblk0 --fstype=vfat --label data --align 4096 --size 1024`<br><br>**fstab**:<br>`/dev/mmcblk0p5  /data  vfat  defaults  0  0` |
| **U-Boot fails to load kernel** | 1. `boot.scr` missing or incorrect<br>2. Wrong kernel image type<br>3. Device tree not loaded | 1. Check boot partition for boot.scr<br>2. Connect serial console (115200 8N1)<br>3. Watch U-Boot messages<br>4. Check U-Boot environment: `fw_printenv` | Verify boot script variables:<br>`KERNEL_IMAGETYPE = "Image"`<br>`KERNEL_BOOTCMD = "booti"`<br><br>Check U-Boot config matches:<br>`RPI_USE_U_BOOT = "1"`<br><br>Rebuild boot files:<br>`bitbake -c clean rpi-u-boot-scr`<br>`bitbake rpi-u-boot-scr` |
| **Kernel panics - Unable to mount root** | 1. Wrong root device in cmdline.txt<br>2. Root filesystem not ext4<br>3. U-Boot not setting correct bootargs | 1. Check cmdline.txt: `cat /boot/cmdline.txt`<br>2. Check root= parameter<br>3. Verify WKS partition order matches fstab<br>4. Serial console shows exact kernel panic | **cmdline.txt** should have:<br>`root=/dev/mmcblk0p2 rootfstype=ext4 rootwait`<br><br>Or for U-Boot A/B switching:<br>`root=/dev/mmcblk0p${rpipart}`<br><br>Ensure WKS file has rootfs as 2nd partition |
| **systemd services fail on boot** | 1. Dependencies not installed<br>2. Mount points don't exist<br>3. Permission issues | 1. SSH to device (if network up)<br>2. `systemctl status --failed`<br>3. `journalctl -xe`<br>4. Check service files: `systemctl cat service-name` | Fix RDEPENDS in recipes:<br>`RDEPENDS:${PN} += "bash systemd"`<br><br>Ensure mount points exist:<br>`install -d ${D}/adu`<br>`install -d ${D}/data`<br><br>Fix permissions in recipe |

### Common Boot Investigation Commands

When device boots, connect via serial console (GPIO 14/15, 115200 8N1) or SSH and run:

```bash
# Check partition layout
lsblk
fdisk -l /dev/mmcblk0

# Check mounted filesystems
mount | grep mmcblk0
df -h

# Check fstab vs actual mounts
cat /etc/fstab
mount -a  # Try to mount all from fstab

# Check failed services
systemctl status --failed
journalctl -xe

# Check boot files
ls -la /boot/

# Check U-Boot environment (if using U-Boot)
fw_printenv
```

### Serial Console Connection

For debugging boot issues, connect a USB-to-TTL adapter:
- **TX** → GPIO 14 (Pin 8)
- **RX** → GPIO 15 (Pin 10)  
- **GND** → Ground (Pin 6)

Terminal settings: **115200 baud, 8N1, no flow control**

```bash
# Linux/Mac
screen /dev/ttyUSB0 115200

# Or use minicom
minicom -D /dev/ttyUSB0 -b 115200
```

---

## U-Boot A/B Partition Issues

For detailed U-Boot boot script internals, see [U-Boot Script](uboot.md).

### Quick Diagnostics

```bash
# Check current U-Boot environment
fw_printenv boot_partition boot_attempts upgrade_available last_known_good_partition

# Expected values (normal operation):
#   boot_partition=rootA (or rootB)
#   boot_attempts=0
#   upgrade_available=0
#   last_known_good_partition=rootA (or rootB)
```

### Common U-Boot Issues

| Symptom | Cause | Solution |
|---------|-------|----------|
| **Device boots wrong partition** | `boot_partition` set incorrectly | `fw_setenv boot_partition rootA && reboot` |
| **Constant rollback loop** | Boot validation keeps failing | Check `journalctl -u adu-boot-validation`, fix root cause, then reset: `fw_setenv boot_attempts 0` |
| **Update doesn't activate** | `upgrade_available` not set | Handler must set: `fw_setenv upgrade_available 1` before reboot |
| **Drops to U-Boot console** | Catastrophic failure (LKG failing) | Both partitions broken; re-flash SD card |
| **U-Boot env not persisting** | `/boot/uboot.env` write issue | Check boot partition is mounted rw, check disk space |

### Manual Recovery

**Force boot to specific partition:**
```bash
fw_setenv boot_partition rootA
fw_setenv upgrade_available 0
fw_setenv boot_attempts 0
reboot
```

**Reset to clean state after failed update:**
```bash
fw_setenv boot_partition rootA        # Or rootB if that's your known-good
fw_setenv upgrade_available 0
fw_setenv boot_attempts 0
fw_setenv boot_result unknown
fw_setenv last_known_good_partition rootA
reboot
```

### Serial Console for Boot Debugging

Connect USB-to-TTL serial adapter:
- **TX** → GPIO 14 (Pin 8)
- **RX** → GPIO 15 (Pin 10)  
- **GND** → Ground (Pin 6)

```bash
# Connect at 115200 baud
screen /dev/ttyUSB0 115200
# Or
minicom -D /dev/ttyUSB0 -b 115200
```

Watch U-Boot output for:
- `boot_partition=` value
- `boot_attempts=` counter
- `upgrade_available=` flag
- Any rollback messages

---

## Best Practices

### Before Building

1. **Clean build when changing dependencies:**
   ```bash
   bitbake -c cleansstate recipe-name
   ```

2. **Verify layer priority:**
   ```bash
   bitbake-layers show-layers
   ```

3. **Check recipe dependencies:**
   ```bash
   bitbake -e recipe-name | grep "^DEPENDS="
   bitbake -e recipe-name | grep "^RDEPENDS="
   ```

### During Build

1. **Monitor for QA warnings:**
   - Look for "QA Issue" messages
   - Address warnings before they become errors

2. **Check sstate usage:**
   - High cache hit rate (>90%) may hide rebuild issues
   - Use `-c cleansstate` to force fresh builds when needed

### After Build

1. **Verify image contents before flashing:**
   ```bash
   # Extract and mount WIC image
   gunzip -c image.wic.gz > image.wic
   losetup -fP image.wic
   mount /dev/loop0p1 /mnt/boot
   ls -la /mnt/boot/
   ```

2. **Test on device systematically:**
   - Serial console for boot issues
   - SSH for runtime issues
   - Check logs in /var/log/ and journalctl

---

## Additional Resources

- [Yocto Project Documentation](https://docs.yoctoproject.org/)
- [meta-raspberrypi Layer](https://github.com/agherzan/meta-raspberrypi)
- [Azure Device Update Documentation](https://docs.microsoft.com/azure/iot-hub-device-update/)
- [BitBake User Manual](https://docs.yoctoproject.org/bitbake/)
