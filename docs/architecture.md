# Azure Device Update A/B Rootfs Architecture Guide

**Platform-Agnostic Design Guidelines for Device Builders**

> **Target Audience**: Hardware vendors, BSP developers, and device builders integrating Azure Device Update into embedded Linux systems using Yocto/OpenEmbedded.

---

## Table of Contents

- [Introduction](#introduction)
- [Core Concepts](#core-concepts)
- [System Requirements](#system-requirements)
- [Partition Layout Design](#partition-layout-design)
- [Bootloader Integration](#bootloader-integration)
- [Boot Health Verification](#boot-health-verification)
- [Delta Update Support](#delta-update-support)
- [Integration Checklist](#integration-checklist)
- [Security Considerations](#security-considerations)
- [Troubleshooting Patterns](#troubleshooting-patterns)
- [Reference Implementation](#reference-implementation)

---

## Introduction

### What is A/B Rootfs Update Architecture?

A/B (dual-boot) rootfs architecture is a firmware update strategy that maintains **two complete root filesystem partitions**:
- **Partition A** (active): Currently running system
- **Partition B** (inactive): Target for next update

During an update:
1. Device downloads and installs update to **inactive** partition
2. Bootloader switches to newly updated partition on next reboot
3. If boot fails, bootloader automatically reverts to previous working partition

### Benefits

| Benefit | Description |
|---------|-------------|
| **Atomicity** | Update either succeeds completely or fails safely - no partial updates |
| **Minimal Downtime** | Single reboot to apply update (vs multiple reboots for in-place updates) |
| **Automatic Rollback** | Boot failures trigger automatic revert to known-good partition |
| **Power-Loss Safety** | Running system unaffected during update; corruption only impacts inactive partition |
| **Zero-Risk Testing** | Can test update before committing, with instant rollback capability |

### When to Use A/B Updates

**Recommended for**:
- Mission-critical devices (medical, industrial, automotive)
- Remote/inaccessible devices (difficult physical access for recovery)
- Large fleets requiring high reliability
- Devices with sufficient storage for dual rootfs

**Consider alternatives if**:
- Storage severely constrained (can't fit 2x rootfs)
- Update frequency is very high (OSTree may be better)
- Device has reliable recovery mechanism (USB boot, network recovery)

### Alternatives to A/B

- **In-place updates**: Single rootfs, updated directly (higher risk)
- **OSTree**: Git-like filesystem versioning (lower storage overhead)
- **Container-based**: Application updates without full rootfs replacement
- **Golden Image + Recovery**: Fallback to factory image on failure

---

## Core Concepts

### 2.1 Dual Rootfs Partitions

```
┌─────────────────────────────────────┐
│         Storage Device              │
├─────────────────────────────────────┤
│  Boot Partition (Shared)            │  ← Kernel, bootloader config
├─────────────────────────────────────┤
│  RootFS A (Active)                  │  ← Currently running
├─────────────────────────────────────┤
│  RootFS B (Inactive)                │  ← Update target
├─────────────────────────────────────┤
│  ADU Working Partition (Shared)     │  ← Downloads, logs, swap
├─────────────────────────────────────┤
│  Data Partition (Optional, Shared)  │  ← Application data
└─────────────────────────────────────┘
```

**Key Principles**:
- **Independence**: Each rootfs partition is complete and bootable independently
- **Symmetry**: Both A and B partitions have identical size and configuration
- **Isolation**: Update to inactive partition doesn't affect running system
- **Shared Resources**: Boot partition, persistent data, and ADU workspace shared between both rootfs

### 2.2 Update Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│                    Update Workflow                               │
└─────────────────────────────────────────────────────────────────┘

1. DOWNLOAD PHASE (Active: A, Target: B)
   ┌──────────┐
   │  Device  │──────> Download update package to /adu partition
   │ Running  │        (Running system unaffected)
   │  on A    │
   └──────────┘

2. INSTALLATION PHASE (Active: A, Target: B)
   ┌──────────┐
   │  Device  │──────> Write update to Partition B
   │ Running  │        Extract files, verify checksums
   │  on A    │        Update bootloader flag: "boot_from=B"
   └──────────┘

3. REBOOT & SWITCH (Active: B, Old: A)
   ┌──────────┐
   │ Bootloader│─────> Read flag: boot_from=B
   │   U-Boot │       Boot into Partition B
   └──────────┘       Increment boot_attempts counter

4. HEALTH CHECK (Active: B, Old: A)
   ┌──────────┐
   │  Device  │──────> Validate: network, services, mounts
   │ Booted   │        If SUCCESS: Reset boot_attempts=0
   │  from B  │        If FAIL: Reboot (attempt 2 of 3)
   └──────────┘

5a. SUCCESS PATH
   ┌──────────┐
   │  Health  │──────> Mark boot successful
   │  Check   │        boot_attempts=0, stay on B
   │  PASSED  │        Partition A becomes target for next update
   └──────────┘

5b. FAILURE PATH (after 3 attempts)
   ┌──────────┐
   │ Bootloader│─────> Rollback: switch back to A
   │  Detects │       Reset boot_attempts=0
   │  Failure │       Device runs on last known-good partition
   └──────────┘
```

### 2.3 Atomic Update Guarantees

**What "Atomic" Means in A/B Context**:

✅ **Guaranteed**:
- Running system never modified during update
- Either complete valid image installed, or no change at all
- Automatic rollback on boot failure
- No intermediate "partially updated" state

⚠️ **NOT Guaranteed** (requires additional measures):
- Protection against power loss during partition write (use `fsync()`)
- Data partition consistency (application responsibility)
- Bootloader corruption (use redundant bootloader or A/B bootloader)

**Power-Loss Scenarios**:

| Phase | Power Loss Impact | Recovery |
|-------|-------------------|----------|
| Download | Download restarts, no system impact | Automatic retry |
| Installation to B | Partition B may be corrupt, A unaffected | Rollback to A (automatic) |
| Bootloader update | **CRITICAL** - may brick device | Use redundant bootloader or SPL |
| First boot from B | Partition B incomplete, A intact | Automatic rollback after 3 attempts |

---

## System Requirements

### 3.1 Hardware Requirements

#### Minimum Storage Calculation

```
Total Storage = Boot + (2 × RootFS) + ADU Working + Overhead + Optional Data

Example for 1GB rootfs:
  Boot:        100 MB  (kernel, dtb, bootloader config)
  RootFS A:    1.2 GB  (1GB + 20% overhead for updates/logs)
  RootFS B:    1.2 GB  (identical to A)
  ADU Working: 2-4 GB  (downloads + delta staging + swap)
  Overhead:    200 MB  (filesystem metadata, alignment)
  ────────────────────
  Minimum:     ~5 GB

  Optional Data: +1-10 GB (application-specific)
```

**Storage Requirements by Rootfs Size**:

| Rootfs Size | Minimum Total Storage | Recommended |
|-------------|----------------------|-------------|
| 256 MB | 1.5 GB | 2 GB |
| 512 MB | 2.5 GB | 4 GB |
| 1 GB | 5 GB | 8 GB |
| 2 GB | 9 GB | 16 GB |

**Formula**:
```
Min_Storage = 100MB + (2 × Rootfs × 1.2) + (2 × Rootfs) + 200MB
            = 100MB + (4.4 × Rootfs) + 200MB
            = 300MB + (4.4 × Rootfs)
```

Where `2 × Rootfs` is for ADU working partition (delta staging).

#### RAM Requirements

| Feature | Minimum RAM | Recommended |
|---------|-------------|-------------|
| Base ADU Agent | 256 MB | 512 MB |
| **With Delta Updates** | **512 MB** | **1 GB+** |
| With Swap (delta) | 256 MB + Swap | 512 MB + 2GB Swap |

**Delta Reconstruction Memory**:
- Requires RAM approximately equal to rootfs size for `bspatch`
- If insufficient RAM, use swap file (see [Delta Update Support](#delta-update-support))

#### Boot Mechanism

**Required Capabilities**:
- ✅ Persistent environment variable storage (U-Boot, GRUB, custom)
- ✅ Conditional boot logic (if/else, boot counter)
- ✅ Multiple partition boot support
- ✅ Runtime configuration modification

**Supported Bootloaders**:
- U-Boot (most common for ARM/embedded)
- GRUB (x86, some ARM)
- Barebox (advanced embedded)
- Custom bootloader (if meets requirements)

### 3.2 Software Dependencies

#### Essential Packages

| Component | Purpose | Yocto Recipe | Alternative |
|-----------|---------|--------------|-------------|
| **SWUpdate** | Update engine | `meta-swupdate` | RAUC, Mender |
| **Azure IoT SDK** | Cloud connectivity | `meta-azure-device-update` | - |
| **systemd** | Init system, service management | `poky/meta` | - |
| **libubootenv** | U-Boot env manipulation | `u-boot-fw-utils` | Custom tools |
| **bsdiff/bspatch** | Delta binary patching | `meta-iot-hub-device-update-delta` | - |
| **zstd** | Compression | `meta-openembedded/meta-oe` | gzip, xz |

#### Filesystem Support

**Root Filesystems** (RootFS A/B):
- **ext4** (recommended): Journaling, ACL, attr support, mature
- ext3: Legacy support
- btrfs: Advanced (snapshots), higher overhead
- xfs: Good for large files

**Boot Partition**:
- **FAT32/vfat** (most compatible): Required for most bootloaders
- ext4: Possible for some bootloaders (U-Boot with ext4 support)

**ADU Working Partition**:
- **ext4** (required): ACL support needed for security
- Must support large files (update packages can be 1-2GB)

### 3.3 Network Requirements

- **TLS 1.2+**: Azure IoT Hub security requirement
- **DNS**: Service discovery
- **NTP or RTC**: Accurate time for certificate validation (±5 minutes tolerance)
- **Bandwidth**: Depends on update strategy
  - Full updates: ~500KB/s minimum for 1GB update in reasonable time
  - Delta updates: ~50KB/s sufficient for 50MB deltas

**Firewall Requirements** (outbound only):
- Port 443 (HTTPS): Azure IoT Hub, Device Update service
- Port 5671 (AMQPS): IoT Hub AMQP protocol
- Port 8883 (MQTTS): IoT Hub MQTT protocol

---

## Partition Layout Design

### 4.1 Essential Partitions

#### Boot Partition (Shared)

**Purpose**: Store kernel, device tree, bootloader configuration

**Characteristics**:
- Filesystem: FAT32 (bootloader compatibility)
- Mounted: `/boot` (read-only preferred)
- Shared: Both rootfs partitions use same boot files
- Size: 100-200 MB

**Contents**:
```
/boot/
├── vmlinuz          # Kernel image
├── initrd.img       # Initial ramdisk (optional)
├── dtb/             # Device tree blobs
│   └── myboard.dtb
├── boot.scr         # U-Boot script (compiled from boot.cmd)
├── uEnv.txt         # U-Boot environment variables
└── config.txt       # Board-specific config (e.g., Raspberry Pi)
```

**U-Boot Environment Storage**:
- Option 1: Raw flash offset (defined in `fw_env.config`)
- Option 2: File in FAT32 partition (`/boot/uboot.env`)
- Must persist across reboots

#### RootFS A & B (Dual Partitions)

**Purpose**: Complete operating system, applications, ADU agent

**Characteristics**:
- Filesystem: ext4
- Mounted: `/` (active partition only)
- Size: Base rootfs + 20-30% overhead
- Identical: Both partitions must have same size

**Size Calculation**:
```
Rootfs_Partition_Size = Uncompressed_Image_Size × 1.25

Example:
  Compressed .ext4.gz:  800 MB
  Uncompressed:        1000 MB
  Partition size:      1250 MB (1.22 GB)
```

**Overhead Reasons**:
- Filesystem metadata (inodes, journal)
- Future updates may be slightly larger
- Logs generated after boot
- Package manager cache (if used)

#### ADU Working Partition (Shared)

**Purpose**: Update downloads, delta staging, logs, swap

**Characteristics**:
- Filesystem: ext4 with ACL support
- Mounted: `/adu` (or `/var/lib/adu`)
- Permissions: `drwxrwx--- root:adu` (770)
- Size: 2-4 GB minimum

**Size Calculation**:
```
ADU_Size = Download_Space + Delta_Staging + Swap + Logs + Overhead

Components:
  Download Space:  1.2 × Largest_Update_Package
  Delta Staging:   2 × Rootfs_Size  (for reconstruction)
  Swap:            2 GB (if delta enabled)
  Logs:            100 MB
  Overhead:        200 MB
  
Example for 1GB rootfs with delta:
  Download:   1.2 GB (1GB SWU package)
  Staging:    2.0 GB (worst case reconstruction)
  Swap:       2.0 GB
  Logs:       0.1 GB
  Overhead:   0.2 GB
  ─────────────────
  Total:      5.5 GB → Round to 6 GB
```

**Directory Structure**:
```
/adu/
├── downloads/          # Update package downloads
├── staging/            # Delta reconstruction workspace
├── logs/               # ADU agent logs
├── health/             # Boot health logs
├── swapfile            # Swap file for delta operations
└── config/             # Persistent ADU configuration
```

**Access Control**:
```bash
# Create ADU user and group
groupadd -g 800 adu
useradd -u 800 -g 800 -d /var/lib/adu -s /bin/false adu

# Set permissions
chown -R root:adu /adu
chmod 770 /adu
chmod 750 /adu/health  # Health logs readable by adu group
```

### 4.2 Optional Partitions

#### Data Partition (Persistent Application Data)

**Purpose**: Store application data that persists across updates

**When to Use**:
- Application logs
- Configuration files
- User data
- Database files

**Characteristics**:
- Filesystem: ext4 or FAT32 (for cross-platform access)
- Mounted: `/data` or `/mnt/data`
- Size: Application-specific (1-10 GB typical)

**NOT for**:
- System logs (use `/adu/logs`)
- ADU configuration (use `/adu/config`)
- Temporary files (use `/tmp` or `/var/tmp`)

### 4.3 Partition Table Example

**GPT (GUID Partition Table)** - Recommended for >2TB or UEFI systems:

```
Disk: /dev/mmcblk0  (16 GB SD card)

Partition    Size       Type      Mount       Purpose
────────────────────────────────────────────────────────────
/dev/mmcblk0p1   100 MB     FAT32     /boot       Boot files
/dev/mmcblk0p2   2.5 GB     ext4      /           RootFS A
/dev/mmcblk0p3   2.5 GB     ext4      /           RootFS B
/dev/mmcblk0p4   6.0 GB     ext4      /adu        ADU working
/dev/mmcblk0p5   5.0 GB     ext4      /data       App data (optional)
```

**MBR (Master Boot Record)** - Legacy, <2TB:

```
Partition    Size       Type      Primary/Extended
────────────────────────────────────────────────────
/dev/sda1    100 MB     FAT32     Primary
/dev/sda2    2.5 GB     ext4      Primary
/dev/sda3    2.5 GB     ext4      Primary
/dev/sda4    Extended   -         Extended
  /dev/sda5  6.0 GB     ext4      Logical (in sda4)
  /dev/sda6  5.0 GB     ext4      Logical (in sda4)
```

**Yocto WIC Configuration Example**:

```python
# File: my-board-adu.wks
part /boot --source bootimg-partition --fstype=vfat --label boot --size=100M --align 4096
part /     --source rootfs --fstype=ext4 --label rootA --size=2500M --align 4096
part /     --source rootfs --fstype=ext4 --label rootB --size=2500M --align 4096
part /adu  --source empty --fstype=ext4 --label adu --size=6000M --align 4096
part /data --source empty --fstype=ext4 --label data --size=5000M --align 4096
```

---

## Bootloader Integration

### 5.1 Boot Selection Logic

**Core Requirements**:
1. **Persistent State**: Store which partition to boot (survives reboots)
2. **Boot Counter**: Track failed boot attempts
3. **Fallback**: Automatically revert after N failed attempts (typically 3)
4. **Success Marker**: Application signals successful boot

**Environment Variables Pattern**:

| Variable | Type | Purpose | Values |
|----------|------|---------|--------|
| `boot_partition` | String | Active partition | "A", "B", "2", "3" |
| `boot_attempts` | Integer | Failed boot counter | 0-3 |
| `boot_success` | Boolean | Last boot status | 0 (fail), 1 (success) |

### 5.2 Boot Process Flow

```
┌─────────────────────────────────────────────────────────────┐
│              Bootloader Decision Tree                        │
└─────────────────────────────────────────────────────────────┘

START
  │
  ├─→ Read: boot_partition, boot_attempts, boot_success
  │
  ├─→ [IF] boot_attempts >= 3
  │     │
  │     ├─→ [ROLLBACK LOGIC]
  │     │    ├─→ IF boot_partition == "A" THEN boot_partition = "B"
  │     │    └─→ IF boot_partition == "B" THEN boot_partition = "A"
  │     │
  │     └─→ Reset: boot_attempts = 0
  │
  ├─→ [IF] boot_success == 0 (previous boot failed)
  │     │
  │     └─→ Increment: boot_attempts += 1
  │
  ├─→ Set kernel command line:
  │    root=/dev/mmcblk0p{boot_partition}
  │
  ├─→ Save environment: boot_success = 0
  │
  └─→ Boot kernel

   [System Boots]
  
   [Boot Health Service Runs]
  
   [IF Health Check PASSED]
      └─→ Execute: fw_setenv boot_attempts 0
      └─→ Execute: fw_setenv boot_success 1
  
   [IF Health Check FAILED]
      └─→ System remains with boot_success=0
      └─→ On next reboot, boot_attempts increments
```

### 5.3 U-Boot Implementation Example

**boot.cmd (pseudo-code)**:

```bash
# Load environment variables
if test ! -e mmc 0:1 uboot.env; then
    # First boot, initialize
    setenv boot_partition 2      # Start with partition 2 (RootFS A)
    setenv boot_attempts 0
    setenv boot_success 1
    saveenv
fi

# Check if we need to rollback (3 failed attempts)
if test ${boot_attempts} -ge 3; then
    echo "ROLLBACK: Too many failed boot attempts"
    
    # Toggle partition
    if test ${boot_partition} = 2; then
        setenv boot_partition 3   # Switch to RootFS B
    else
        setenv boot_partition 2   # Switch to RootFS A
    fi
    
    # Reset counter
    setenv boot_attempts 0
    setenv boot_success 0
    saveenv
fi

# Increment boot attempt if last boot failed
if test ${boot_success} = 0; then
    setexpr boot_attempts ${boot_attempts} + 1
    echo "Boot attempt ${boot_attempts} of 3"
    saveenv
fi

# Set kernel command line with correct root partition
setenv bootargs "root=/dev/mmcblk0p${boot_partition} rootwait ro"

# Mark boot as in-progress (health check will set to 1 if successful)
setenv boot_success 0
saveenv

# Boot kernel
load mmc 0:1 ${kernel_addr_r} vmlinuz
load mmc 0:1 ${fdt_addr} dtb/myboard.dtb
bootz ${kernel_addr_r} - ${fdt_addr}
```

**GRUB Implementation Example**:

```bash
# /boot/grub/grub.cfg

# Read environment
load_env

# Default to partition A if not set
if [ -z "$boot_partition" ]; then
    set boot_partition="A"
    set boot_attempts=0
    set boot_success=1
    save_env boot_partition boot_attempts boot_success
fi

# Rollback logic
if [ "$boot_attempts" -ge "3" ]; then
    echo "ROLLBACK: Switching partitions"
    if [ "$boot_partition" = "A" ]; then
        set boot_partition="B"
    else
        set boot_partition="A"
    fi
    set boot_attempts=0
    save_env boot_partition boot_attempts
fi

# Increment attempt counter if previous boot failed
if [ "$boot_success" = "0" ]; then
    expr boot_attempts $boot_attempts + 1
    save_env boot_attempts
fi

# Set boot success to 0 (health check will set to 1)
set boot_success=0
save_env boot_success

# Boot appropriate partition
if [ "$boot_partition" = "A" ]; then
    set root=/dev/sda2
else
    set root=/dev/sda3
fi

linux /vmlinuz root=$root ro quiet
initrd /initrd.img
boot
```

### 5.4 Environment Configuration

**U-Boot `fw_env.config`**:

```
# Device    Offset    Size      Sector Size
/dev/mmcblk0  0x400000  0x20000   0x200
```

Or for file-based environment:

```
# File path              Offset    Size
/boot/uboot.env          0x0       0x20000
```

**Tools for Runtime Manipulation**:

```bash
# Read environment
fw_printenv boot_partition
fw_printenv boot_attempts

# Write environment (from Linux userspace)
fw_setenv boot_partition 3
fw_setenv boot_attempts 0
fw_setenv boot_success 1
```

---

## Boot Health Verification

### 6.1 Health Check Architecture

**Purpose**: Validate that the new system is functioning correctly before marking boot as successful.

**When to Run**: After systemd reaches `multi-user.target` or `graphical.target`

**Validation Categories**:

| Category | What to Check | Example |
|----------|---------------|---------|
| **Services** | Critical services running | ADU agent, network, logging |
| **Filesystems** | All required mounts present | `/`, `/boot`, `/adu`, `/data` |
| **Network** | Connectivity functional | Ping gateway, DNS resolution |
| **Storage** | Sufficient free space | Root: >100MB, ADU: >500MB |
| **Device Health** | Hardware-specific checks | Temperature, sensors |

**Success Criteria**:
- ALL critical checks must pass
- Non-critical checks can fail with warnings
- Timeout: 60-120 seconds after boot

**On Success**:
```bash
fw_setenv boot_attempts 0    # Reset counter
fw_setenv boot_success 1     # Mark as successful
logger "Boot health check PASSED - system stable"
```

**On Failure**:
```bash
# Do NOT reset boot_attempts
# boot_success remains 0
logger "Boot health check FAILED - will retry or rollback"
# System will reboot, bootloader increments boot_attempts
reboot
```

### 6.2 systemd Integration

**Service File**: `adu-boot-validation.service`

> **Note**: The actual implementation (`adu-boot-validation`) includes two phases:
> - **Phase 1**: Rollback detection, flapping prevention, workflow blacklisting
> - **Phase 2**: Health checks (services, filesystems, network, disk space)
>
> The service runs **Before=deviceupdate-agent.service** to ensure rollback detection
> completes before the ADU agent starts (preventing retry of failed workflows).

```ini
[Unit]
Description=ADU Boot Validation (rollback detection + health checks)
After=network-online.target multi-user.target
Wants=network-online.target
# IMPORTANT: Run BEFORE ADU agent starts
Before=deviceupdate-agent.service

[Service]
Type=oneshot
ExecStart=/usr/lib/adu/adu-boot-validation.sh
RemainAfterExit=yes
TimeoutStartSec=300
# On failure, trigger reboot
FailureAction=reboot

[Install]
WantedBy=multi-user.target
```

**Validation Script**: `/usr/lib/adu/adu-boot-validation.sh`

```bash
#!/bin/bash
# ADU Boot Validation Script (Two-Phase)

HEALTH_LOG="/adu/health/boot-validation.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() {
    echo "[$TIMESTAMP] $1" | tee -a "$HEALTH_LOG"
}

fail() {
    log "FAIL: $1"
    exit 1
}

log "=== Boot Health Check Started ==="

# 1. Check critical services
for service in deviceupdate-agent systemd-networkd; do
    if ! systemctl is-active --quiet "$service"; then
        fail "Service $service not running"
    fi
    log "✓ Service $service running"
done

# 2. Check filesystems
for mount in / /boot /adu; do
    if ! mountpoint -q "$mount"; then
        fail "Filesystem $mount not mounted"
    fi
    log "✓ Filesystem $mount mounted"
done

# 3. Check network connectivity
if ! ping -c 3 -W 5 8.8.8.8 >/dev/null 2>&1; then
    fail "Network connectivity failed"
fi
log "✓ Network connectivity OK"

# 4. Check DNS resolution
if ! nslookup google.com >/dev/null 2>&1; then
    fail "DNS resolution failed"
fi
log "✓ DNS resolution OK"

# 5. Check storage space
ROOT_FREE=$(df / | awk 'NR==2 {print $4}')
if [ "$ROOT_FREE" -lt 102400 ]; then  # 100MB in KB
    fail "Insufficient root space: ${ROOT_FREE}KB"
fi
log "✓ Root filesystem space OK: ${ROOT_FREE}KB"

ADU_FREE=$(df /adu | awk 'NR==2 {print $4}')
if [ "$ADU_FREE" -lt 512000 ]; then  # 500MB in KB
    fail "Insufficient ADU space: ${ADU_FREE}KB"
fi
log "✓ ADU partition space OK: ${ADU_FREE}KB"

# 6. Mark boot as successful
if command -v fw_setenv >/dev/null 2>&1; then
    fw_setenv boot_attempts 0
    fw_setenv boot_success 1
    log "✓ Boot marked as successful"
else
    log "⚠ Warning: fw_setenv not available, cannot update boot flags"
fi

log "=== Boot Health Check PASSED ==="
exit 0
```

**Make Executable**:
```bash
chmod +x /usr/lib/adu/adu-boot-validation.sh
```

### 6.3 Logging and Diagnostics

**Health Log Location**: `/adu/health/boot-validation.log`

**Log Rotation**:
```bash
# /etc/logrotate.d/adu-health
/adu/health/boot-validation.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root adu
}
```

**Viewing Logs**:
```bash
# Latest health check
tail -20 /adu/health/boot-validation.log

# All boot attempts since last successful boot
journalctl -u adu-boot-validation.service -b

# Health check history
grep "Boot Validation" /adu/health/boot-validation.log
```

---

## Delta Update Support

### 7.1 Delta Processing Requirements

**What are Delta Updates?**

Instead of downloading entire rootfs image (500MB-2GB), device downloads only the **binary difference** (diff) between current and target versions, typically 5-20% of full image size.

**Example**:
```
Full Update:  Current v1.0 → Download 800MB → Install v2.0
Delta Update: Current v1.0 → Download 50MB diff → Reconstruct v2.0 locally
```

**Memory Requirements**:

Delta reconstruction using `bspatch` requires approximately:
```
RAM_Required = Target_Image_Size (uncompressed)

Example for 1GB rootfs:
  Minimum RAM: 1 GB
  With 512MB physical RAM: Need 512MB swap
  Recommended: 2GB swap for safety margin
```

**CPU Impact**:
- Delta reconstruction is CPU-intensive (compression/decompression)
- Arm Cortex-A53 (1.5GHz quad-core): ~5-10 minutes for 1GB image
- Slower CPUs: May take 20-30 minutes

### 7.2 Storage Requirements

**ADU Partition Sizing for Delta**:

```
ADU_Size = Download + Staging + Swap + Overhead

Components:
1. Download Storage: 1.2 × Max_Delta_Size
   - Max delta typically 20-30% of rootfs
   - Example: 1GB rootfs → 300MB delta × 1.2 = 360MB

2. Staging Space: 2 × Rootfs_Size
   - Source image: Rootfs_Size (extracted from current partition)
   - Target image: Rootfs_Size (reconstructed)
   - Example: 2 × 1GB = 2GB

3. Swap File: 2GB (if physical RAM < Rootfs_Size)

4. Overhead: 200MB (logs, temp files)

Total for 1GB rootfs with delta:
  360MB + 2GB + 2GB + 200MB = 4.5GB → Round to 5GB
```

**Why 2× Rootfs for Staging?**
- Need to extract current image from partition A
- Simultaneously reconstruct target image
- Both must exist during patching process

### 7.3 Swap File Configuration

**Automatic Swap Creation Service**:

`adu-swap.service`:
```ini
[Unit]
Description=ADU Swap File Creation
Before=deviceupdate-agent.service
ConditionPathExists=!/adu/swapfile

[Service]
Type=oneshot
ExecStart=/usr/bin/create-adu-swap
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

**Swap Creation Script**: `/usr/bin/create-adu-swap`

```bash
#!/bin/bash
SWAP_FILE="/adu/swapfile"
SWAP_SIZE_MB=2048  # 2GB

# Check if swap already exists
if [ -f "$SWAP_FILE" ]; then
    echo "Swap file already exists"
    exit 0
fi

# Create swap file
echo "Creating ${SWAP_SIZE_MB}MB swap file..."
dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$SWAP_SIZE_MB status=progress

# Set permissions (important for security)
chmod 600 "$SWAP_FILE"

# Format as swap
mkswap "$SWAP_FILE"

# Enable swap
swapon "$SWAP_FILE"

# Add to fstab for persistence
if ! grep -q "$SWAP_FILE" /etc/fstab; then
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
fi

echo "Swap file created and enabled"
```

**Verify Swap**:
```bash
# Check swap status
swapon --show
free -h

# Expected output:
# NAME          TYPE  SIZE USED PRIO
# /adu/swapfile file  2G   0B   -2
```

### 7.4 Delta Workflow

```
┌──────────────────────────────────────────────────────────────┐
│              Delta Update Workflow                           │
└──────────────────────────────────────────────────────────────┘

1. DOWNLOAD DELTA (Active: A)
   ┌──────────┐
   │   ADU    │──────> Download v1-to-v2.diff (50MB)
   │  Agent   │        Verify SHA256 checksum
   └──────────┘        Store in /adu/downloads/

2. EXTRACT SOURCE (Active: A, from partition A)
   ┌──────────┐
   │   ADU    │──────> Extract current rootfs from /dev/mmcblk0p2
   │  Agent   │        Mount as loop device
   └──────────┘        Copy to /adu/staging/source/ (1GB)

3. RECONSTRUCT TARGET (In /adu/staging/)
   ┌──────────┐
   │ bspatch  │──────> Apply diff: source + delta → target
   │  Tool    │        Uses swap if needed
   └──────────┘        Output: /adu/staging/target/rootfs.ext4 (1GB)

4. VERIFY TARGET
   ┌──────────┐
   │   ADU    │──────> Compute SHA256 of reconstructed image
   │  Agent   │        Compare with manifest hash
   └──────────┘        If mismatch: ABORT, retry download

5. INSTALL TO PARTITION B
   ┌──────────┐
   │SWUpdate  │──────> Write verified image to /dev/mmcblk0p3
   │  Engine  │        Set bootloader: boot_partition=3
   └──────────┘        Cleanup staging area

6. REBOOT & VERIFY (same as full update)
```

**Advantages**:
- Bandwidth: 50MB vs 800MB (93% reduction)
- Time: Download ~30 seconds vs 10 minutes (on 10Mbps)
- Cost: Lower cellular/metered network costs

**Disadvantages**:
- Complexity: More failure modes (source extraction, patching)
- Time: Reconstruction takes 5-15 minutes
- Storage: Need 2× rootfs staging space
- RAM/Swap: Higher memory requirements

### 7.5 Delta Libraries

**bsdiff/bspatch**:
- Industry-standard binary diff algorithm
- Yocto recipe: `meta-iot-hub-device-update-delta/recipes-support/bsdiff`
- Usage:
  ```bash
  # Generate delta (on build server)
  bsdiff old.ext4 new.ext4 delta.diff
  
  # Apply delta (on device)
  bspatch old.ext4 new.ext4 delta.diff
  ```

**Azure Delta Libraries**:
- `libadudiffapi`: Microsoft's delta generation/application library
- Optimized for embedded systems
- Recipe: `meta-iot-hub-device-update-delta/recipes-azure/iot-hub-device-update-delta-processor`

**Compression**:
- Deltas typically compressed with zstd or xz
- Further reduces size by 20-40%
- Example: 50MB delta → 30MB compressed

---

## Integration Checklist

### Development Phase

- [ ] **Partition Layout**
  - [ ] Design partition sizes based on rootfs
  - [ ] Create WIC configuration for Yocto
  - [ ] Test partition creation on target hardware

- [ ] **Bootloader Configuration**
  - [ ] Choose bootloader (U-Boot recommended)
  - [ ] Implement A/B boot script with rollback logic
  - [ ] Configure environment variable storage
  - [ ] Test boot switching manually

- [ ] **Filesystem Setup**
  - [ ] Configure ext4 for rootfs with journaling
  - [ ] Set up ADU partition with ACL support
  - [ ] Create mount points in /etc/fstab
  - [ ] Test filesystem permissions

### Integration Phase

- [ ] **ADU Agent Installation**
  - [ ] Add meta-azure-device-update layer
  - [ ] Configure ADU agent (IoT Hub connection string)
  - [ ] Install SWUpdate engine
  - [ ] Configure update handlers (rootfs, delta)

- [ ] **Boot Health Service**
  - [ ] Create boot health check script
  - [ ] Configure systemd service
  - [ ] Test health check success path
  - [ ] Test health check failure (simulated)

- [ ] **Delta Support** (Optional)
  - [ ] Add meta-iot-hub-device-update-delta layer
  - [ ] Create swap file service
  - [ ] Configure delta staging space
  - [ ] Test delta reconstruction locally

### Testing Phase

- [ ] **Functional Testing**
  - [ ] Test full update: A → B
  - [ ] Test full update: B → A
  - [ ] Test update with device reboot during installation
  - [ ] Test delta update (if enabled)
  - [ ] Test network loss during download

- [ ] **Rollback Testing**
  - [ ] Simulate boot failure (corrupted partition)
  - [ ] Verify automatic rollback after 3 attempts
  - [ ] Test manual rollback trigger
  - [ ] Verify health check failure triggers rollback

- [ ] **Stress Testing**
  - [ ] 10 consecutive updates without reboot
  - [ ] Update during high system load
  - [ ] Storage exhaustion scenarios
  - [ ] Power loss during update (if possible)

- [ ] **Security Testing**
  - [ ] Verify signed update packages
  - [ ] Test unsigned package rejection
  - [ ] Check ADU partition permissions
  - [ ] Validate TLS certificate validation

### Production Readiness

- [ ] **Documentation**
  - [ ] Create deployment guide
  - [ ] Document rollback procedures
  - [ ] Write troubleshooting guide
  - [ ] Provide partition layout diagram

- [ ] **Monitoring**
  - [ ] Enable ADU agent logging
  - [ ] Configure health check logging
  - [ ] Set up IoT Hub monitoring
  - [ ] Create alert rules for failures

- [ ] **Recovery**
  - [ ] Test factory reset procedure
  - [ ] Document emergency recovery steps
  - [ ] Prepare rescue SD card / USB image
  - [ ] Validate bootloader recovery

---

## Security Considerations

### Update Package Signing

**Why Sign Updates?**
- Prevent malicious updates
- Ensure authenticity from trusted source
- Detect corruption or tampering

**Implementation**:

1. **Generate RSA Key Pair** (on secure build server):
   ```bash
   # Private key (keep secret!)
   openssl genrsa -aes256 -out private.pem -passout file:pass.txt 2048
   
   # Public key (bake into device image)
   openssl rsa -in private.pem -passin file:pass.txt -out public.pem -outform PEM -pubout
   ```

2. **Sign Update Package** (build time):
   ```bash
   # Create signature
   openssl dgst -sha256 -sign private.pem -passin file:pass.txt \
       -out update.swu.sig update.swu
   ```

3. **Verify on Device** (SWUpdate automatic):
   - Public key installed: `/etc/swupdate/public.pem`
   - SWUpdate verifies signature before installation
   - Rejects updates with invalid signatures

### ADU Partition Access Control

**ACL Configuration**:
```bash
# ADU partition must be protected from unauthorized access
chown root:adu /adu
chmod 770 /adu

# Only adu user/group can read/write
setfacl -m u:adu:rwx /adu
setfacl -m g:adu:rwx /adu
setfacl -m other:--- /adu

# Health directory readable by adu group for diagnostics
chmod 750 /adu/health
```

**Why Restrict Access?**
- Prevent malicious users from:
  - Tampering with downloaded updates
  - Deleting update packages
  - Filling storage with junk
  - Reading sensitive logs

### Secure Boot Integration

**Not covered in this guide**, but recommended for production:

- U-Boot Verified Boot (FIT images with signatures)
- Chain of Trust from ROM bootloader → U-Boot → Kernel
- Encrypted root filesystems
- TPM/TEE integration for key storage

---

## Troubleshooting Patterns

### Boot Loop After Update

**Symptoms**: Device reboots 3 times, then reverts to old partition

**Causes**:
1. Boot health check failing
2. Critical service not starting
3. Filesystem corruption
4. Network configuration issue

**Debug Steps**:

```bash
# 1. Check bootloader environment
fw_printenv boot_partition
fw_printenv boot_attempts
fw_printenv boot_success

# 2. Check boot validation logs
tail -50 /adu/health/boot-validation.log
journalctl -u adu-boot-validation.service -b -1  # Previous boot

# 3. Check failed services
systemctl --failed
journalctl -xe

# 4. Manual validation check
/usr/lib/adu/adu-boot-validation.sh
```

**Solutions**:
- Fix failing service
- Adjust health check criteria (if too strict)
- Verify network configuration
- Check filesystem integrity: `fsck /dev/mmcblk0p3`

### Update Package Won't Install

**Symptoms**: Download succeeds, but installation fails

**Causes**:
1. Signature verification failure
2. Hardware compatibility mismatch
3. Insufficient storage on target partition
4. SWUpdate configuration error

**Debug Steps**:

```bash
# 1. Check SWUpdate logs
journalctl -u swupdate -n 100

# 2. Verify signature
swupdate -i update.swu -k /etc/swupdate/public.pem

# 3. Check hardware compatibility
cat /etc/adu-swupdate-hw-compat
# Compare with sw-description in update package

# 4. Check target partition space
df -h /dev/mmcblk0p3
```

**Solutions**:
- Verify signing key matches
- Update hardware compatibility file
- Increase target partition size
- Fix SWUpdate configuration

### Delta Reconstruction Failure

**Symptoms**: Delta download succeeds, reconstruction fails with OOM or error

**Causes**:
1. Insufficient RAM/swap
2. Corrupted delta file
3. Source extraction failure
4. Wrong source version

**Debug Steps**:

```bash
# 1. Check memory
free -h
swapon --show

# 2. Verify delta file
sha256sum /adu/downloads/delta.diff
# Compare with manifest hash

# 3. Check staging space
df -h /adu
du -sh /adu/staging/*

# 4. Manual reconstruction test
bspatch /adu/staging/source.ext4 /adu/staging/target.ext4 /adu/downloads/delta.diff
```

**Solutions**:
- Increase swap size to 2-4GB
- Re-download delta (may be corrupted)
- Verify source version matches expected
- Free up staging space (delete old files)

### Storage Exhausted

**Symptoms**: Update fails with "No space left on device"

**Causes**:
1. ADU partition too small
2. Logs filling space
3. Stale download files
4. Multiple updates downloaded

**Debug Steps**:

```bash
# 1. Check space on all partitions
df -h

# 2. Find large files
du -sh /adu/* | sort -h
find /adu -type f -size +100M

# 3. Check download cache
ls -lh /adu/downloads/
```

**Solutions**:
```bash
# Clean old downloads
rm -f /adu/downloads/*.swu.old

# Clean staging area
rm -rf /adu/staging/*

# Rotate logs
logrotate -f /etc/logrotate.d/adu-health

# Increase ADU partition size (requires repartitioning)
```

---

## Reference Implementation

This guide is based on the **meta-raspberrypi-adu** layer, which provides a complete working implementation of A/B updates with delta support for Raspberry Pi 4.

**Repository**: https://github.com/Azure/iot-hub-device-update-yocto

**Reference Files**:
- U-Boot boot script: `meta-raspberrypi-adu/recipes-bsp/rpi-u-boot-scr/files/boot.cmd.in`
- Boot validation service: `meta-raspberrypi-adu/recipes-support/adu-boot-validation/`
- Partition layout: `meta-raspberrypi-adu/wic/adu-raspberrypi.wks`
- SWUpdate configuration: `meta-raspberrypi-adu/recipes-support/swupdate/`

**Related Documentation**:
- [meta-raspberrypi-adu README](../README.md) - Raspberry Pi implementation
- [Porting Guide](porting.md) - Bring Your Own Board guide
- [meta-azure-device-update-samples](../../meta-azure-device-update-samples/README.md) - Delta generation examples

---

## Conclusion

Implementing A/B rootfs updates with Azure Device Update requires:

✅ **Hardware**: Sufficient storage (4-5× rootfs), bootloader with persistent environment  
✅ **Software**: U-Boot/GRUB with boot logic, SWUpdate, ADU agent, systemd  
✅ **Configuration**: Dual rootfs partitions, boot health service, rollback logic  
✅ **Optional**: Delta support requires staging space, swap, and bsdiff tools  

**Benefits**:
- Atomic updates with automatic rollback
- Minimal downtime (single reboot)
- Bandwidth-efficient delta updates (optional)
- Production-ready reliability

**Next Steps**:
1. Review your hardware capabilities
2. Design partition layout
3. Configure bootloader
4. Implement boot health verification
5. Test thoroughly (success and failure paths)
6. Deploy to production

For platform-specific implementation details, refer to the RPi reference implementation in **meta-raspberrypi-adu**.

---

**Document Version**: 1.0  
**Last Updated**: January 12, 2026  
**Maintained By**: Azure IoT Device Update Team
