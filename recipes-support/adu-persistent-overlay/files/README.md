# ADU Persistent Overlay System

## Overview

The ADU Persistent Overlay system provides a hybrid approach to persist data across A/B rootfs updates:

- **OverlayFS**: Applied to directories like `/etc` and `/var/log` for automatic persistence of all changes
- **Bind Mounts**: Used for critical files like `/etc/passwd`, `/etc/shadow` for explicit control and easy inspection

## Architecture

```
┌─────────────────────────────────────────┐
│  User View (merged filesystem)          │
├─────────────────────────────────────────┤
│  Critical Files (bind mounts)           │
│  /etc/passwd → /adu/system/passwd       │
│  /etc/shadow → /adu/system/shadow       │
├─────────────────────────────────────────┤
│  Overlay Layer (/etc overlay)           │
│  Upper: /adu/overlay/etc                │
│  Lower: /etc (rootfs - read-only)       │
└─────────────────────────────────────────┘
```

## Storage Layout

```
/adu/
├── overlay/           # Upper layers for overlayfs
│   ├── var-log/      # Changes to /var/log
│   ├── var-lib-connman/   # WiFi/network configs
│   ├── var-lib-bluetooth/ # Bluetooth pairings
│   ├── var-lib-apt/       # APT package lists & state
│   └── var-cache-apt/     # Downloaded .deb packages
├── work/             # Overlayfs work directories
│   ├── var-log/
│   ├── var-lib-connman/
│   ├── var-lib-bluetooth/
│   ├── var-lib-apt/
│   └── var-cache-apt/
├── system/           # Critical files (bind mounted)
│   ├── passwd
│   ├── shadow
│   ├── group
│   ├── gshadow
│   ├── hostname
│   ├── timezone
│   ├── machine-id
│   ├── du-config.json
│   ├── ssh/          # SSH host keys directory
│   │   ├── ssh_host_rsa_key
│   │   ├── ssh_host_ed25519_key
│   │   └── ...
│   ├── apt-sources.list.d/     # APT repositories
│   ├── apt-trusted.gpg.d/      # APT signing keys
│   └── apt-preferences.d/      # Package pinning
└── .backups/         # Automatic backups
    ├── original-*    # Original rootfs files
    └── migration-*   # Migration snapshots
```

## Usage

### Verify Active Mounts

```bash
sudo /usr/lib/adu/verify-overlays.sh
```

### Add New User (Persists Automatically)

```bash
sudo useradd -m newuser
sudo passwd newuser

# Verify persistence
cat /adu/system/passwd | grep newuser
cat /adu/overlay/etc/home/newuser  # home dir in overlay
```

### Modify Configuration Files

```bash
# Edit any file in /etc
sudo nano /etc/hostname

# Changes automatically saved to /adu/overlay/etc/
ls -la /adu/overlay/etc/ | grep hostname
```

### Factory Reset

```bash
sudo /usr/lib/adu/factory-reset.sh
# Removes all persistent changes, reverts to pristine rootfs
```

### Manual Migration (Existing Devices)

```bash
sudo /usr/lib/adu/migrate-to-overlay.sh
```

## Configuration

Edit `/etc/adu/overlay.conf` to customize:

```bash
# Add more overlay directories
OVERLAY_DIRS=(
    "/var/log"
    "/var/cache"      # Add cache directory persistence
    "/home"           # Add home directory persistence
)

# Add more bind-mounted files
BIND_MOUNTS=(
    "passwd:/etc/passwd"
    "shadow:/etc/shadow"
    "custom.conf:/etc/myapp/custom.conf"  # Add custom config
)
```

After modifying configuration:
```bash
sudo systemctl restart adu-persistent-overlay
```

## Benefits

✅ **Automatic Persistence**: 
- WiFi/Bluetooth connections persist automatically via overlayfs
- Network configurations survive A/B updates
- SSH host keys remain constant (no "host key changed" warnings)
- APT repository configs and package cache persist across updates

✅ **Easy Inspection**: Critical files visible in `/adu/system/` directory  
✅ **Factory Reset**: Simple `rm -rf /adu/overlay/*` to revert  
✅ **A/B Update Safe**: Works across rootfs partition switches  
✅ **Rollback Compatible**: Changes persist even after update rollback  
✅ **Backup Friendly**: Easy to backup `/adu/` directory  

## Troubleshooting

### Check Mount Status
```bash
mount | grep overlay
mount | grep bind
```

### View Overlay Changes
```bash
# See what changed in /etc
find /adu/overlay/etc -type f
```

### Compare Persistent vs Original
```bash
diff /etc/passwd.rootfs-original /etc/passwd
```

### Remount After Changes
```bash
sudo systemctl restart adu-persistent-overlay
```

## Migration from Existing System

If upgrading from a system without overlays:

1. System automatically migrates on first boot
2. Original files backed up to `/adu/.backups/migration-*`
3. Check migration status: `cat /adu/.migration-complete`

## Technical Details

- **Systemd Service**: `adu-persistent-overlay.service`
- **Priority**: Runs early in boot (sysinit.target)
- **OverlayFS Module**: Automatically loaded when mounting
- **Execution Order**: Overlays mounted first, then bind mounts overlay

## Related Files

- Service: `/lib/systemd/system/adu-persistent-overlay.service`
- Scripts: `/usr/lib/adu/mount-overlays.sh`, `mount-critical-binds.sh`
- Config: `/etc/adu/overlay.conf`
- Docs: `/usr/share/doc/adu-persistent-overlay/README.md`
