# U-Boot Boot Script Files

## Active Files

### boot.cmd.in (PRODUCTION - ACTIVELY USED)
The production U-Boot boot script that implements ADU A/B partition management.

**Key Features:**
- Uses modern variable names aligned with DEVICE-BOOT-PROCESS.md design
- Variables: `boot_partition` (rootA/rootB), not legacy `rpipart` (2/3)
- Automatic rollback after 3 failed boot attempts
- Per-partition tracking: `boot_attempts_A/B`, `boot_result_A/B`, `boot_timestamp_A/B`
- Upgrade validation mode with `upgrade_available` flag
- Clean, production-ready code (no verbose debug output)

**Workflow:**
1. First boot: Initialize all U-Boot environment variables
2. Check `upgrade_available` flag - if set, enter validation mode
3. If `boot_attempts >= 3` and upgrade pending, trigger automatic rollback
4. Set root partition based on `boot_partition` variable
5. Increment boot attempt counters
6. Save environment and boot kernel

**Used By:**
- Built by `rpi-u-boot-scr.bb` recipe
- Deployed as `/boot/boot.scr` on device
- Executed by U-Boot on every boot

## Reference Files (Not Built)

### boot.cmd.in.debug.verbose-reference
Legacy debug version with extensive logging - kept as reference only.

**Status:** NOT BUILT OR DEPLOYED (renamed from `boot.cmd.in.debug`)

**Why Kept:**
- Historical reference for verbose U-Boot debugging techniques
- Shows echo statements for troubleshooting boot issues
- Documents legacy ADU error reporting approach
- Useful if verbose boot script needed in future

**Problems with this version:**
- Still uses old legacy variables (`rpipart`, `have_updated`)
- Mixed old and new design approaches
- Too verbose for production (slows boot)
- Doesn't align with current DEVICE-BOOT-PROCESS.md design

**If you need verbose boot debugging:**
1. Copy concepts from `boot.cmd.in.debug.verbose-reference`
2. Add echo statements to production `boot.cmd.in`
3. Rebuild and test
4. Remember: Verbose output slows boot significantly

## Variable Migration

### Old Design (Legacy - DEPRECATED)
```
rpipart         → 2 or 3 (partition numbers)
have_updated    → 0 or 1 (update applied flag)
boot_attempts   → Counter (0-3)
```

### New Design (Current - PRODUCTION)
```
boot_partition     → rootA or rootB (semantic names)
upgrade_available  → 0 or 1 (clearer intent)
boot_attempts      → Global counter (0-3)
boot_attempts_A    → rootA counter
boot_attempts_B    → rootB counter
boot_result        → success/failed/unknown
boot_result_A      → Per-partition result
boot_result_B      → Per-partition result
boot_timestamp_A   → Unix epoch timestamp
boot_timestamp_B   → Unix epoch timestamp
```

## Testing Boot Script Changes

After modifying `boot.cmd.in`:

```bash
# Rebuild U-Boot script
cd ~/adu_yocto/iot-hub-device-update-yocto
./scripts/build.sh -o ~/adu_yocto/out/build --rebuild "rpi-u-boot-scr"

# Find generated boot.scr
ls ~/adu_yocto/out/build/build/tmp/deploy/images/raspberrypi4-64/boot.scr*

# Flash to SD card or manually copy
sudo cp boot.scr /mnt/boot/

# On device, inspect U-Boot environment
fw_printenv boot_partition boot_attempts boot_result
```

## Related Documentation

- **DEVICE-BOOT-PROCESS.md** - Complete boot flow design and variable reference
- **ADU-ERROR-REPORTING.md** - Error reporting from U-Boot to ADU agent
- **check-uboot-rollback.sh** - Helper script to check for rollback events

## Maintenance Notes

**When changing partition layout:**
1. Update partition numbers in `boot.cmd.in` (rootA=p2, rootB=p3)
2. Update `adu-raspberrypi.wks` partition definitions
3. Update `/etc/fstab` in base-files
4. Update systemd mount units (adu.mount)
5. Rebuild and test thoroughly

**When adding new U-Boot variables:**
1. Document in DEVICE-BOOT-PROCESS.md first
2. Initialize in first-boot section of boot.cmd.in
3. Update adu-boot-menu.sh to display new variables
4. Update adu-boot-validation.sh if variables need to be set from Linux
5. Update adu-decode-error if adding error codes

---

**Last Updated:** 2026-01-02  
**Maintainer:** ADU Yocto Team
