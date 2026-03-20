# meta-raspberrypi-adu

> **DISCLAIMER:**  
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

## Quick Start

This is a **Yocto meta layer** that provides Raspberry Pi-specific customizations for Azure Device Update with A/B partition support. It is **not a standalone project** — it must be used as part of a complete Yocto build environment with all required layers.

```bash
# Typical build workflow (from parent iot-hub-device-update-yocto repo)
cd iot-hub-device-update-yocto
source yocto/poky/oe-init-build-env ~/adu_yocto/out/build

# Ensure all layers are in bblayers.conf, then build:
bitbake adu-base-image

# Flash to SD card using bmaptool (recommended — faster, verifies integrity)
cd ~/adu_yocto/out/build/tmp/deploy/images/raspberrypi4-64/
sudo bmaptool copy adu-base-image-raspberrypi4-64.wic.gz /dev/sdX

# Alternative: flash with dd
# sudo dd if=adu-base-image-raspberrypi4-64.wic of=/dev/sdX bs=4M status=progress && sync
```

---

## What This Layer Provides

- Raspberry Pi BSP customizations for A/B rootfs updates
- U-Boot boot script with partition switching and automatic rollback logic
- Boot validation service with configurable health checks
- WIC partition layout (boot + rootA + rootB + adu)
- SWUpdate integration for OTA updates
- Persistent overlay strategy to preserve data across A/B updates

---

## Requirements

- **Host System**: Ubuntu 20.04+ or compatible Linux distribution
- **Disk Space**: ~100GB for Yocto build
- **RAM**: 16GB+ recommended, 8GB minimum
- **Target Device**: Raspberry Pi 3B+ or Raspberry Pi 4 (2GB+ RAM)
- **SD Card**: 16GB+ (32GB recommended for delta updates)
- **Network**: Ethernet or WiFi for IoT Hub connectivity

---

## Hardware Compatibility

| Device | Tested | A/B Updates | Delta Updates | Notes |
|--------|--------|-------------|---------------|-------|
| **Raspberry Pi 4** (2GB/4GB/8GB) | ✅ Yes | ✅ Yes | ✅ Yes | Recommended |
| **Raspberry Pi 3B+** | ✅ Yes | ✅ Yes | ⚠️ Limited | Need 4GB+ swap for 1GB+ images |
| **Raspberry Pi 3B** | ⚠️ Limited | ✅ Yes | ❌ No | 1GB RAM insufficient for delta |
| **Other Boards** | ❌ No | 🔄 Portable | 🔄 Portable | See [Porting Guide](docs/porting.md) |

**Delta Update Requirements**:
- **RAM**: Physical RAM + Swap ≥ Rootfs Size
- **Example**: 1GB rootfs → Need 512MB RAM + 512MB swap (or 2GB swap for safety)
- **Storage**: 8GB+ ADU partition (2GB staging + 2GB swap + downloads)

---

## Layer Dependencies

This layer requires the following layers in your `bblayers.conf`:

| Layer | Purpose | Source |
|-------|---------|--------|
| **poky/meta** | Yocto core | https://git.yoctoproject.org/poky |
| **poky/meta-poky** | Poky distro | (included with poky) |
| **meta-openembedded/meta-oe** | Additional recipes | https://github.com/openembedded/meta-openembedded |
| **meta-openembedded/meta-python** | Python support | (included with meta-openembedded) |
| **meta-openembedded/meta-networking** | Networking tools | (included with meta-openembedded) |
| **meta-raspberrypi** | Raspberry Pi BSP | https://github.com/agherzan/meta-raspberrypi |
| **meta-swupdate** | SWUpdate framework | https://github.com/sbabic/meta-swupdate |
| **meta-clang** | Clang compiler (for delta) | https://github.com/kraj/meta-clang |
| **meta-azure-device-update** | ADU agent & handlers | https://github.com/azure/meta-azure-device-update |
| **meta-iot-hub-device-update-delta** | Delta update support | https://github.com/azure/meta-iot-hub-device-update-delta |
| **meta-raspberrypi-adu** | **This layer** | (this project) |

For a complete working example of how to integrate all these layers, see the parent repository's build scripts and `bblayers.conf` configuration.

---

## Documentation

| Document | Description |
|----------|-------------|
| ⭐ **[Customization Guide](docs/customization.md)** | **Start here for modifications** — Partitioning, U-Boot boot script, boot validation, ADU handler integration |
| [Architecture Guide](docs/architecture.md) | Platform-agnostic A/B rootfs design patterns, storage/RAM requirements |
| [Porting Guide](docs/porting.md) | Adapt this layer to other hardware platforms |
| [U-Boot Script](docs/uboot.md) | A/B partition boot logic, variables, rollback |
| [Troubleshooting](docs/troubleshooting.md) | Common issues and fixes for boot, updates, builds |

### External Resources
- [Azure Device Update Documentation](https://learn.microsoft.com/azure/iot-hub-device-update/)
- [SWUpdate Documentation](https://sbabic.github.io/swupdate/)
- [U-Boot Documentation](https://u-boot.readthedocs.io/)

---

## Overview

This Yocto meta layer provides a complete, **production-ready reference implementation** of Azure Device Update (ADU) for Raspberry Pi devices (3B+ and 4) with advanced delta update capabilities and resilient A/B partition management.

**For platform-agnostic design concepts**, see: [ADU A/B Update Architecture Guide](docs/architecture.md)

## Purpose

The `meta-raspberrypi-adu` layer enables:

1. **Over-the-Air (OTA) Updates via Azure Device Update**
   - Full integration with Azure IoT Hub Device Update service
   - Support for full image updates and bandwidth-efficient delta updates
   - Automated update deployment and monitoring from Azure cloud

2. **Resilient A/B Partition Updates**
   - Dual rootfs partitions (rootA/rootB) with automatic failover
   - Boot health validation with automatic rollback on failure
   - U-Boot integration with configurable boot attempt counter (default: 5 attempts)
   - Minimal downtime (single reboot for partition switch, automatic rollback on failure)

3. **Delta Update Infrastructure**
   - Large dedicated partition (8GB) for delta staging and reconstruction
   - Automatic 2GB swap file for memory-constrained delta operations
   - Microsoft's libadudiffapi for efficient binary patching
   - Reduces bandwidth usage by 60-95% compared to full updates

4. **Production Security and Reliability**
   - ACL-protected ADU data partition (`adu` group access only, set by `adu-setup.service`)
   - Boot health monitoring with comprehensive system checks
   - Persistent health logs in `/var/log/adu/`
   - Hardware compatibility validation via swupdate

## Key Features

### Azure Device Update Agent
- **SWUpdate Handler V2**: Full rootfs updates with partition management
- **Delta Downloader**: Bandwidth-efficient differential updates
- **Script Handler**: Custom update workflows and pre/post-install hooks
- **Delivery Optimization**: Intelligent download scheduling and caching

### A/B Update System
- **Dual Rootfs Partitions**: Independent root filesystems for failsafe updates
- **U-Boot A/B Switching**: Automatic boot slot selection via `boot_partition` variable (`rootA`/`rootB`)
- **Boot Health Validation**: Post-update system health checks
- **Automatic Rollback**: Reverts to previous partition after `max_boot_attempts` failed attempts (default: 5)

### Delta Update Support
- **8GB ADU Partition**: Large staging area for delta reconstruction (ext4)
- **2GB Swap File**: Automatic swap creation for memory-intensive patching
- **Binary Differential Updates**: 5-40% of full image size (typical)
- **Integrity Verification**: SHA256 checksums for all update files

### Custom SWUpdate
- **ZSTD Compression**: Fast decompression for quicker updates
- **Hardware Compatibility**: Custom compatibility file (`/etc/adu-swupdate-hw-compat`)
- **Update Handlers**: Support for multiple update types (image, file, script)

### Boot Health System
- **Post-Boot Validation**: Validates critical services, filesystems, and network
- **Success Marking**: Resets boot counter via `fw_setenv boot_attempts 0`
- **Health Logging**: Detailed logs in `/var/log/adu/boot-validation.log`
- **Failure Detection**: Triggers automatic rollback on validation failure

### Security and Access Control
- **ADU User/Group**: Dedicated user (uid=800) and group (gid=800)
- **Protected Partition**: `/adu` ownership set to `adu:adu` (770) by `adu-setup.service` after mount
- **Persistent Configuration**: `/etc/adu → /adu/conf` and `/var/log/adu → /adu/logs` symlinks

---

## Partition Layout

The layer creates a 4-partition layout (MBR) optimized for A/B updates and delta operations:

| Partition | Size | Type | Mount | Purpose | A/B |
|-----------|------|------|-------|---------|-----|
| P1: boot | 2GB | FAT32 | /boot | U-Boot, kernel, device tree | ❌ Shared |
| P2: rootA | Dynamic+512MB | ext4 | / | Root filesystem — Slot A | ✅ |
| P3: rootB | Dynamic+512MB | ext4 | / | Root filesystem — Slot B | ✅ |
| P4: adu | 8GB | ext4 | /adu | ADU data, logs, swap, delta staging | ❌ Shared |

> **Note on a 5th `/data` partition**: The WIC file contains a commented-out 5th partition for optional customer data storage. Enabling it requires switching to a GPT partition table (MBR supports only 4 primary partitions). Raspberry Pi 4 supports GPT; older models may not. See the [Customization Guide](docs/customization.md) for instructions.

**Why 8GB for /adu?**
- Delta reconstruction requires ~2GB staging space (rootfs size)
- 2GB swap file for memory-constrained delta operations
- Room for logs, health data, and download cache
- Future expansion headroom

**Partition management** (adding/removing partitions, MBR vs GPT migration, fstab sync): see [Customization Guide](docs/customization.md).

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        SD Card Layout                            │
├─────────────┬─────────────┬─────────────┬───────────────────────┤
│ Boot (2G)   │ RootA (2G)  │ RootB (2G)  │       ADU (8G)        │
│   (FAT32)   │   (ext4)    │   (ext4)    │       (ext4)          │
└─────────────┴─────────────┴─────────────┴───────────────────────┘
       │              │             │            │
       │              │             │            └─ Delta staging
       │              │             │               Swap file (2GB)
       │              │             │               Health logs
       │              │             │               Download cache
       │              │             │
       │              │             └─ Inactive slot (update target)
       │              │
       │              └─ Active slot (current boot)
       │
       └─ U-Boot + Kernel (shared)

Update Flow:
1. Device boots from RootA (boot_partition=rootA)
2. Boot-health service validates system health
3. ADU downloads delta update to /adu/
4. Delta reconstructed using v1 + diff → v2
5. SWUpdate installs v2 to RootB
6. U-Boot switches to RootB (boot_partition=rootB)
7. Device reboots into RootB
8. Boot-health validates → success or rollback
```

---

## Recipe Reference

### recipes-bsp

#### `rpi-u-boot-scr` (bbappend)
Overrides the default Raspberry Pi U-Boot boot script from `meta-raspberrypi` to implement A/B partition management with automatic rollback.

**How it works:**
- Reads the `boot_partition` U-Boot environment variable (`rootA` or `rootB`)
- Increments `boot_attempts` on each boot
- If `boot_attempts` exceeds `max_boot_attempts` (default: **5**), triggers rollback to `last_known_good_partition`
- On first boot, initialises all variables and saves `uboot.env`

**Key U-Boot environment variables:**

| Variable | Values | Description |
|----------|--------|-------------|
| `boot_partition` | `rootA` / `rootB` | Active partition to boot |
| `boot_attempts` | 0–N | Current boot attempt counter for active slot |
| `max_boot_attempts` | 5 (default) | Rollback threshold (configurable) |
| `upgrade_available` | `0` / `1` | Indicates a pending update awaiting validation |
| `boot_result` | `success` / `failed` / `unknown` | Result of last boot validation |
| `last_known_good_partition` | `rootA` / `rootB` | Safe fallback partition |

**Key files:**
- [`rpi-u-boot-scr/files/boot.cmd.in`](recipes-bsp/rpi-u-boot-scr/files/boot.cmd.in): Boot script with A/B logic
- [`rpi-u-boot-scr/files/check-uboot-rollback.sh`](recipes-bsp/rpi-u-boot-scr/files/check-uboot-rollback.sh): Userspace helper to inspect rollback state

#### `u-boot` (bbappend) + `fw-env-conf`
- `u-boot_%.bbappend`: Applies build patches for Raspberry Pi compatibility
- `fw-env-conf.bb`: Installs `/etc/fw_env.config` so `fw_printenv` / `fw_setenv` know where the U-Boot environment is stored

---

### recipes-core

#### `base-files` (bbappend)
- Custom `fstab` with all 4 partitions defined (`/boot`, `/`, `/adu`)
- `/adu` is mounted with `defaults` options; ownership (`800:800`) and permissions (`770`) are applied **post-mount** by `adu-setup.service`
- Installs `adu-setup.service` to set `/adu` ownership after mount

  > **Note**: `adu-setup.service` is deprecated and will be superseded by `adu-oobe.service` from `meta-azure-device-update` in a future release. Both handle `/adu` partition ownership setup.

#### `images/adu-base-image.bb`
Base image recipe with all ADU components. Produces:
- `adu-base-image-raspberrypi4-64.wic.gz` — SD card flash image
- `adu-base-image-raspberrypi4-64.ext4.gz` — rootfs used by OTA update packages

Sets `ADU_SOFTWARE_VERSION` (default: `0.0.1.0`) written to `/etc/adu-version`.

#### `packagegroup-base.bbappend`
Extends the base package group with additional Raspberry Pi-specific packages.

---

### recipes-extended

#### `adu-update-image.bb`
Builds a SWUpdate `.swu` OTA update package from `adu-base-image`. The package contains the compressed ext4 rootfs and an `sw-description` manifest targeting both rootA and rootB.

Signing is configured via:
- `ADUC_PRIVATE_KEY` — path to RSA private key (`.pem`)
- `ADUC_PRIVATE_KEY_PASSWORD` — path to key password file (`.pass`)

**Versioned update recipes and delta recipes** (`adu-update-image-v2`, `adu-update-image-v3`, `adu-delta-image`) are **not part of this layer**. They live in the sibling [`meta-azure-device-update-samples`](../meta-azure-device-update-samples/) layer, which provides the full multi-version A/B and delta update demo workflow.

---

### recipes-graphics

#### `mesa`, `mesa-gl`, `mesa-demos` (bbappends)
Mesa and DRM/KMS configuration for the Raspberry Pi graphics stack. These bbappends adjust build options for compatibility with the RPi BSP.

---

### recipes-kernel

#### `linux-raspberrypi_%.bbappend`
Applies a kernel config fragment (`enable-overlayfs.cfg`) that enables overlayfs support (`CONFIG_OVERLAY_FS=y`). This is a **required** kernel dependency for `adu-persistent-overlay` to function.

---

### recipes-support

#### `adu-boot-validation`
Unified two-phase systemd service that validates each boot **before** the ADU agent starts.

- **Phase 1 — Rollback detection**: Reads U-Boot variables to detect if an auto-rollback occurred. If so, blacklists the failed `workflow_id` to prevent infinite retry loops and detects partition flapping.
- **Phase 2 — Health validation**: Runs configurable health checks (critical services, filesystems, network, disk space). Supports custom plugin scripts in `/usr/lib/adu/validation-checks.d/`.
- On success: calls `fw_setenv boot_attempts 0` to mark the boot good.
- Logs to `/var/log/adu/boot-validation.log`.

**Installed tools:**
- `adu-boot-validation.sh` (`/usr/bin/`) — validation script (also callable manually)
- `adu-confirm-boot` (`/usr/bin/`) — operator tool to manually confirm a boot as healthy (useful when automated checks are too strict during development)
- `boot-validation.conf` (`/usr/lib/adu/`) — configuration for check behaviour
- `check-example.sh.disabled` — example custom check plugin (disabled by default)

#### `adu-diag`
Comprehensive diagnostic tool for troubleshooting ADU system issues.

**Installed tools:**
- `adu-diag` (`/usr/bin/`) — collects logs, partition info, service status, and configuration into a support bundle
- `adu-health-check` (`/usr/bin/`) — runs all health checks without early exit (useful for scripted validation or CI); unlike `adu-boot-validation.sh`, it never triggers rollback

#### `adu-diskutil`
Interactive USB storage management tool (`/usr/bin/adu-diskutil`). Scan, mount, and unmount USB devices from the command line — useful for manual update file transfers.

#### `adu-persistent-overlay`
Hybrid persistence strategy using overlayfs and bind mounts to preserve critical data across A/B rootfs updates (e.g. `/etc/adu`, `/var/log/adu`, `/var/lib/adu`).

- Provides `adu-persistence-strategy` virtual package (conflicts with `adu-persistence-symlinks`)
- Requires `adu-filesystem-layout` (RDEPENDS) and overlayfs kernel support (via `linux-raspberrypi_%.bbappend`)
- Configuration: `/etc/adu/overlay.conf` and `/etc/overlay/overlay.conf`
- Scripts installed to `/usr/lib/adu/`: `mount-overlays.sh`, `umount-overlays.sh`, `mount-critical-binds.sh`, `factory-reset.sh`, and others

The persistence strategy is selected via:
```
PREFERRED_PROVIDER_adu-persistence-strategy = "adu-persistent-overlay"
```
(set in `conf/distro/include/adu-persistence-overlayfs.inc`, included automatically by `layer.conf`)

#### `adu-swap`
Systemd service that creates and activates a 2GB swap file at `/adu/swapfile` on the ADU partition. Activates automatically on boot and is required for delta reconstruction on memory-constrained devices.

#### `adu-swupdate-hw-compat`
Generates and installs `/etc/adu-swupdate-hw-compat` containing `${MACHINE} ${HW_REV}` (e.g. `raspberrypi4-64 1.0`). SWUpdate checks this file against the `hardware-compatibility` field in the update manifest to reject incompatible packages.

`HW_REV` defaults to `1.0` and can be overridden via `local.conf` or environment variable.

#### `adu-tools`
Collection of diagnostic and utility scripts for ADU images.

**Installed locations:**
- `/usr/sbin/` — `adu-wifi-setup.sh`, `adu-wifi-diagnostics.sh`, `adu-splash-screen-diagnostics.sh`, `adu-motd.sh`
- `/usr/bin/` — `adu-ctl` (ADU agent control and management tool)
- `/etc/profile.d/adu-motd.sh` — displays device info on login
- `/usr/share/doc/adu/` — `GETTING-STARTED.txt` and `README.txt`

**`adu-ctl` commands:** `service`, `journal`, `run`, `health`, `diag`, `config`, `info` — run `adu-ctl help` for the full list.

#### `swupdate` (bbappend)
Configures the SWUpdate client for ADU use: minimal feature set with OpenSSL for signature verification. The `defconfig` for `raspberrypi4-64` is provided in `recipes-support/swupdate/swupdate/raspberrypi4-64/`.

---

### recipes-azure-device-update

#### `adu-config-setup` (bbappend)
Overrides the `pkg_postinst_ontarget` from `meta-azure-device-update` to customise symlink creation for the Raspberry Pi persistence strategy:
- Creates `/etc/adu → /adu/conf`
- Creates `/var/log/adu → /adu/logs`
- Does **not** create `/var/lib/adu/downloads` as a directory — this is handled at runtime by `adu-persistent-overlay` as a bind mount

#### `azure-device-update` (bbappend)
- Removes the `.NET DiffGenTool` runtime dependency (Python bsdiff is used instead for delta generation in the samples layer)
- Removes `/var/lib/adu/downloads` directory from the rootfs image so it can be replaced by a bind mount at runtime

#### `yocto-a-b-update`
Platform-specific A/B update handler script (`/usr/lib/adu/yocto-a-b-update.sh`). Called by the SWUpdate handler during an OTA update to:
1. Write the new rootfs to the inactive partition
2. Set `boot_partition` to the new slot
3. Set `upgrade_available=1` and reset `boot_attempts=0`
4. Trigger a reboot into the new partition

---

### classes

#### `adu-timestamp-check.bbclass`
Build-time validation class used by `adu-update-image` and `adu-delta-image` recipes to detect stale sstate-cached artifacts. If a build artifact is older than the current base image, the class automatically removes it so BitBake rebuilds it fresh. This prevents silent version mismatches when the base image changes but update/delta recipes are served from cache.

---

### wic

#### `adu-raspberrypi.wks`
WIC Kickstart file defining the physical partition layout of the SD card image. **Must be kept in sync with `recipes-core/base-files/base-files/raspberrypi4-64/fstab`** — a mismatch will cause mount failures at boot.

Current layout:
```
part /boot  --source bootimg-partition --fstype=vfat --size 2048
part /      --source rootfs            --fstype=ext4 --label rootA
part        --source rootfs            --fstype=ext4 --label rootB
part /adu                              --fstype=ext4 --size 8192
# part /data (commented out — requires GPT)
```

---

## Network Configuration

### WiFi/Bluetooth Support

WiFi/Bluetooth is **disabled by default** (requires accepting a proprietary firmware license for the BCM43455 chip).

**Enable in build** (choose one method):

```bash
# Method 1: Environment variable
export ENABLE_WIFI_BLUETOOTH=1
export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS ENABLE_WIFI_BLUETOOTH"
bitbake adu-base-image

# Method 2: Add to local.conf
echo 'ENABLE_WIFI_BLUETOOTH = "1"' >> build/conf/local.conf
```

**What gets included when enabled**: BCM43455 firmware (`synaptics-killswitch` license accepted), wpa-supplicant, connman, wireless-tools (~50MB additional).

### Quick WiFi Setup (on device)

```bash
# Connect using connman
connmanctl
> enable wifi
> scan wifi
> services
> agent on
> connect wifi_<id>_YourSSID_managed_psk
# Enter password when prompted
> quit

# Verify
ip addr show wlan0
ping -c 4 8.8.8.8
```

**Alternative (wpa_supplicant)**:
```bash
wpa_passphrase "YourSSID" "YourPassword" | tee /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
systemctl enable --now wpa_supplicant@wlan0
```

---

## Build Artifacts

The layer produces:

- **SD Card Image**: `adu-base-image-raspberrypi4-64.wic.gz` (for initial flashing)
- **OTA Update Package**: `adu-update-image-raspberrypi4-64.swu` (for cloud deployment)
- **BMAP file**: `adu-base-image-raspberrypi4-64.wic.bmap` (for bmaptool flashing)

Delta files and versioned update packages (`v2`, `v3`, `.diff`) are produced by the [`meta-azure-device-update-samples`](../meta-azure-device-update-samples/) layer.

---

## Delta Update Workflow

Delta updates reduce bandwidth by downloading only the differences between versions.

**How Delta Updates Work:**

```
Step 1: Deploy Full Update v1.0 (Initial)
┌────────────────────────────────────────┐
│ Device: v0 (factory) → v1.0            │
│ Download: v1.0.swu (800MB)             │
│ Cache: v1.0-recompressed.swu saved     │
│ Result: Device on v1.0, source cached  │
└────────────────────────────────────────┘

Step 2: Deploy Delta Update v2.0
┌────────────────────────────────────────┐
│ Device: v1.0 → v2.0                    │
│ Source: v1.0-recompressed.swu (cached) │
│ Download: v1-to-v2.diff (50MB only!)   │
│ Reconstruct: bspatch src + diff → v2.0 │
│ Verify: SHA256 hash check              │
│ Install: SWUpdate writes to partition  │
│ Cache: v2.0-recompressed.swu saved     │
│ Result: 93% bandwidth saved!           │
└────────────────────────────────────────┘
```

**Requirements:**
- SWUpdate built with `CONFIG_ZSTD=y`
- At least 3× rootfs size free on `/adu` for reconstruction
- `libadudiffapi.so` (bsdiff/bspatch) from `meta-iot-hub-device-update-delta`
- Cached previous version `.swu` at `/var/lib/adu/downloads/delta-cache/`

**Troubleshooting Delta Updates:**

```bash
# Check if delta handler is installed
ls -l /var/lib/adu/extensions/sources/libmicrosoft_delta_download_handler.so

# Check source cache
ls -l /var/lib/adu/downloads/delta-cache/

# Verify SWUpdate zstd support
swupdate --help | grep -i zstd

# Monitor delta update process
sudo journalctl -u deviceupdate-agent -f | grep -i delta

# Check disk space (need 3x rootfs)
df -h /adu/
```

**See**: [`meta-azure-device-update-samples`](../meta-azure-device-update-samples/) for delta handler scripts and versioned recipe examples.

---

## Troubleshooting

### Boot Loop After Update

**Symptoms**: Device reboots repeatedly, then reverts to old partition

**Causes**:
1. Boot health check failing
2. Critical service not starting
3. Network configuration issue

**Debug**:
```bash
# Check boot validation logs
tail -50 /var/log/adu/boot-validation.log
journalctl -u adu-boot-validation.service -b -1  # Previous boot

# Check failed services
systemctl --failed

# Run health check manually (no rollback triggered)
adu-health-check

# Or run the full validation script manually
adu-boot-validation.sh
```

**Solutions**:
- Fix the failing service
- Adjust health check criteria via `/usr/lib/adu/boot-validation.conf`
- Add a custom check plugin to `/usr/lib/adu/validation-checks.d/`
- Use `adu-confirm-boot` to manually confirm a boot as healthy during development

### Update Package Won't Install

**Symptoms**: Download succeeds, installation fails

**Debug**:
```bash
# Check SWUpdate logs
journalctl -u swupdate -n 100

# Verify hardware compatibility
cat /etc/adu-swupdate-hw-compat
# Must match hw-compatibility field in update manifest (e.g. "raspberrypi4-64 1.0")

# Check target partition space
df -h | grep mmcblk0
```

**Solutions**:
- Verify the hardware compatibility string matches the manifest
- Check that the target partition has sufficient space (rootfs size + 20%)
- Verify RSA signature if using signed updates

### Delta Reconstruction Fails

**Symptoms**: Delta download succeeds, reconstruction fails with OOM error

**Debug**:
```bash
free -h
swapon --show
df -h /adu
du -sh /adu/staging/* 2>/dev/null
```

**Solutions**:
```bash
# Increase swap size temporarily
dd if=/dev/zero of=/adu/swapfile bs=1M count=4096  # 4GB swap
chmod 600 /adu/swapfile
mkswap /adu/swapfile
swapon /adu/swapfile

# Free up staging space
rm -rf /adu/staging/*
```

### Build Issues

#### Recipe Parse Errors
**Error**: `ParseError: not a BitBake file`  
**Cause**: Using `require` with a `.bbappend` file instead of `.inc`  
**Solution**: Extract shared code to a `.inc` file and `require` that instead

#### Missing Dependencies
**Error**: `QA Issue: package requires /bin/bash, but no providers found`  
**Solution**: Add to the recipe:
```bitbake
RDEPENDS:${PN} += "bash"
```

#### WIC Image Creation Fails
**Error**: `cannot stat device tree file`  
**Solution**: Add kernel deploy dependency:
```bitbake
do_image_wic[depends] += "virtual/kernel:do_deploy"
```

#### Shared File Conflict
**Error**: `files already exist in shared area` (SWU files)  
**Solution**:
```bash
rm -f tmp/deploy/images/raspberrypi4-64/adu-update-image*.swu
bitbake adu-update-image
```

#### Stale Update Artifacts After Base Image Rebuild
**Symptom**: Update `.swu` or delta `.diff` files are older than the base image  
**Cause**: sstate cache served old artifacts  
**Solution**: The `adu-timestamp-check.bbclass` detects and auto-removes stale artifacts on the next build. If you need to force a clean immediately:
```bash
bitbake -c cleansstate adu-update-image
bitbake adu-update-image
```

**For comprehensive troubleshooting**, see [Troubleshooting Guide](docs/troubleshooting.md)

---

## Key Differences from Standard Raspberry Pi Images

1. **A/B Partitions**: Two root filesystems (rootA/rootB) instead of one
2. **Large ADU Partition**: 8GB dedicated space for updates, staging, and swap
3. **Boot Health**: Automatic validation and rollback system (configurable attempt limit)
4. **ACL Security**: `/adu` partition restricted to `adu` group (uid/gid 800)
5. **Azure Integration**: Full ADU agent with delta handler support
6. **Swap File**: Automatic 2GB swap creation for delta operations
7. **Persistent Overlay**: overlayfs-based strategy to survive A/B rootfs swaps

---

## License

See individual recipe licenses. This layer is provided under the MIT license (see LICENSE file).
