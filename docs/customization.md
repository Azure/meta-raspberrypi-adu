# meta-raspberrypi-adu Customization Guide

**A/B Rootfs Update Customizations for Raspberry Pi**

> This guide documents all customizations made in `meta-raspberrypi-adu` over the standard `meta-raspberrypi` layer to enable A/B rootfs updates with Azure Device Update (ADU).

---

## Table of Contents

1. [Overview](#overview)
2. [ADU Agent & Handler Dependencies](#adu-agent--handler-dependencies)
3. [Customization Summary](#customization-summary)
4. [Disk Partitioning](#disk-partitioning)
5. [Bootloader (U-Boot) Customization](#bootloader-u-boot-customization)
6. [Boot Health & Retry Logic](#boot-health--retry-logic)
7. [Post-Boot Validation](#post-boot-validation)
8. [SWUpdate Integration](#swupdate-integration)
9. [Configuration Files](#configuration-files)
10. [Quick Reference](#quick-reference)

---

## Overview

### Why These Customizations?

The standard `meta-raspberrypi` layer provides a basic Raspberry Pi BSP. To enable **resilient A/B over-the-air (OTA) updates** with automatic rollback, we need:

| Requirement | Standard meta-raspberrypi | meta-raspberrypi-adu |
|-------------|---------------------------|----------------------|
| Dual rootfs partitions | ❌ Single rootfs | ✅ rootA + rootB |
| Bootloader partition selection | ❌ Fixed boot | ✅ U-Boot A/B logic |
| Boot retry counter | ❌ None | ✅ 5 attempts max |
| Automatic rollback | ❌ None | ✅ On boot failure |
| Post-boot validation | ❌ None | ✅ Health checks |
| Delta update staging | ❌ None | ✅ 8GB ADU partition |

---

## ADU Agent & Handler Dependencies

> ⚠️ **Important**: This implementation is designed to work with the **Azure Device Update Agent** and **SWUpdate Handler V2**. If you implement a custom update handler, you must adapt the boot management logic to match your update strategy.

### Reference Architecture

This layer implements the following update flow, which is tightly coupled to ADU Agent behavior:

```
┌─────────────────────────────────────────────────────────────────────┐
│                  ADU Agent + SWUpdate Handler V2 Flow               │
└─────────────────────────────────────────────────────────────────────┘

1. ADU Agent receives deployment from Azure IoT Hub
        │
2. ADU Agent invokes SWUpdate Handler V2
        │
        ├─► Handler downloads update (.swu file)
        ├─► Handler calls SWUpdate to write to inactive partition
        ├─► Handler sets U-Boot variables:
        │       fw_setenv boot_partition rootB    # Target partition
        │       fw_setenv upgrade_available 1     # Enable validation mode
        │       fw_setenv boot_attempts 0         # Reset counter
        └─► Handler triggers reboot
                │
3. U-Boot boot script (this layer)
        │
        ├─► Reads upgrade_available, boot_partition, boot_attempts
        ├─► Increments boot_attempts
        ├─► If boot_attempts > max: ROLLBACK to last_known_good_partition
        └─► Boots selected partition
                │
4. Boot validation service (this layer)
        │
        ├─► Runs health checks
        ├─► If PASS: Sets upgrade_available=0, boot_attempts=0
        │            Updates last_known_good_partition
        └─► If FAIL: Exits non-zero → systemd reboots → retry
                │
5. ADU Agent reports result to Azure IoT Hub
```

### What the Handler Controls vs. What This Layer Controls

| Responsibility | Controlled By | U-Boot Variables Set |
|----------------|---------------|----------------------|
| Download update | ADU Agent / Handler | — |
| Write to inactive partition | SWUpdate (via Handler) | — |
| Set target partition | **Handler** | `boot_partition` |
| Enable validation mode | **Handler** | `upgrade_available=1` |
| Reset boot counter | **Handler** | `boot_attempts=0` |
| Trigger reboot | **Handler** | — |
| A/B partition selection | **This Layer** (U-Boot) | — |
| Boot retry counting | **This Layer** (U-Boot) | `boot_attempts++` |
| Automatic rollback | **This Layer** (U-Boot) | `boot_partition`, `upgrade_available=0` |
| Health validation | **This Layer** (service) | `boot_attempts=0`, `boot_result` |
| Update LKG partition | **This Layer** (service) | `last_known_good_partition` |

### If You Roll Your Own Handler

If you implement a **custom update handler** instead of using SWUpdate Handler V2, you **MUST** ensure your handler:

1. **Sets `boot_partition`** to the target partition (`rootA` or `rootB`) before reboot
2. **Sets `upgrade_available=1`** to enable validation mode
3. **Sets `boot_attempts=0`** to reset the retry counter
4. **Triggers reboot** after setting variables

**Example (custom handler pseudo-code):**
```bash
# After writing update to inactive partition
fw_setenv boot_partition rootB
fw_setenv upgrade_available 1
fw_setenv boot_attempts 0
reboot
```

If your handler does NOT set these variables correctly:
- `upgrade_available=0`: Boot validation won't run, `last_known_good_partition` won't update
- `boot_partition` not set: Device boots same partition (update not activated)
- `boot_attempts` not reset: May trigger premature rollback

### Alternative Update Strategies

If you use a different update strategy, you may need to modify:

| If You Use... | Modify These Components |
|---------------|------------------------|
| **RAUC instead of SWUpdate** | `boot.cmd.in` (variable names may differ), fstab, handler integration |
| **Mender** | Mender has its own bootloader integration; this layer not needed |
| **Custom bootloader (not U-Boot)** | `boot.cmd.in` → your bootloader's equivalent |
| **Single rootfs (no A/B)** | Not applicable; use standard meta-raspberrypi |
| **OSTree** | OSTree manages boot differently; this layer not compatible |

### Contract Between Handler and Boot Script

The U-Boot boot script expects these variables to be set by the update handler:

```
┌────────────────────────────────────────────────────────────────────┐
│  Variable Contract: Handler ←→ U-Boot Script                      │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  BEFORE REBOOT (Handler sets):                                     │
│    boot_partition = "rootA" | "rootB"   # Target partition         │
│    upgrade_available = 1                # Enable validation        │
│    boot_attempts = 0                    # Reset counter            │
│                                                                    │
│  AFTER SUCCESSFUL BOOT (Validation service sets):                  │
│    upgrade_available = 0                # Exit validation mode     │
│    boot_attempts = 0                    # Confirm success          │
│    boot_result = "success"              # Record outcome           │
│    last_known_good_partition = "rootX"  # Update LKG               │
│                                                                    │
│  AFTER ROLLBACK (U-Boot script sets):                              │
│    boot_partition = ${last_known_good_partition}                   │
│    upgrade_available = 0                # Exit validation mode     │
│    boot_attempts = 0                    # Reset for LKG            │
│    boot_result = "failed"               # Record outcome           │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

---

### Layer Structure

```
meta-raspberrypi-adu/
├── wic/                          # Partition layout
│   └── adu-raspberrypi.wks       # A/B partition scheme
├── recipes-bsp/                  # Bootloader customizations
│   ├── rpi-u-boot-scr/           # A/B boot script
│   ├── bootfiles/                # config.txt modifications
│   └── u-boot/                   # U-Boot config
├── recipes-support/              # Boot validation & support
│   ├── adu-boot-validation/      # Post-boot health checks
│   ├── adu-swap/                 # Swap for delta updates
│   └── swupdate/                 # SWUpdate integration
├── recipes-core/                 # System configuration
│   └── base-files/               # fstab for A/B mounts
└── conf/                         # Layer configuration
```

---

## Customization Summary

### Key Files Modified/Added

| Component | File | Purpose |
|-----------|------|---------|
| **Partition Layout** | `wic/adu-raspberrypi.wks` | 4-partition A/B scheme |
| **Boot Script** | `recipes-bsp/rpi-u-boot-scr/files/boot.cmd.in` | A/B selection, rollback logic |
| **U-Boot Config** | `recipes-bsp/u-boot/u-boot_%.bbappend` | Enable env tools |
| **Boot Validation** | `recipes-support/adu-boot-validation/` | Post-boot health checks |
| **Filesystem Table** | `recipes-core/base-files/base-files/raspberrypi4-64/fstab` | /boot, /adu mounts |
| **HW Compatibility** | `recipes-support/adu-swupdate-hw-compat/` | SWUpdate hw matching |

---

## Disk Partitioning

### Partition Layout (adu-raspberrypi.wks)

**Location**: `wic/adu-raspberrypi.wks`

```
┌──────────────────────────────────────────────────────────────────┐
│                    SD Card Layout (16GB+)                        │
├──────────────────────────────────────────────────────────────────┤
│ P1: /boot (FAT32, 2GB)                                          │
│     - U-Boot, kernel, DTBs, config.txt                          │
│     - uboot.env (persistent boot state)                         │
│     - boot.scr (A/B boot script)                                │
├──────────────────────────────────────────────────────────────────┤
│ P2: rootA (ext4, ~2.5GB)                                        │
│     - Primary root filesystem                                    │
│     - Default boot partition                                     │
├──────────────────────────────────────────────────────────────────┤
│ P3: rootB (ext4, ~2.5GB)                                        │
│     - Secondary root filesystem                                  │
│     - Update target partition                                    │
│     - NOT mounted during normal operation                        │
├──────────────────────────────────────────────────────────────────┤
│ P4: /adu (ext4, 8GB)                                            │
│     - ADU agent working directory                                │
│     - Delta update staging (~2GB)                                │
│     - Swap file (2GB) for delta reconstruction                   │
│     - Logs and configuration                                     │
│     - Persists across A/B updates                                │
└──────────────────────────────────────────────────────────────────┘
```

### WKS File Configuration

```wks
# Boot partition (MUST be first)
part /boot --source bootimg-partition --ondisk mmcblk0 --fstype=vfat \
    --label boot --active --align 4096 --size 2048 --fsoptions "defaults,sync"

# Primary rootfs - rootA (MUST be partition 2)
part / --source rootfs --ondisk mmcblk0 --fstype=ext4 \
    --label rootA --align 4096 --extra-space 512

# Secondary rootfs - rootB (MUST be partition 3)  
part --source rootfs --ondisk mmcblk0 --fstype=ext4 \
    --label rootB --align 4096 --extra-space 512

# ADU working partition (MUST be partition 4)
part /adu --ondisk mmcblk0 --fstype=ext4 \
    --label adu --align 4096 --size 8192
```

### ⚠️ Critical: Partition Number Dependencies

**DO NOT change partition numbers!** Multiple components hardcode these:

| Partition | Number | Hardcoded In |
|-----------|--------|--------------|
| /boot | p1 | U-Boot, fstab, config.txt |
| rootA | p2 | boot.cmd.in (`root=/dev/mmcblk0p2`) |
| rootB | p3 | boot.cmd.in (`root=/dev/mmcblk0p3`) |
| /adu | p4 | fstab |

If you need to add partitions, add them AFTER p4 and switch to GPT.

### Corresponding fstab Entry

**Location**: `recipes-core/base-files/base-files/raspberrypi4-64/fstab`

```fstab
# Static file system entries (root handled by kernel cmdline)
/dev/mmcblk0p1  /boot   vfat    defaults,sync   0   2
/dev/mmcblk0p4  /adu    ext4    defaults        0   2
```

Note: Root partition (`/`) is set via kernel cmdline by U-Boot, not fstab.

---

## Bootloader (U-Boot) Customization

### Boot Flow

```
┌───────────────────────────────────────────────────────────────────┐
│                    A/B Boot Flow                                  │
└───────────────────────────────────────────────────────────────────┘

1. RPi Firmware → Loads U-Boot from /boot
                      │
2. U-Boot          ← Reads uboot.env
   │                  - boot_partition (rootA/rootB)
   │                  - boot_attempts (0-5)
   │                  - upgrade_available (0/1)
   │
   ├─► upgrade_available=0 AND boot_attempts > 5?
   │   └─► YES: CATASTROPHIC FAILURE → Drop to U-Boot console
   │
   ├─► upgrade_available=1 AND boot_attempts > 5?
   │   └─► YES: ROLLBACK → Switch to last_known_good_partition
   │
   └─► INCREMENT boot_attempts
       Set root=/dev/mmcblk0p{2|3} based on boot_partition
       Boot Linux kernel
                      │
3. Linux Kernel    ← Mounts selected rootfs
                      │
4. systemd         ← Runs adu-boot-validation.service
   │                  - Validates system health
   │                  - If PASS: boot_attempts=0, upgrade_available=0
   │                  - If FAIL: exit 1 (will reboot, retry up to 5x)
   │
   └─► Normal operation or reboot for retry/rollback
```

### U-Boot Environment Variables

**Storage**: `/boot/uboot.env` (FAT32 file)

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `boot_partition` | string | `rootA` | Which partition to boot: `rootA` (p2) or `rootB` (p3) |
| `boot_attempts` | int | `0` | Boot attempt counter (0-5) |
| `upgrade_available` | bool | `0` | Set to `1` when update is pending validation |
| `last_known_good_partition` | string | `rootA` | Last successfully validated partition |
| `max_boot_attempts` | int | `5` | Maximum attempts before rollback |
| `boot_result` | string | `unknown` | `success`, `failed`, or `unknown` |

### Boot Script Implementation

**Location**: `recipes-bsp/rpi-u-boot-scr/files/boot.cmd.in`

**Key Logic Sections**:

#### 1. First Boot Initialization
```u-boot
if test ! -e mmc 0:1 uboot.env; then 
    # Create default environment
    setenv boot_partition rootA
    setenv boot_attempts 0
    setenv upgrade_available 0
    setenv last_known_good_partition rootA
    setenv max_boot_attempts 5
    saveenv
fi
```

#### 2. Catastrophic Failure Detection (LKG Failing)
```u-boot
# If not in upgrade mode but boot keeps failing, something is fundamentally broken
if test "${upgrade_available}" != "1"; then
    if test "${boot_attempts}" -gt "${max_boot_attempts}"; then
        echo "CATASTROPHIC FAILURE: LKG partition failed"
        setenv boot_attempts 0
        saveenv
        exit  # Drop to U-Boot console
    fi
fi
```

#### 3. Rollback Logic (During Upgrade Validation)
```u-boot
if test "${upgrade_available}" = "1"; then
    if test "${boot_attempts}" -gt "${max_boot_attempts}"; then
        # Rollback triggered
        setenv boot_partition ${last_known_good_partition}
        setenv boot_attempts 0
        setenv upgrade_available 0
        setenv boot_result failed
        saveenv
    fi
fi
```

#### 4. Partition Selection
```u-boot
if test "${boot_partition}" = "rootA"; then
    setenv bootargs "${bootargs} root=/dev/mmcblk0p2"
else
    setenv bootargs "${bootargs} root=/dev/mmcblk0p3"
fi

# Increment attempt counter
setexpr boot_attempts ${boot_attempts} + 1
saveenv
booti ${kernel_addr_r} - ${fdt_addr}
```

### Manual U-Boot Operations

```bash
# View all boot variables
fw_printenv | grep -E "boot_partition|boot_attempts|upgrade_available|last_known_good"

# Force boot to specific partition
fw_setenv boot_partition rootB
fw_setenv boot_attempts 0
reboot

# Reset to known good state
fw_setenv boot_partition rootA
fw_setenv upgrade_available 0
fw_setenv boot_attempts 0
fw_setenv boot_result unknown
reboot
```

---

## Boot Health & Retry Logic

### Retry Mechanism

The A/B update system uses a boot attempt counter with exponential backoff:

```
Boot Attempt Timeline (upgrade_available=1):
─────────────────────────────────────────────

Attempt 1 ─► Boot ─► Health Check FAIL ─► Reboot
Attempt 2 ─► Boot ─► Health Check FAIL ─► Reboot
Attempt 3 ─► Boot ─► Health Check FAIL ─► Reboot
Attempt 4 ─► Boot ─► Health Check FAIL ─► Reboot
Attempt 5 ─► Boot ─► Health Check FAIL ─► Reboot
Attempt 6 ─► U-Boot detects attempts > max ─► ROLLBACK to LKG partition
```

### Why 5 Attempts?

- Allows for transient failures (network blip, slow service startup)
- Not so many that bad updates cause extended downtime
- Configurable via `max_boot_attempts` U-Boot variable

### Rollback Behavior

| Scenario | Action | Result |
|----------|--------|--------|
| `upgrade_available=1`, attempts > max | Switch to `last_known_good_partition` | Rolls back to previous working rootfs |
| `upgrade_available=0`, attempts > max | Drop to U-Boot console | Manual recovery required |
| Health check passes | Set `boot_attempts=0`, `upgrade_available=0` | Normal operation |

---

## Post-Boot Validation

### adu-boot-validation Service

**Location**: `recipes-support/adu-boot-validation/`

This service runs at boot **before the ADU Agent starts** to validate system health and handle rollback detection. It uses a two-phase approach:

### Two-Phase Validation Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│              adu-boot-validation.service (Before=deviceupdate-agent)│
└─────────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┴─────────────────────┐
        ▼                                           ▼
┌───────────────────┐                    ┌───────────────────────────┐
│     PHASE 1       │                    │         PHASE 2           │
│ Rollback Detection│                    │      Health Checks        │
├───────────────────┤                    ├───────────────────────────┤
│ • Detect rollback │                    │ • SystemdServices check   │
│ • Check flapping  │                    │ • FilesystemWritable test │
│ • Blacklist failed│                    │ • NetworkConnectivity     │
│   workflows       │                    │ • DiskSpace validation    │
│ • Log results     │                    │ • Custom plugin checks    │
└───────────────────┘                    └───────────────────────────┘
                              │
                              ▼
                   ADU Agent starts safely
```

**Why Phase 1 runs before ADU Agent?** The rollback detection and workflow blacklisting must complete before the ADU Agent starts to prevent it from re-trying failed update workflows that caused the rollback.

### Validation Flow

```
systemd boot
      │
      ▼
adu-boot-validation.service (Before=deviceupdate-agent)
      │
      ├──────────── PHASE 1: ROLLBACK DETECTION ────────────┐
      │                                                      │
      ├─► Check upgrade_available                            │
      │   └─► If 0 AND boot_attempts=0: Skip to Phase 2      │
      │                                                      │
      ├─► Detect Rollback Condition:                         │
      │   └─► boot_result="failed" OR                        │
      │       boot_attempts > 0                              │
      │                                                      │
      ├─► Check Flapping Protection:                         │
      │   └─► If rollback count > threshold in window:       │
      │       Stay on LKG, blacklist all pending workflows   │
      │                                                      │
      ├─► Blacklist Failed Workflow:                         │
      │   └─► Write to /adu/state/blacklisted-workflows.json │
      │       (prevents ADU agent from retrying)             │
      │                                                      │
      └─► Log results to /adu/health/rollback.log            │
      │
      ├──────────── PHASE 2: HEALTH CHECKS ─────────────────┐
      │                                                      │
      ├─► Run Built-in Checks:                               │
      │   ├─ SystemdServices (journald, dbus, etc.)          │
      │   ├─ FilesystemWritable (/tmp test write)            │
      │   ├─ NetworkConnectivity (ping/DNS)                  │
      │   └─ DiskSpace (> 10% free)                          │
      │                                                      │
      ├─► Run Custom Checks:                                 │
      │   └─ Scripts in /usr/lib/adu/validation-checks.d/    │
      │                                                      │
      └─► Result:                                            │
          ├─ PASS: fw_setenv boot_attempts 0                 │
          │        fw_setenv upgrade_available 0             │
          │        fw_setenv boot_result success             │
          │        fw_setenv last_known_good_partition X     │
          │                                                  │
          └─ FAIL: exit 1 (systemd reboots, retry)           │
      │
      ▼
ADU Agent starts (deviceupdate-agent.service)
```

### Configuration

**Location**: `/usr/lib/adu/boot-validation.conf`

```ini
[General]
# Timeout for all validation checks (seconds)
ValidationTimeout = 300

# Allow manual override via adu-confirm-boot command
AllowManualOverride = true

# Auto-confirm if validation times out (dangerous!)
AutoConfirmOnTimeout = false

[Checks]
# Directory for custom check scripts
CustomChecksDir = /usr/lib/adu/validation-checks.d

# Built-in check severity: critical, warning, disabled
CheckSystemdServices = critical
CheckFilesystemWritable = critical
CheckNetworkConnectivity = warning
CheckDiskSpace = warning

[SystemdServices]
# Comma-separated list of required services
Services = systemd-journald,dbus,deviceupdate-agent
```

### Custom Validation Checks

Add custom checks by placing executable scripts in `/usr/lib/adu/validation-checks.d/`:

```bash
#!/bin/bash
# /usr/lib/adu/validation-checks.d/check-my-app.sh

# Check if custom application is running
if systemctl is-active --quiet my-application; then
    echo "PASS: my-application is running"
    exit 0
else
    echo "FAIL: my-application is not running"
    exit 1  # Returning non-zero marks check as failed
fi
```

Make executable: `chmod +x /usr/lib/adu/validation-checks.d/check-my-app.sh`

### Manual Boot Confirmation

For debugging or special cases, manually confirm a boot:

```bash
# Create override flag (skips validation)
sudo touch /var/run/adu-boot-confirmed

# Or use the helper tool
sudo adu-confirm-boot
```

---

## SWUpdate Integration

### Hardware Compatibility

**Location**: `recipes-support/adu-swupdate-hw-compat/`

SWUpdate validates that updates are compatible with the target hardware.

**Compatibility File**: `/etc/adu-swupdate-hw-compat`

```
raspberrypi4-64 1.0
```

This file is checked against `sw-description` in update packages.

### Update Flow

```
ADU Agent receives update
        │
        ▼
Download to /adu/downloads/
        │
        ▼
SWUpdate validates:
  ├─ sw-description signature
  ├─ Hardware compatibility
  └─ Version check
        │
        ▼
Write rootfs to inactive partition (p2 or p3)
        │
        ▼
Set U-Boot variables:
  fw_setenv boot_partition rootB  # (or rootA)
  fw_setenv upgrade_available 1
  fw_setenv boot_attempts 0
        │
        ▼
Reboot
        │
        ▼
[Boot validation flow starts]
```

---

## Configuration Files

### Key Configuration Locations

| File | Purpose | Persists Across Updates |
|------|---------|-------------------------|
| `/boot/uboot.env` | Boot state (partition, attempts) | Yes (shared boot) |
| `/etc/adu/du-config.json` | ADU agent config | No (in rootfs) |
| `/adu/` | ADU working data, logs | Yes (separate partition) |
| `/usr/lib/adu/boot-validation.conf` | Validation settings | No (in rootfs) |

### Developer Configuration

For build-time customization, use `/conf/developer.conf`:

```bitbake
# Enable/disable features
WITH_FEATURE_DELTA_UPDATE = "1"
WITH_ADUC_TESTS = "0"

# Import manifest settings
ADU_IMPORTMANIFEST_PROVIDER = "contoso"
ADU_IMPORTMANIFEST_NAME = "rpi4-adu"
ADU_IMPORTMANIFEST_MANUFACTURER = "contoso"
ADU_IMPORTMANIFEST_MODEL = "rpi4-prod"
```

---

## Quick Reference

### U-Boot Commands

```bash
# View boot state
fw_printenv boot_partition boot_attempts upgrade_available

# Manual partition switch
fw_setenv boot_partition rootB && reboot

# Reset after failed update
fw_setenv upgrade_available 0
fw_setenv boot_attempts 0
fw_setenv boot_result unknown
reboot

# Force rollback
fw_setenv boot_partition rootA
fw_setenv upgrade_available 0
reboot
```

### Diagnostic Commands

```bash
# Check current partition
findmnt / | grep mmcblk0

# Check boot validation status
systemctl status adu-boot-validation

# View validation logs
journalctl -u adu-boot-validation -b

# Check ADU agent status  
systemctl status deviceupdate-agent

# View boot health log
cat /var/log/adu/boot-validation.log
```

### Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Boot loops indefinitely | Validation keeps failing | Check `/var/log/adu/boot-validation.log`, use `adu-confirm-boot` |
| Drops to U-Boot console | Both partitions failing | Manual recovery, re-flash SD card |
| Update stuck at "Applying" | Reboot not triggered | Check `fw_printenv upgrade_available` |
| Wrong partition booted | `boot_partition` incorrect | `fw_setenv boot_partition rootX` |

---

## Related Documentation

- [ADU A/B Update Architecture Guide](architecture.md) - Platform-agnostic design concepts
- [Porting Guide](porting.md) - Adapt to other hardware
- [U-Boot Boot Script](uboot.md) - Deep dive into U-Boot A/B partition logic
- [Troubleshooting](troubleshooting.md) - Build and runtime issues

---

## Appendix: Recipe Reference

### recipes-bsp/rpi-u-boot-scr/

| File | Purpose |
|------|---------|
| `rpi-u-boot-scr.bbappend` | Override default boot script |
| `files/boot.cmd.in` | A/B boot selection logic |

### recipes-support/adu-boot-validation/

| File | Purpose |
|------|---------|
| `adu-boot-validation.bb` | Recipe definition |
| `files/adu-boot-validation.sh` | Two-phase validation script (~780 lines) |
| `files/adu-boot-validation.service` | systemd unit (runs Before=deviceupdate-agent) |
| `files/boot-validation.conf` | Default configuration |
| `files/adu-confirm-boot` | Manual override tool |

> **Note**: The validation script includes two phases:
> - **Phase 1 (Rollback Detection)**: Detects rollback conditions, prevents boot flapping, blacklists failed workflows
> - **Phase 2 (Health Checks)**: Runs built-in and custom health checks to validate system state

### recipes-core/base-files/

| File | Purpose |
|------|---------|
| `base-files_%.bbappend` | fstab customization |
| `base-files/raspberrypi4-64/fstab` | Mount points for /boot, /adu |
