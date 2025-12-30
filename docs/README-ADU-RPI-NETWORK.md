# WiFi/Bluetooth Troubleshooting Guide for Raspberry Pi 4

This guide covers building, configuring, and troubleshooting WiFi/Bluetooth connectivity on Azure Device Update (ADU) images for Raspberry Pi 4.

---

## Table of Contents
1. [Building Image with WiFi/Bluetooth Support](#building-image-with-wifibluetooth-support)
2. [First-Time WiFi Configuration](#first-time-wifi-configuration)
3. [Troubleshooting Common Issues](#troubleshooting-common-issues)
4. [Diagnostic Tools](#diagnostic-tools)
5. [Auto-Enable WiFi at Boot](#auto-enable-wifi-at-boot)
6. [Advanced Topics](#advanced-topics)

---

## Building Image with WiFi/Bluetooth Support

### Yocto Build Configuration

WiFi/Bluetooth support is controlled by the `ENABLE_WIFI_BLUETOOTH` variable and the `adu-wifi-bluetooth.conf` distro configuration.

**Option 1: Environment variable (recommended for CI/automation)**
```bash
export ENABLE_WIFI_BLUETOOTH=1
export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS ENABLE_WIFI_BLUETOOTH"
bitbake adu-base-image
```

**Note**: `BB_ENV_PASSTHROUGH_ADDITIONS` tells BitBake to read the `ENABLE_WIFI_BLUETOOTH` environment variable. Without this, BitBake will not see the environment variable.

**Option 2: Add to local.conf**
Edit `build/conf/local.conf`:
```bash
# Enable WiFi/Bluetooth support
ENABLE_WIFI_BLUETOOTH = "1"
```

Then build:
```bash
bitbake adu-base-image
```

**Option 3: Include distro configuration**
The layer provides `conf/distro/adu-wifi-bluetooth.conf`. You can include it in your distro config:
```bash
require conf/distro/adu-wifi-bluetooth.conf
ENABLE_WIFI_BLUETOOTH = "1"
```

### What Gets Included

When WiFi/Bluetooth support is enabled:
- **Firmware**: BCM43455/43456 firmware from linux-firmware-rpidistro
- **License**: Accepts `synaptics-killswitch` proprietary license
- **Packages**: wpa-supplicant, iw, wireless-tools, connman, rfkill
- **Features**: MACHINE_FEATURES includes wifi and bluetooth
- **Image Size**: Adds ~50MB to base image

### Build Configuration Details

WiFi/Bluetooth support is controlled by the `ENABLE_WIFI_BLUETOOTH` variable in `conf/distro/adu-wifi-bluetooth.conf`:

```python
# Default: disabled (requires accepting proprietary license)
ENABLE_WIFI_BLUETOOTH ?= "0"

# When enabled (ENABLE_WIFI_BLUETOOTH = "1"):
# 1. Accepts BCM43455 firmware license (synaptics-killswitch)
LICENSE_FLAGS_ACCEPTED:append = "${@' synaptics-killswitch' if d.getVar('ENABLE_WIFI_BLUETOOTH') == '1' else ''}"

# 2. Keeps wifi/bluetooth in MACHINE_FEATURES (doesn't remove them)
MACHINE_FEATURES:remove = "${@'' if d.getVar('ENABLE_WIFI_BLUETOOTH') == '1' else 'wifi bluetooth'}"

# 3. Includes packagegroup-base-extended (wpa-supplicant, connman, wireless-tools, etc.)
IMAGE_INSTALL:remove = "${@'' if d.getVar('ENABLE_WIFI_BLUETOOTH') == '1' else 'packagegroup-base-extended'}"
```

**Important**: You must set `ENABLE_WIFI_BLUETOOTH = "1"` before the BitBake environment is initialized.

---

## First-Time WiFi Configuration

### Prerequisites
- RPi 4 with built image (WiFi/Bluetooth enabled)
- HDMI monitor + keyboard, or SSH over Ethernet
- WiFi network name (SSID) and password

### Step 1: Unblock WiFi (if soft blocked)

Check rfkill status:
```bash
rfkill list wifi
```

If output shows `Soft blocked: yes`:
```bash
rfkill unblock wifi
ip link set wlan0 up
```

### Step 2: Scan for Networks

```bash
iw dev wlan0 scan | grep SSID
```

Should display list of available WiFi networks.

### Step 3: Connect Using connman (Recommended)

Start connman interactive shell:
```bash
connmanctl
```

Inside connmanctl:
```
connmanctl> enable wifi
connmanctl> scan wifi
connmanctl> services
```

Look for your network (format: `wifi_<id>_<ssid>_managed_psk`), then:
```
connmanctl> agent on
connmanctl> connect wifi_abc123_YourSSID_managed_psk
```

Enter password when prompted. Exit connmanctl:
```
connmanctl> quit
```

### Step 4: Verify Connection

```bash
ip addr show wlan0        # Should show assigned IP
ping -c 4 8.8.8.8         # Test internet connectivity
connmanctl services       # Should show "R" (Ready) or "O" (Online)
```

### Alternative: Manual wpa_supplicant Configuration

Create configuration file:
```bash
wpa_passphrase "YOUR_SSID" "YOUR_PASSWORD" | sudo tee /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
```

Start wpa_supplicant in background:
```bash
sudo wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
```

Request IP address (connman usually handles this automatically):
```bash
# If connman is not managing wlan0:
sudo systemctl stop connman
sudo ip link set wlan0 up
# systemd-networkd should acquire DHCP
```

---

## Troubleshooting Common Issues

### Issue 1: WiFi Interface Not Found (`wlan0` missing)

**Symptoms:**
```bash
ip link show wlan0
# Error: Device "wlan0" does not exist
```

**Diagnosis:**
```bash
# Check if firmware loaded
dmesg | grep -i brcmfmac

# Check if driver module loaded
lsmod | grep brcmfmac

# Check for SDIO device
dmesg | grep mmc1:
```

**Solutions:**
1. **Firmware missing**: Rebuild image with `ENABLE_WIFI_BLUETOOTH = "1"` in local.conf
2. **Driver not loaded**: `sudo modprobe brcmfmac`
3. **Hardware issue**: Check `dmesg` for SDIO detection errors

### Issue 2: WiFi Soft Blocked (rfkill)

**Symptoms:**
```bash
rfkill list wifi
# Soft blocked: yes
```

**Diagnosis:**
```bash
# Check systemd-rfkill service
systemctl status systemd-rfkill

# Check for rfkill events
journalctl -u systemd-rfkill --since "1 hour ago"
```

**Solutions:**
1. **Temporary**: `rfkill unblock wifi`
2. **Permanent**: Create systemd service (see [Auto-Enable WiFi at Boot](#auto-enable-wifi-at-boot))

### Issue 3: Firmware Not Loading

**Symptoms:**
```bash
dmesg | grep -i firmware
# brcmfmac: Direct firmware load for brcm/brcmfmac43455-sdio.bin failed
```

**Diagnosis:**
```bash
# Check firmware files
ls -la /lib/firmware/brcm/brcmfmac43455-sdio.*

# Verify firmware symlinks
file /lib/firmware/brcm/brcmfmac43455-sdio.bin
```

**Solutions:**
1. **Missing files**: Rebuild with `ENABLE_WIFI_BLUETOOTH = "1"` in build/conf/local.conf
2. **Broken symlinks**: Check linux-firmware-rpidistro recipe installation
3. **Wrong chip**: Verify with `dmesg | grep BCM` (should show BCM43455/6)

### Issue 4: nl80211 Driver Errors

**Symptoms:**
```bash
wpa_supplicant -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
# nl80211: kernel reports: Registration to specific type not supported
```

**Diagnosis:**
This is a **non-fatal warning**. wpa_supplicant tries to register for management frames (monitor mode) but kernel denies. This does NOT prevent normal WiFi client operation.

**Solutions:**
- **No action needed**: WiFi client mode works despite this warning
- If using wpa_supplicant manually, add `-B` flag to run in background

### Issue 5: Connection Timeout or Authentication Failure

**Symptoms:**
```bash
connmanctl> connect wifi_abc123_MySSID_managed_psk
# Error: Operation timeout or Input/output error
```

**Diagnosis:**
```bash
# Check wpa_supplicant logs
journalctl -u wpa_supplicant@wlan0 --since "5 minutes ago"

# Check signal strength
iw dev wlan0 station dump

# Check authentication events
dmesg | grep -i "wlan0.*auth"
```

**Solutions:**
1. **Wrong password**: Re-enter password carefully (case-sensitive)
2. **Weak signal**: Move closer to access point
3. **Wrong security type**: Check if network uses WPA3 (try WPA2 network first)
4. **MAC filtering**: Add RPi MAC address to router whitelist

### Issue 6: DHCP Failure (No IP Address)

**Symptoms:**
```bash
ip addr show wlan0
# inet6 fe80::... (only IPv6 link-local, no IPv4)
```

**Diagnosis:**
```bash
# Check connman service status
systemctl status connman

# Check DHCP lease attempts
journalctl -u connman --since "10 minutes ago" | grep -i dhcp

# Force connman to reconnect (triggers new DHCP request)
connmanctl disconnect wifi_*
connmanctl connect wifi_<your_service_id>
```

**Solutions:**
1. **Restart connman**: `sudo systemctl restart connman` to retry DHCP
2. **DHCP server issue**: Check router DHCP pool not exhausted
3. **Static IP**: Configure static IP in connman if DHCP unavailable (see Advanced Topics)

---

## Diagnostic Tools

### Built-in Diagnostic Script

The image includes `/adu/tools/adu-wifi-diagnostics.sh` for automated diagnostics:

```bash
# Run full diagnostics (saves to /boot/adu-diags/)
sudo /adu/tools/adu-wifi-diagnostics.sh

# Output location
ls -lh /boot/adu-diags/
# wifi-diag-YYYYMMDD-HHMMSS.txt
```

**What it collects:**
- System info (hostname, uptime, kernel version)
- Network interfaces (ip link, ip addr)
- WiFi interface details (iw dev, iw list capabilities)
- rfkill status
- Firmware files and versions
- Loaded kernel modules (brcmfmac)
- dmesg logs (WiFi/Bluetooth related)
- wpa_supplicant status
- connman services and status
- Recent journal logs (network, rfkill)

**Access diagnostics from another system:**
```bash
# Mount boot partition from SD card on another PC
sudo mount /dev/sdX1 /mnt
ls /mnt/adu-diags/
cat /mnt/adu-diags/wifi-diag-*.txt
```

### Manual Diagnostic Commands

#### Check Hardware Detection
```bash
# SDIO device detection (BCM43455 on mmc1)
dmesg | grep mmc1:

# Expected: mmc1: new SDIO card at address 0001
```

#### Check Firmware Loading
```bash
# Firmware request and loading
dmesg | grep -E "firmware|brcm"

# Expected: "Firmware: BCM43455/6 wl0: ... version 7.45.265"
```

#### Check Driver Status
```bash
# Driver loaded
lsmod | grep brcmfmac

# Driver info
modinfo brcmfmac | head -20

# Driver messages
dmesg | grep brcmfmac
```

#### Check Network Manager Status
```bash
# connman
systemctl status connman
connmanctl technologies
connmanctl services

# wpa_supplicant
systemctl status wpa_supplicant@wlan0
journalctl -u wpa_supplicant@wlan0 --since "10 minutes ago"
```

#### Check Wireless Capabilities
```bash
# Interface capabilities
iw list | grep -A 20 "Supported interface modes"

# Current connection info
iw dev wlan0 info
iw dev wlan0 link

# Signal strength (when connected)
iw dev wlan0 station dump
```

---

## Auto-Enable WiFi at Boot

By default, WiFi may be rfkill soft blocked on boot. To auto-unblock:

### Option 1: systemd Service (Recommended)

Create `/etc/systemd/system/rfkill-unblock-wifi.service`:
```ini
[Unit]
Description=Unblock WiFi at boot
Before=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock wifi
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
```

Enable the service:
```bash
sudo systemctl daemon-reload
sudo systemctl enable rfkill-unblock-wifi.service
sudo systemctl start rfkill-unblock-wifi.service
```

### Option 2: udev Rule

Create `/etc/udev/rules.d/85-rfkill-unblock-wifi.rules`:
```
# Auto-unblock WiFi on boot
ACTION=="add", SUBSYSTEM=="rfkill", ATTR{type}=="wlan", ATTR{soft}="0"
```

Reload udev rules:
```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### Option 3: Add to Image Recipe (Persistent)

For production images, add to a custom recipe in your layer.

**File structure** (machine-specific for Raspberry Pi 4):
```
recipes-core/base-files/
├── base-files_%.bbappend
└── base-files/
    └── raspberrypi4-64/
        └── rfkill-unblock-wifi.service
```

**Note**: The service file must be placed in the machine-specific subfolder (`raspberrypi4-64/`) to match your `MACHINE` setting. For other Raspberry Pi variants, use the appropriate folder name (e.g., `raspberrypi4/`, `raspberrypi3/`).

`recipes-core/base-files/base-files/raspberrypi4-64/rfkill-unblock-wifi.service`:
```ini
[Unit]
Description=Unblock WiFi at boot
Before=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock wifi
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
```

`recipes-core/base-files/base-files_%.bbappend`:
```bash
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://rfkill-unblock-wifi.service"

inherit systemd

SYSTEMD_SERVICE:${PN} += "rfkill-unblock-wifi.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install:append() {
    if ${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'true', 'false', d)}; then
        install -d ${D}${systemd_system_unitdir}
        install -m 0644 ${WORKDIR}/rfkill-unblock-wifi.service ${D}${systemd_system_unitdir}/
    fi
}

FILES:${PN} += "${systemd_system_unitdir}/rfkill-unblock-wifi.service"
```

---

## Advanced Topics

### Static IP Configuration with connman

Create `/var/lib/connman/wifi.config`:
```ini
[service_wifi_home]
Type=wifi
Name=YourSSID
Passphrase=YourPassword
IPv4=192.168.1.100/255.255.255.0/192.168.1.1
Nameservers=8.8.8.8,8.8.4.4
```

Restart connman:
```bash
sudo systemctl restart connman
```

### Hidden SSID Configuration

Using wpa_supplicant:
```bash
wpa_passphrase "HiddenSSID" "password" | sudo tee -a /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
```

Edit the file and add `scan_ssid=1`:
```
network={
    ssid="HiddenSSID"
    psk=abc123...
    scan_ssid=1
}
```

### WPA Enterprise (802.1X) Configuration

For enterprise networks with RADIUS authentication:

`/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`:
```
network={
    ssid="EnterpriseSSID"
    key_mgmt=WPA-EAP
    eap=PEAP
    identity="username"
    password="password"
    phase2="auth=MSCHAPV2"
}
```

### Bluetooth Pairing

Check Bluetooth status:
```bash
rfkill list bluetooth
bluetoothctl
```

Inside bluetoothctl:
```
[bluetooth]# power on
[bluetooth]# agent on
[bluetooth]# default-agent
[bluetooth]# scan on
[bluetooth]# pair XX:XX:XX:XX:XX:XX
[bluetooth]# connect XX:XX:XX:XX:XX:XX
```

### Performance Tuning

Disable power management for better performance:
```bash
iw dev wlan0 set power_save off
```

To make persistent, add to `/etc/network/if-up.d/wifi-power`:
```bash
#!/bin/sh
if [ "$IFACE" = "wlan0" ]; then
    iw dev wlan0 set power_save off
fi
```

### Monitoring Connection Quality

Real-time signal monitoring:
```bash
watch -n 1 'iw dev wlan0 station dump | grep -E "signal|tx bitrate|rx bitrate"'
```

Connection statistics:
```bash
iw dev wlan0 station dump  # Full connection statistics
iw dev wlan0 link          # Link quality and bitrate
```

---

## Firmware Details

### BCM43455 Chip Information

- **Chip**: Broadcom BCM43455 revision 6 (BCM4345/6)
- **Driver**: brcmfmac (Linux mainline, backport from linux-firmware-rpidistro)
- **Firmware Source**: https://github.com/RPi-Distro/firmware-nonfree
- **License**: Proprietary (synaptics-killswitch)
- **WiFi**: 802.11ac (2.4GHz + 5GHz), up to 433 Mbps
- **Bluetooth**: BT 4.2, BLE

### Firmware Files Location

```
/lib/firmware/brcm/
├── brcmfmac43455-sdio.bin          # Main firmware binary
├── brcmfmac43455-sdio.txt          # NVRAM config (board-specific)
├── brcmfmac43455-sdio.clm_blob     # Country/regulatory data
├── brcmfmac43456-sdio.bin          # Alternative firmware (RPi 4)
├── brcmfmac43456-sdio.clm_blob
└── brcmfmac43455-sdio.raspberrypi,4-model-b.txt → brcmfmac43456-sdio.txt
```

**Key symlinks**: RPi 4 uses BCM43455 chip but loads brcmfmac43456 firmware variant for optimal performance.

### Firmware Version Check

```bash
dmesg | grep "Firmware:"
# Expected: Firmware: BCM43455/6 wl0: Aug 29 2023 01:47:08 version 7.45.265
```

---

## Quick Reference: Common Commands

| Task | Command |
|------|---------|
| Check WiFi status | `ip link show wlan0` |
| Scan networks | `iw dev wlan0 scan \| grep SSID` |
| Unblock WiFi | `rfkill unblock wifi` |
| Connect (connman) | `connmanctl` → `connect wifi_...` |
| Check connection | `connmanctl services` |
| Signal strength | `iw dev wlan0 station dump` |
| View IP address | `ip addr show wlan0` |
| Test connectivity | `ping -c 4 8.8.8.8` |
| Run diagnostics | `sudo /adu/tools/adu-wifi-diagnostics.sh` |
| View logs | `journalctl -u connman --since "10 min ago"` |

---

## Support and Resources

### Log Files
- **connman**: `journalctl -u connman`
- **wpa_supplicant**: `journalctl -u wpa_supplicant@wlan0`
- **rfkill**: `journalctl -u systemd-rfkill`
- **kernel**: `dmesg | grep -E "wlan|brcm|mmc1"`

### Useful Links
- [Raspberry Pi Forums - Networking](https://forums.raspberrypi.com/viewforum.php?f=28)
- [ConnMan Documentation](https://git.kernel.org/pub/scm/network/connman/connman.git/tree/doc)
- [wpa_supplicant Configuration](https://w1.fi/cgit/hostap/plain/wpa_supplicant/wpa_supplicant.conf)
- [Broadcom brcmfmac Driver](https://wireless.wiki.kernel.org/en/users/drivers/brcm80211)

### Getting Help

When reporting WiFi issues, always include:
1. Output of diagnostic script: `/adu/tools/adu-wifi-diagnostics.sh`
2. Build configuration: `ENABLE_WIFI_BLUETOOTH` setting
3. Network details: Security type (WPA2/WPA3), 2.4GHz vs 5GHz
4. Symptoms: Connection timeout, no IP, weak signal, etc.

---

## Appendix: Build Configuration Reference

### Layer: meta-raspberrypi-adu

**Layer path**: `meta-raspberrypi-adu`  
**Distro config**: `meta-raspberrypi-adu/conf/distro/adu-wifi-bluetooth.conf`

**Configuration snippet**:
```python
# meta-raspberrypi-adu/conf/distro/adu-wifi-bluetooth.conf

ENABLE_WIFI_BLUETOOTH ?= "0"

# Accept proprietary BCM43455 firmware license when WiFi/BT enabled
LICENSE_FLAGS_ACCEPTED:append = "${@' synaptics-killswitch' if d.getVar('ENABLE_WIFI_BLUETOOTH') == '1' else ''}"

# Keep wifi/bluetooth in MACHINE_FEATURES when enabled
MACHINE_FEATURES:remove = "${@'' if d.getVar('ENABLE_WIFI_BLUETOOTH') == '1' else 'wifi bluetooth'}"

# Include packagegroup-base-extended when enabled
IMAGE_INSTALL:remove = "${@'' if d.getVar('ENABLE_WIFI_BLUETOOTH') == '1' else 'packagegroup-base-extended'}"
```

**How to enable in your build**:

1. **Method 1: Environment variable (recommended)**
   ```bash
   export ENABLE_WIFI_BLUETOOTH=1
   export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS ENABLE_WIFI_BLUETOOTH"
   source poky/oe-init-build-env build
   bitbake adu-base-image
   ```
   
   **Note**: The `BB_ENV_PASSTHROUGH_ADDITIONS` variable must be set before initializing the build environment to allow BitBake to access the environment variable.

2. **Method 2: local.conf**
   Add to `build/conf/local.conf`:
   ```python
   ENABLE_WIFI_BLUETOOTH = "1"
   ```

3. **Method 3: Custom distro**
   In your distro conf file:
   ```python
   require conf/distro/adu-wifi-bluetooth.conf
   ENABLE_WIFI_BLUETOOTH = "1"
   ```

**Packages installed** (when enabled):
- linux-firmware-rpidistro-bcm43455 (BCM43455/6 firmware)
- wpa-supplicant (WiFi authentication daemon)
- connman, connman-client (network manager)
- iw, wireless-tools (WiFi utilities)
- rfkill (wireless enable/disable)
- bluez5 (Bluetooth stack)
- adu-tools (diagnostic scripts in /adu/tools/)

---

## License

This documentation is provided under the MIT License.
See [LICENSE](LICENSE) for details.

---

**Last Updated**: December 30, 2025  
**Tested On**: Raspberry Pi 4 Model B (4GB/8GB), Yocto Scarthgap (5.0)  
**Firmware Version**: BCM43455/6 wl0 version 7.45.265
