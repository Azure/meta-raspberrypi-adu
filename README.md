# meta-raspberrypi-adu

> **DISCLAIMER:**  
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

## Quick Start

This is a **Yocto meta layer** that provides Raspberry Pi-specific customizations for Azure Device Update with A/B partition support. It is **not a standalone project** — it must be used as part of a complete Yocto build environment with all required layers.

### What This Layer Provides

- Raspberry Pi BSP customizations for A/B rootfs updates
- U-Boot boot script with partition switching and rollback logic
- Boot validation service with health checks
- WIC partition layout (boot + rootA + rootB + adu)
- SWUpdate integration for OTA updates

### Layer Dependencies

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
| **meta-azure-device-update** | ADU agent & handlers | https://github.com/azure/meta-azure-device-update|
| **meta-iot-hub-device-update-delta** | Delta update support | http://github.com/azure/meta-iot-hub-device-update-delta |
| **meta-raspberrypi-adu** | **This layer** | (this project) |

### Integration Example

For a complete working example of how to integrate all these layers, see the parent repository's build scripts and `bblayers.conf` configuration.

```bash
# Typical build workflow (from parent iot-hub-device-update-yocto repo)
cd iot-hub-device-update-yocto
source yocto/poky/oe-init-build-env ~/adu_yocto/out/build

# Ensure all layers are in bblayers.conf, then:
bitbake adu-base-image

# Flash to SD card
cd ~/adu_yocto/out/build/tmp/deploy/images/raspberrypi4-64/
sudo bmaptool copy adu-base-image-raspberrypi4-64.wic.gz /dev/sdX
```

**Prerequisites**: Ubuntu 20.04+, 100GB disk space, 16GB RAM (recommended), 16GB+ SD card

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
   - U-Boot integration with boot attempt counter (max 3 attempts)
   - Minimal downtime (single reboot for partition switch, automatic rollback on failure)

3. **Delta Update Infrastructure**
   - Large dedicated partition (8GB) for delta staging and reconstruction
   - Automatic 2GB swap file for memory-constrained delta operations
   - Microsoft's libadudiffapi for efficient binary patching
   - Reduces bandwidth usage by 60-95% compared to full updates

4. **Production Security and Reliability**
   - ACL-protected ADU data partition (adu group access only)
   - Boot health monitoring with comprehensive system checks
   - Persistent health logs in `/adu/health/` directory
   - Hardware compatibility validation via swupdate

## Key Features

### Azure Device Update Agent
- **SWUpdate Handler V2**: Full rootfs updates with partition management
- **Delta Downloader**: Bandwidth-efficient differential updates
- **Script Handler**: Custom update workflows and pre/post-install hooks
- **Delivery Optimization**: Intelligent download scheduling and caching

### A/B Update System
- **Dual Rootfs Partitions**: Independent root filesystems for failsafe updates
- **U-Boot A/B Switching**: Automatic boot slot selection and rollback
- **Boot Health Validation**: Post-update system health checks
- **Automatic Rollback**: Reverts to previous partition after 3 failed boot attempts

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
- **Health Logging**: Detailed logs in `/adu/health/boot-health.log`
- **Failure Detection**: Triggers automatic rollback on validation failure

### Security and Access Control
- **ADU User/Group**: Dedicated user (uid=800) and group (gid=800)
- **Protected Health Data**: `/adu/health/` accessible only by adu group and root
- **Secure Partition Mounting**: `/adu` mounted with restrictive permissions (770)

## Partition Layout

The layer creates a 5-partition layout optimized for A/B updates, delta operations, and customer data:

| Partition | Size | Type | Mount | Purpose | A/B |
|-----------|------|------|-------|---------|-----|
| P1: boot | 2GB | FAT32 | /boot | U-Boot, kernel, device tree | ❌ Shared |
| P2: rootA | Dynamic+512MB | ext4 | / | Root filesystem - Slot A | ✅ |
| P3: rootB | Dynamic+512MB | ext4 | / | Root filesystem - Slot B | ✅ |
| P4: adu | 8GB | ext4 | /adu | ADU data, logs, swap, delta staging | ❌ Shared |
| P5: data | 1GB | FAT32 | /data | **Optional**: Customer data storage | ❌ Shared |

**Why 8GB for /adu?**
- Delta reconstruction requires ~2GB staging space (rootfs size)
- 2GB swap file for memory-constrained delta operations
- Room for logs, health data, and download cache
- Future expansion headroom

**Optional /data partition:**
- Persists across updates for application-specific data
- FAT32 for easy cross-platform access (Linux/Windows)
- Can be used for logs, configuration, user data, etc.
- Not required for ADU functionality

## Adding or Modifying Partitions

### Overview

The partition layout is defined in two synchronized files that MUST be kept in sync:

1. **WIC Kickstart File**: `wic/adu-raspberrypi.wks` - Defines physical partition layout
2. **Filesystem Table**: `recipes-core/base-files/base-files/raspberrypi4-64/fstab` - Defines mount points

**CRITICAL**: These files must match exactly, or the system will fail to boot.

### Adding a New Partition

To add a new partition (like `/data`), follow these steps:

#### Step 1: Add Partition to WIC File

Edit `wic/adu-raspberrypi.wks`:

```wks
# Add your new partition at the end
part /mynewpart --ondisk mmcblk0 --fstype=ext4 --label mynewpart --align 4096 --size 2048
```

**Key parameters:**
- `/mynewpart` - Mount point (optional, can be omitted for unmounted partitions)
- `--fstype` - Filesystem type (`ext4`, `vfat`, `ext3`, etc.)
- `--label` - Partition label for identification
- `--size` - Size in MB
- `--align 4096` - Align to 4KB boundaries (recommended for SD cards)

#### Step 2: Add Mount Entry to fstab

Edit `recipes-core/base-files/base-files/raspberrypi4-64/fstab`:

```bash
# Mount the new partition
# Device number follows partition order in .wks file
/dev/mmcblk0p6  /mynewpart   ext4    defaults,nofail   0   2
```

**Device numbering:**
- P1 = /boot (first partition in .wks)
- P2 = rootA (second partition)
- P3 = rootB (third partition)
- P4 = /adu (fourth partition)
- P5 = /data (fifth partition)
- P6 = /mynewpart (sixth partition - your new one)

**Mount options:**
- `defaults` - Standard options (rw, suid, dev, exec, auto, nouser, async)
- `nofail` - **CRITICAL**: System continues booting even if mount fails
- `0` - Dump frequency (0 = don't dump)
- `2` - fsck pass (0=skip, 1=root, 2=other filesystems)

#### Step 3: Create Mount Point Directory

The mount point directory must exist in the rootfs. Add it to `recipes-core/base-files/base-files_%.bbappend`:

```bash
do_install:append() {
    # ... existing code ...
    
    # Create mount point for new partition
    install -d ${D}/mynewpart
}
```

**Why is this needed?**
- Unlike `/adu` (created by `azure-device-update` recipe), new partitions don't have automatic directory creation
- Without the directory, systemd will fail to mount the partition
- The `nofail` option prevents boot failure, but the partition won't be mounted

#### Step 4: Rebuild Image

Clean and rebuild to apply partition changes:

```bash
cd ~/adu_yocto/iot-hub-device-update-yocto
./scripts/build.sh -o ~/adu_yocto/out/build --rebuild-base-image
```

### Removing a Partition

To remove a partition:

1. **Remove from WIC file**: Delete or comment out the `part` line
2. **Remove from fstab**: Delete or comment out the mount entry
3. **Remove mount point creation**: Remove `install -d ${D}/partition` from bbappend
4. **Rebuild**: Use `--rebuild-base-image` to apply changes

**WARNING**: Removing partitions changes device numbering for subsequent partitions!

### Key Differences: /adu vs /data Partitions

| Aspect | /adu Partition | /data Partition |
|--------|----------------|-----------------|
| **Created by** | `azure-device-update` recipe | `base-files` recipe |
| **Directory creation** | Automatic (ADUC_CONF_DIR=/adu) | Manual (base-files_%.bbappend) |
| **Filesystem** | ext4 (ACL support, journaling) | vfat (cross-platform compatibility) |
| **Size** | 4GB-8GB (for delta staging) | Variable (1GB default) |
| **Ownership** | adu:adu (800:800) | root:root |
| **Permissions** | 0770 (restricted to adu group) | 0755 (world-readable) |
| **Purpose** | ADU system data, logs, swap | Customer application data |
| **Required** | ✅ YES (ADU won't function) | ❌ NO (optional) |
| **Mount options** | `defaults` | `defaults,nofail` |
| **Post-mount setup** | `adu-setup.service` (chown/chmod) | None |

### Troubleshooting Partition Issues

#### Boot Failure After Adding Partition

**Symptom**: System fails to boot or hangs during startup

**Causes:**
1. Mount point directory doesn't exist
2. Missing `nofail` option in fstab
3. WIC and fstab partition numbers don't match

**Solution:**
```bash
# Add nofail to fstab entry
/dev/mmcblk0pX  /mountpoint   ext4    defaults,nofail   0   2

# Ensure directory is created in base-files_%.bbappend
install -d ${D}/mountpoint
```

#### Partition Not Mounting

**Symptom**: Partition exists but isn't mounted after boot

**Check:**
```bash
# On device, check if partition exists
lsblk
fdisk -l /dev/mmcblk0

# Check fstab syntax
cat /etc/fstab

# Check systemd mount unit
systemctl status mountpoint.mount

# Check system logs
journalctl -xe | grep mount
```

**Common issues:**
- Wrong device number (`/dev/mmcblk0p5` vs `/dev/mmcblk0p6`)
- Typo in fstab mount point vs directory name
- Missing `nofail` causes boot hang
- Filesystem not formatted (WIC handles this, but check if manual partitioning)

#### UID/GID Synchronization Issues

**Symptom**: Permission denied when accessing /adu partition

**Cause**: UID/GID 800:800 defined in multiple places must stay synchronized

**Files to check:**
1. `meta-azure-device-update/recipes-azure-device-update/azure-device-update/azure-device-update_git.bb`
   ```bash
   GROUPADD_PARAM:${PN} = "--gid 800 --system adu"
   USERADD_PARAM:${PN} = "--uid 800 --system -g adu ..."
   ```

2. `meta-raspberrypi-adu/recipes-core/base-files/base-files/adu-setup.service`
   ```bash
   ExecStart=/bin/chown 800:800 /adu
   ```

3. `meta-raspberrypi-adu/wic/adu-raspberrypi.wks` (if using vfat)
   ```wks
   part /adu --fstype=vfat --fsoptions "umask=0027,gid=800,uid=800"
   ```

**If you change UID/GID**, update ALL these files to match.

### MBR vs GPT Partition Tables

**CRITICAL**: The current configuration uses **MBR (Master Boot Record)** partition table, which has a **hard limit of 4 primary partitions**.

#### Current Partition Count: 4/4 (At MBR Limit)

```
P1: /boot  (2GB vfat)    - Primary
P2: rootA  (~2GB ext4)   - Primary  
P3: rootB  (~2GB ext4)   - Primary
P4: /adu   (8GB ext4)    - Primary
---
Total: 4 partitions (MBR maximum reached)
```

#### Adding a 5th Partition Requires GPT

If you need more than 4 partitions (e.g., to add `/data`), you **must** switch to **GPT (GUID Partition Table)**:

**What is GPT?**
- Modern partition table standard (vs legacy MBR)
- Supports up to 128 partitions
- Required for disks >2TB
- More reliable (redundant headers, CRC32 checksums)
- Better support for modern UEFI systems

**How to Enable GPT:**

1. Add to top of `wic/adu-raspberrypi.wks` (after comments):
   ```wks
   # Use GPT partition table to support >4 partitions
   bootloader --ptable gpt
   ```

2. Uncomment the 5th partition in `.wks` file:
   ```wks
   part /data --ondisk mmcblk0 --fstype=vfat --label data --align 4096 --size 1024
   ```

3. Uncomment the mount entry in `fstab`:
   ```bash
   /dev/mmcblk0p5  /data   vfat    defaults,nofail   0   0
   ```

4. Create `/data` directory in `base-files_%.bbappend`

5. **Test thoroughly on target hardware**

**⚠️ WARNINGS:**

1. **Raspberry Pi firmware compatibility**: 
   - Raspberry Pi 4: Should work (EEPROM supports GPT)
   - Raspberry Pi 3B+: May have limited/no GPT boot support
   - Older models: Likely won't boot from GPT
   
2. **Testing required**:
   - Test on non-production hardware first
   - Verify U-Boot can read GPT partition table
   - Check that firmware loads bootloader correctly
   - Ensure all partitions mount correctly

3. **Compatibility concerns**:
   - Some older boot ROMs only support MBR
   - Recovery tools may not recognize GPT
   - Dual-boot scenarios more complex

**Alternative: Stick with 4 Partitions**

If GPT compatibility is uncertain, keep the current 4-partition MBR layout:
- Use `/adu` for both system and application data
- Create subdirectories: `/adu/system`, `/adu/app-data`
- Adjust size of `/adu` partition as needed
- This is the **recommended approach** for maximum compatibility

### Best Practices

1. **Stay within 4 partitions for MBR compatibility** (recommended for Raspberry Pi)
2. **Always use `nofail`** for optional partitions to prevent boot failures
3. **Keep WIC and fstab synchronized** - partition numbers must match
4. **Test boot on hardware** after partition changes
5. **Document partition purpose** in comments (both WIC and fstab)
6. **Use ext4 for system partitions** (ACL support, journaling, reliability)
7. **Use vfat for data partitions** (cross-platform compatibility)
8. **Align partitions to 4096 bytes** for optimal SD card performance
9. **Leave room for growth** - don't use 100% of SD card space
10. **Test GPT thoroughly** before production use - not all Pi models support it

## Recipe Structure

### recipes-bsp
**U-Boot Boot Script Customization**
- Implements A/B partition switching logic in U-Boot
- Boot counter management (max 3 attempts per slot)
- Automatic failover to alternate partition on failure
- Reads `rpipart` environment variable (2=rootA, 3=rootB)

**Key Files:**
- [rpi-u-boot-scr/files/boot.cmd.in](recipes-bsp/rpi-u-boot-scr/files/boot.cmd.in): Boot script with A/B logic

### recipes-core
**Base Image and Filesystem Configuration**

**base-files:**
- Custom `fstab` with all 4 partitions
- `/adu` mounted with ACL restrictions (uid=800, gid=800, umask=0027)
- Automatic mounting on boot

**images:**
- `adu-base-image.bb`: Base image recipe with all ADU components
- Includes boot-health and swap services
- WIC image generation for SD card flashing

### recipes-extended
**OTA Update Image Creation**
- `adu-update-image.bb`: SWU package for OTA updates
- Contains rootfs tarball and update scripts
- Includes version metadata and signatures

### recipes-graphics
**Graphics Stack**
- Mesa, DRM/KMS drivers for Raspberry Pi
- Optional GUI components

### recipes-support
**ADU Infrastructure Services**

**adu-boot-validation:**
- Two-phase systemd service that validates successful boot (runs before ADU agent)
- **Phase 1**: Detects rollbacks, prevents boot flapping, blacklists failed workflows
- **Phase 2**: Checks critical services, filesystems, network, disk space
- Marks boot successful via `fw_setenv boot_attempts 0`
- Logs to `/adu/health/boot-validation.log`

**adu-swap:**
- Systemd service that creates 2GB swap file
- Located at `/adu/swapfile` on ADU partition
- Activates automatically on boot
- Logs to `/adu/health/swap-setup.log`

**adu-swupdate-hw-compat:**
- Installs `/etc/adu-swupdate-hw-compat` for hardware validation
- Ensures updates are compatible with device model

**swupdate:**
- Custom SWUpdate build with ZSTD compression
- ADU-specific configurations
- Delta handler support

### recipes-azure-device-update
**ADU Agent and Services**
- `azure-device-update`: ADU agent service
- Connects to Azure IoT Hub
- Manages update downloads, installation, and reporting

### wic
**WIC Image Configuration**
- `adu-raspberrypi.wks`: Partition layout definition
- Creates bootable SD card image with 4 partitions
- Generates `.wic.gz` and `.wic.bmap` for flashing

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        SD Card Layout                            │
├─────────────┬─────────────┬─────────────┬───────────┬───────────┤
│ Boot (2G)   │ RootA (2G)  │ RootB (2G)  │ ADU (8G)  │ Data (1G) │
│   (FAT32)   │   (ext4)    │   (ext4)    │  (ext4)   │  (FAT32)  │
└─────────────┴─────────────┴─────────────┴───────────┴───────────┘
       │              │             │            │           │
       │              │             │            │           └─ Customer data
       │              │             │            │              (optional)
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
1. Device boots from RootA (rpipart=2)
2. Boot-health service validates system health
3. ADU downloads delta update to /adu/
4. Delta reconstructed using v1 + diff → v2
5. SWUpdate installs v2 to RootB
6. U-Boot switches to RootB (rpipart=3)
7. Device reboots into RootB
8. Boot-health validates → success or rollback
```

## Build Artifacts

The layer produces:

- **SD Card Image**: `adu-base-image-raspberrypi4-64.wic.gz` (for initial flashing)
- **OTA Update Package**: `adu-update-image-raspberrypi4-64.swu` (for cloud deployment)
- **Delta Files**: `.diff` files for bandwidth-efficient updates
- **Import Manifests**: JSON files for Azure Device Update import

## Documentation

| Document | Description |
|----------|-------------|
| ⭐ **[Customization Guide](docs/customization.md)** | **Start here** — All A/B update customizations: partitioning, U-Boot boot script, boot validation, ADU handler integration |
| [Architecture Guide](docs/architecture.md) | Platform-agnostic A/B rootfs design patterns, storage/RAM requirements |
| [Porting Guide](docs/porting.md) | Adapt this layer to other hardware platforms |
| [U-Boot Script](docs/uboot.md) | A/B partition boot logic, variables, rollback |
| [Troubleshooting](docs/troubleshooting.md) | Common issues and fixes for boot, updates, builds |

### External Resources
- [Azure Device Update Documentation](https://learn.microsoft.com/azure/iot-hub-device-update/)
- [SWUpdate Documentation](https://sbabic.github.io/swupdate/)
- [U-Boot Documentation](https://u-boot.readthedocs.io/)

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

## Quick Start

```bash
# Clone and initialize
cd iot-hub-device-update-yocto
source yocto/poky/oe-init-build-env ~/adu_yocto/out/build

# Build base image
bitbake adu-base-image

# Flash to SD card
cd ~/adu_yocto/out/build/tmp/deploy/images/raspberrypi4-64/
sudo dd if=adu-base-image-raspberrypi4-64.wic of=/dev/sdX bs=4M status=progress
sync
```

---

## Recipes Overview

### Update Workflow Recipes

The layer includes versioned update recipes for testing A/B and delta update workflows:

| Recipe | Version | Output | Purpose |
|--------|---------|--------|---------|
| `adu-base-image.bb` | 1.0.0 | `adu-base-image-*.wic.gz` | Initial SD card image (flash once) |
| `adu-update-image.bb` | 1.0.1 | `adu-update-image-*.swu` | First OTA update package |
| `adu-update-image-v2.bb` | 2.0.0 | `adu-update-image-v2-*.swu` | Second OTA update package |
| `adu-update-image-v3.bb` | 3.0.0 | `adu-update-image-v3-*.swu` | Third OTA update package |
| `adu-delta-image.bb` | - | `*.diff` delta files | Binary diffs between versions |

**Demo Update Path**:
```
Device starts with:  v1.0.0 (base image on SD card)
                      ↓
OTA Update 1:        v1.0.1 (full 800MB SWU package)
                      ↓
OTA Update 2:        v2.0.0 (delta: 50MB diff from v1.0.1)
                      ↓
OTA Update 3:        v3.0.0 (delta: 45MB diff from v2.0.0)
```

**For production use**, copy and customize these recipes for your versioning scheme.

### Delta Update Workflow

Delta updates significantly reduce bandwidth usage by downloading only the differences between versions rather than complete images.

**Build all versions and generate deltas**:
```bash
# Build base image + 3 update versions
bitbake adu-base-image
bitbake adu-update-image       # v1.0.1
bitbake adu-update-image-v2    # v2.0.0
bitbake adu-update-image-v3    # v3.0.0

# Generate delta files (v1→v2, v2→v3, v1→v3)
bitbake adu-delta-image
```

**Output**:
- Full SWU packages: ~800MB each (depends on rootfs size)
- Delta files: ~50-150MB each (5-20% of full size)
- Import manifests: JSON files for Azure Device Update

**Delta Savings Example** (1GB rootfs):
- Full update: 800MB → 10 minutes @ 10Mbps
- Delta update: 80MB → 1 minute @ 10Mbps
- **Bandwidth savings**: 90%

**How Delta Updates Work:**

```
Step 1: Deploy Full Update v1.0 (Initial)
┌────────────────────────────────────────┐
│ Device: v0 (factory) → v1.0            │
│ Download: v1.0.swu (800MB)             │
│ Download: v1.0-recompressed.swu (800MB)│
│ Install: SWUpdate writes to partition  │
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

Step 3: Deploy Delta Update v3.0
┌────────────────────────────────────────┐
│ Device: v2.0 → v3.0                    │
│ Source: v2.0-recompressed.swu (cached) │
│ Download: v2-to-v3.diff (60MB)         │
│ Reconstruct: bspatch src + diff → v3.0 │
│ Install & cache v3.0 for future deltas │
└────────────────────────────────────────┘
```

**Key Components:**

1. **Microsoft Delta Download Handler** (`libmicrosoft_delta_download_handler.so`)
   - ADU agent extension for delta processing
   - Checks source cache for matching version
   - Downloads only diff file instead of full update
   - Reconstructs target using bspatch algorithm
   - Falls back to full download if delta fails

2. **Source Update Cache** (`/var/lib/adu/downloads/delta-cache/`)
   - Stores recompressed SWU files from previous updates
   - Required for delta reconstruction
   - Automatically managed by caching script handler

3. **Recompressed SWU Files**
   - SWU files with zstd-compressed ext4 filesystems
   - Ensures consistent compression for delta generation
   - Both source and target must use same compression

4. **Delta Generation** (on build server)
   - Uses bsdiff to create binary diffs
   - Generates deltas between all version pairs
   - Includes round-trip verification
   - Produces import manifests with relatedFiles

**Multi-Version Delta Support:**

The system can generate deltas between multiple version pairs:
```bash
# Delta image recipe generates:
v1.0-to-v2.0.diff   # For devices on v1.0
v2.0-to-v3.0.diff   # For devices on v2.0
v1.0-to-v3.0.diff   # For devices still on v1.0

# Import manifest includes all paths:
"relatedFiles": [
  { "filename": "v2-to-v3.diff", "sourceVersion": "2.0.0" },
  { "filename": "v1-to-v3.diff", "sourceVersion": "1.0.0" }
]

# Handler automatically selects optimal delta based on cached source
```

**Requirements:**

- **SWUpdate with zstd support**: Build with `CONFIG_ZSTD=y`
- **Disk space**: At least 3x rootfs size for reconstruction
- **Delta library**: `libadudiffapi.so` (bsdiff/bspatch)
- **Source cache**: Previous version must be cached

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
df -h /var/lib/adu/
```

**See**: [recipes-extended/images/](recipes-extended/images/) for recipe source code and [meta-azure-device-update-samples](../meta-azure-device-update-samples/) for delta handler scripts

---

## Network Configuration

### WiFi/Bluetooth Support

WiFi/Bluetooth is **disabled by default** (requires accepting proprietary firmware license).

**Enable in build** (choose one method):

```bash
# Method 1: Environment variable
export ENABLE_WIFI_BLUETOOTH=1
export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS ENABLE_WIFI_BLUETOOTH"
bitbake adu-base-image

# Method 2: Add to local.conf
echo 'ENABLE_WIFI_BLUETOOTH = "1"' >> build/conf/local.conf
```

**What gets included**: BCM43455 firmware, wpa-supplicant, connman, wireless-tools (~50MB)

### Quick WiFi Setup (on device)

```bash
# 1. Unblock WiFi
rfkill unblock wifi
ip link set wlan0 up

# 2. Connect using connman
connmanctl
> enable wifi
> scan wifi
> services
> agent on
> connect wifi_<id>_YourSSID_managed_psk
# Enter password when prompted
> quit

# 3. Verify
ip addr show wlan0
ping -c 4 8.8.8.8
```

**Alternative (wpa_supplicant)**:
```bash
wpa_passphrase "YourSSID" "YourPassword" | tee /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
systemctl enable --now wpa_supplicant@wlan0
```

---

## Troubleshooting

### Boot Loop After Update

**Symptoms**: Device reboots 3 times, then reverts to old partition

**Causes**:
1. Boot health check failing
2. Critical service not starting
3. Network configuration issue

**Debug**:
```bash
# Check boot validation logs
tail -50 /adu/health/boot-validation.log
journalctl -u adu-boot-validation.service -b -1  # Previous boot

# Check failed services
systemctl --failed

# Manual health check
/usr/lib/adu/adu-boot-validation.sh
```

**Solutions**:
- Fix failing service
- Adjust health check criteria in `/usr/lib/adu/adu-boot-validation.sh`
- Verify network connectivity

### Update Package Won't Install

**Symptoms**: Download succeeds, installation fails

**Debug**:
```bash
# Check SWUpdate logs
journalctl -u swupdate -n 100

# Verify hardware compatibility
cat /etc/adu-swupdate-hw-compat
# Should match hw-compatibility field in update manifest

# Check target partition space
df -h | grep mmcblk0
```

**Solutions**:
- Verify hardware compatibility string matches
- Check partition has sufficient space (rootfs size + 20%)
- Verify signature if using signed updates

### Delta Reconstruction Fails

**Symptoms**: Delta download succeeds, reconstruction fails with OOM error

**Debug**:
```bash
# Check memory and swap
free -h
swapon --show

# Check staging space
df -h /adu
du -sh /adu/staging/*

# Check delta file integrity
sha256sum /adu/downloads/delta.diff
```

**Solutions**:
```bash
# Increase swap size
dd if=/dev/zero of=/adu/swapfile bs=1M count=4096  # 4GB swap
chmod 600 /adu/swapfile
mkswap /adu/swapfile
swapon /adu/swapfile

# Free up staging space
rm -rf /adu/staging/*

# Re-download delta if corrupted
```

### Build Issues

#### Recipe Parse Errors

**Error**: `ParseError: not a BitBake file`

**Cause**: Using `require` with `.bbappend` file instead of `.inc`

**Solution**: Create `.inc` file with shared code, require from `.bbappend`

#### Missing Dependencies

**Error**: `QA Issue: package requires /bin/bash, but no providers found`

**Solution**: Add to recipe:
```bitbake
RDEPENDS:${PN} += "bash"
```

#### WIC Image Creation Fails

**Error**: `cannot stat device tree file`

**Solution**: Add kernel dependency:
```bitbake
do_image_wic[depends] += "virtual/kernel:do_deploy"
```

**Force rebuild**:
```bash
bitbake -c cleansstate virtual/kernel
bitbake virtual/kernel
bitbake adu-base-image
```

#### Shared File Conflict

**Error**: `files already exist in shared area` (SWU files)

**Solution**:
```bash
# Remove old deployment artifacts
rm -f tmp/deploy/images/raspberrypi4-64/adu-update-image-v*.swu
rm -f tmp/deploy/images/raspberrypi4-64/manifest-*-adu-update-image-v*.deploy

# Rebuild
bitbake adu-update-image-v1
```

**For comprehensive troubleshooting**, see [Troubleshooting Guide](docs/troubleshooting.md)

---

## Key Differences from Standard Raspberry Pi Images

1. **A/B Partitions**: Two root filesystems instead of one
2. **Large ADU Partition**: 8GB dedicated space for updates and swap
3. **Optional Data Partition**: 1GB customer data storage (FAT32)
4. **Boot Health**: Automatic validation and rollback system
5. **ACL Security**: Restricted access to ADU data
6. **Azure Integration**: Full ADU agent with delta support
7. **Swap File**: Automatic creation for delta operations

## License

See individual recipe licenses. This layer is provided under the MIT license (see LICENSE file).
