#!/bin/bash
################################################################################
# ADU WiFi Diagnostics Script
# 
# Purpose: Collect comprehensive WiFi/Bluetooth diagnostic information for
#          troubleshooting connectivity issues on Raspberry Pi 4 ADU images.
#
# Usage:   sudo /adu/tools/adu-wifi-diagnostics.sh [output_file]
#
# Output:  /boot/adu-diags/wifi-diag-YYYYMMDD-HHMMSS.txt (default)
#          or custom path specified as argument
#
# License: MIT
################################################################################

set -e

# Configuration
DEFAULT_OUTPUT_DIR="/boot/adu-diags"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEFAULT_OUTPUT_FILE="${DEFAULT_OUTPUT_DIR}/wifi-diag-${TIMESTAMP}.txt"

# Use custom output file if provided, otherwise use default
OUTPUT_FILE="${1:-$DEFAULT_OUTPUT_FILE}"
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Helper function to print section headers
print_section() {
    echo "" | tee -a "$OUTPUT_FILE"
    echo "========================================================================" | tee -a "$OUTPUT_FILE"
    echo "  $1" | tee -a "$OUTPUT_FILE"
    echo "========================================================================" | tee -a "$OUTPUT_FILE"
    echo "" | tee -a "$OUTPUT_FILE"
}

# Helper function to run command and capture output
run_cmd() {
    local cmd="$1"
    local desc="$2"
    
    echo "--- $desc ---" >> "$OUTPUT_FILE"
    echo "Command: $cmd" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    
    if eval "$cmd" >> "$OUTPUT_FILE" 2>&1; then
        echo "[SUCCESS]" >> "$OUTPUT_FILE"
    else
        local exit_code=$?
        echo "[FAILED] Exit code: $exit_code" >> "$OUTPUT_FILE"
    fi
    echo "" >> "$OUTPUT_FILE"
}

# Start diagnostics
{
    echo "################################################################################"
    echo "#  ADU WiFi/Bluetooth Diagnostics Report"
    echo "#  Generated: $(date)"
    echo "#  Hostname: $(hostname)"
    echo "################################################################################"
} > "$OUTPUT_FILE"

echo "Starting WiFi diagnostics collection..."
echo "Output will be saved to: $OUTPUT_FILE"

# ==============================================================================
# SECTION 1: System Information
# ==============================================================================
print_section "SECTION 1: System Information"

run_cmd "date" "Current Date/Time"
run_cmd "hostname" "Hostname"
run_cmd "uptime" "System Uptime"
run_cmd "uname -a" "Kernel Version"
run_cmd "cat /etc/os-release" "OS Release Information"
run_cmd "cat /proc/cpuinfo | grep -E 'Model|Hardware|Revision'" "CPU/Board Information"
run_cmd "free -h" "Memory Usage"
run_cmd "df -h" "Disk Usage"

# ==============================================================================
# SECTION 2: Network Interfaces
# ==============================================================================
print_section "SECTION 2: Network Interfaces"

run_cmd "ip link show" "Network Interfaces (Link Layer)"
run_cmd "ip addr show" "Network Interfaces (IP Addresses)"
run_cmd "ip route show" "Routing Table"
run_cmd "cat /etc/resolv.conf" "DNS Configuration"

# ==============================================================================
# SECTION 3: WiFi Interface Details
# ==============================================================================
print_section "SECTION 3: WiFi Interface Details"

run_cmd "ip link show wlan0" "wlan0 Interface Status"
run_cmd "iw dev wlan0 info" "wlan0 Device Information"
run_cmd "iw dev wlan0 link" "wlan0 Link Status"
run_cmd "iw dev wlan0 station dump" "wlan0 Station Information (Signal)"
run_cmd "iw list" "WiFi Capabilities (Full)"
run_cmd "iwconfig wlan0" "wlan0 Wireless Config (legacy)"

# WiFi scan (may fail if not unblocked or powered)
echo "--- WiFi Network Scan ---" >> "$OUTPUT_FILE"
echo "Command: iw dev wlan0 scan" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
if timeout 10 iw dev wlan0 scan >> "$OUTPUT_FILE" 2>&1; then
    echo "[SUCCESS] Scan completed" >> "$OUTPUT_FILE"
else
    exit_code=$?
    echo "[FAILED/TIMEOUT] Exit code: $exit_code" >> "$OUTPUT_FILE"
    echo "Note: Scan may fail if WiFi is blocked or interface is down" >> "$OUTPUT_FILE"
fi
echo "" >> "$OUTPUT_FILE"

# ==============================================================================
# SECTION 4: rfkill Status
# ==============================================================================
print_section "SECTION 4: rfkill Status (WiFi/Bluetooth Enable/Disable)"

run_cmd "rfkill list" "All rfkill Devices"
run_cmd "rfkill list wifi" "WiFi rfkill Status"
run_cmd "rfkill list bluetooth" "Bluetooth rfkill Status"

# ==============================================================================
# SECTION 5: Firmware and Driver
# ==============================================================================
print_section "SECTION 5: Firmware and Driver"

run_cmd "ls -lah /lib/firmware/brcm/brcmfmac43455*" "BCM43455 Firmware Files"
run_cmd "ls -lah /lib/firmware/brcm/brcmfmac43456*" "BCM43456 Firmware Files"

echo "--- Firmware Loading from dmesg ---" >> "$OUTPUT_FILE"
dmesg | grep -i "firmware" | grep -i "brcm" >> "$OUTPUT_FILE" 2>&1 || echo "[No firmware messages found]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

run_cmd "lsmod | grep brcm" "Loaded Broadcom Kernel Modules"
run_cmd "modinfo brcmfmac" "brcmfmac Driver Information"

# ==============================================================================
# SECTION 6: dmesg Logs (WiFi/Bluetooth)
# ==============================================================================
print_section "SECTION 6: Kernel Logs (dmesg)"

echo "--- BCM/Broadcom Messages ---" >> "$OUTPUT_FILE"
dmesg | grep -i "bcm" | tail -100 >> "$OUTPUT_FILE" 2>&1 || echo "[No BCM messages found]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "--- brcmfmac Driver Messages ---" >> "$OUTPUT_FILE"
dmesg | grep -i "brcmfmac" | tail -100 >> "$OUTPUT_FILE" 2>&1 || echo "[No brcmfmac messages found]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "--- wlan0 Interface Messages ---" >> "$OUTPUT_FILE"
dmesg | grep -i "wlan0" | tail -100 >> "$OUTPUT_FILE" 2>&1 || echo "[No wlan0 messages found]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "--- SDIO/MMC Messages (WiFi chip on mmc1) ---" >> "$OUTPUT_FILE"
dmesg | grep -E "mmc1:|sdio" | tail -50 >> "$OUTPUT_FILE" 2>&1 || echo "[No SDIO messages found]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "--- Bluetooth Messages ---" >> "$OUTPUT_FILE"
dmesg | grep -i "bluetooth\|hci0" | tail -50 >> "$OUTPUT_FILE" 2>&1 || echo "[No Bluetooth messages found]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "--- Firmware Version from dmesg ---" >> "$OUTPUT_FILE"
dmesg | grep "Firmware:" >> "$OUTPUT_FILE" 2>&1 || echo "[Firmware version not found in dmesg]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# ==============================================================================
# SECTION 7: wpa_supplicant
# ==============================================================================
print_section "SECTION 7: wpa_supplicant"

run_cmd "systemctl status wpa_supplicant@wlan0 --no-pager" "wpa_supplicant@wlan0 Service Status"
run_cmd "ps aux | grep wpa_supplicant" "wpa_supplicant Processes"

if [ -f /etc/wpa_supplicant/wpa_supplicant-wlan0.conf ]; then
    echo "--- wpa_supplicant Configuration (passwords redacted) ---" >> "$OUTPUT_FILE"
    grep -v "psk=" /etc/wpa_supplicant/wpa_supplicant-wlan0.conf >> "$OUTPUT_FILE" 2>&1 || echo "[Config file exists but could not read]" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
else
    echo "[wpa_supplicant config not found at /etc/wpa_supplicant/wpa_supplicant-wlan0.conf]" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
fi

echo "--- wpa_supplicant Logs (last 50 lines) ---" >> "$OUTPUT_FILE"
journalctl -u wpa_supplicant@wlan0 --no-pager -n 50 >> "$OUTPUT_FILE" 2>&1 || echo "[No wpa_supplicant logs available]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# ==============================================================================
# SECTION 8: connman (Connection Manager)
# ==============================================================================
print_section "SECTION 8: connman (Connection Manager)"

run_cmd "systemctl status connman --no-pager" "connman Service Status"
run_cmd "connmanctl technologies" "connman Technologies"
run_cmd "connmanctl services" "connman Services"
run_cmd "connmanctl state" "connman State"

echo "--- connman Logs (last 50 lines) ---" >> "$OUTPUT_FILE"
journalctl -u connman --no-pager -n 50 >> "$OUTPUT_FILE" 2>&1 || echo "[No connman logs available]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# ==============================================================================
# SECTION 9: systemd Journal (Network/rfkill)
# ==============================================================================
print_section "SECTION 9: systemd Journal Logs"

echo "--- Network-related Logs (last 100 lines) ---" >> "$OUTPUT_FILE"
journalctl --no-pager -n 100 | grep -i "network\|wlan\|wifi\|connman\|wpa" >> "$OUTPUT_FILE" 2>&1 || echo "[No network logs found]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "--- rfkill Service Logs (last 20 lines) ---" >> "$OUTPUT_FILE"
journalctl -u systemd-rfkill --no-pager -n 20 >> "$OUTPUT_FILE" 2>&1 || echo "[No rfkill logs available]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# ==============================================================================
# SECTION 10: Bluetooth Status
# ==============================================================================
print_section "SECTION 10: Bluetooth Status"

echo "--- Bluetooth HCI Configuration ---" >> "$OUTPUT_FILE"
if command -v hciconfig >/dev/null 2>&1; then
    hciconfig -a >> "$OUTPUT_FILE" 2>&1 || echo "[hciconfig failed]" >> "$OUTPUT_FILE"
else
    echo "[hciconfig not available - deprecated in newer BlueZ]" >> "$OUTPUT_FILE"
fi
echo "" >> "$OUTPUT_FILE"

run_cmd "bluetoothctl show" "Bluetooth Controller Info"
run_cmd "systemctl status bluetooth --no-pager" "Bluetooth Service Status"

echo "--- Bluetooth Logs (last 30 lines) ---" >> "$OUTPUT_FILE"
journalctl -u bluetooth --no-pager -n 30 >> "$OUTPUT_FILE" 2>&1 || echo "[No Bluetooth logs available]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# ==============================================================================
# SECTION 11: PCI/USB Devices
# ==============================================================================
print_section "SECTION 11: Hardware Detection"

run_cmd "lsusb" "USB Devices"
run_cmd "dmesg | grep 'usb' | tail -50" "Recent USB Messages"

# ==============================================================================
# SECTION 12: Environment Variables
# ==============================================================================
print_section "SECTION 12: Environment Variables"

echo "--- Network-related Environment Variables ---" >> "$OUTPUT_FILE"
env | grep -i "network\|wifi\|wlan\|proxy" >> "$OUTPUT_FILE" 2>&1 || echo "[No network-related env vars]" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# ==============================================================================
# SECTION 13: Configuration Files
# ==============================================================================
print_section "SECTION 13: Configuration Files"

if [ -f /etc/network/interfaces ]; then
    run_cmd "cat /etc/network/interfaces" "Network Interfaces Config"
else
    echo "[/etc/network/interfaces not found - system may use systemd-networkd]" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
fi

run_cmd "ls -la /etc/systemd/network/" "systemd-networkd Configs"
run_cmd "ls -la /var/lib/connman/" "connman Configs"

# ==============================================================================
# SECTION 14: Summary and Recommendations
# ==============================================================================
print_section "SECTION 14: Summary and Recommendations"

{
    echo "Diagnostic Summary:"
    echo ""
    
    # Check wlan0 exists
    if ip link show wlan0 >/dev/null 2>&1; then
        echo "✓ wlan0 interface exists"
    else
        echo "✗ wlan0 interface NOT FOUND"
        echo "  → Check if WiFi firmware/driver is loaded (see Section 5)"
    fi
    
    # Check rfkill
    if rfkill list wifi | grep -q "Soft blocked: yes"; then
        echo "✗ WiFi is soft blocked by rfkill"
        echo "  → Run: rfkill unblock wifi"
    else
        echo "✓ WiFi is not soft blocked"
    fi
    
    # Check firmware loaded
    if dmesg | grep -q "Firmware: BCM43455"; then
        echo "✓ BCM43455 firmware loaded successfully"
        VERSION=$(dmesg | grep "Firmware: BCM43455" | tail -1 | awk '{print $NF}')
        echo "  Version: $VERSION"
    else
        echo "✗ BCM43455 firmware NOT detected in dmesg"
        echo "  → Check firmware files in /lib/firmware/brcm/ (see Section 5)"
    fi
    
    # Check connman status
    if systemctl is-active --quiet connman; then
        echo "✓ connman service is running"
    else
        echo "✗ connman service is NOT running"
        echo "  → Run: systemctl start connman"
    fi
    
    # Check wlan0 has IP
    if ip addr show wlan0 | grep -q "inet "; then
        IP=$(ip addr show wlan0 | grep "inet " | awk '{print $2}')
        echo "✓ wlan0 has IP address: $IP"
    else
        echo "⚠ wlan0 does not have an IP address"
        echo "  → Check if connected to WiFi network"
    fi
    
    echo ""
    echo "Next Steps:"
    echo "1. Review firmware loading (Section 5 and 6)"
    echo "2. Check rfkill status (Section 4)"
    echo "3. Review connman/wpa_supplicant logs (Section 7 and 8)"
    echo "4. For detailed troubleshooting, see: meta-raspberrypi-adu/docs/README-ADU-RPI-NETWORK.md"
    echo ""
    echo "For support, share this diagnostic file: $OUTPUT_FILE"
    
} >> "$OUTPUT_FILE"

# ==============================================================================
# Completion
# ==============================================================================
{
    echo ""
    echo "################################################################################"
    echo "#  Diagnostics Collection Complete"
    echo "#  Output: $OUTPUT_FILE"
    echo "#  Timestamp: $(date)"
    echo "################################################################################"
} >> "$OUTPUT_FILE"

# Print summary to console
echo ""
echo "========================================================================="
echo "  WiFi Diagnostics Collection Complete"
echo "========================================================================="
echo ""
echo "Output file: $OUTPUT_FILE"
echo "File size: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo ""
echo "Quick checks:"

# Quick console summary
if ip link show wlan0 >/dev/null 2>&1; then
    echo "  ✓ wlan0 interface exists"
else
    echo "  ✗ wlan0 interface NOT FOUND"
fi

if rfkill list wifi | grep -q "Soft blocked: yes"; then
    echo "  ✗ WiFi is soft blocked - run: rfkill unblock wifi"
else
    echo "  ✓ WiFi is not soft blocked"
fi

if dmesg | grep -q "Firmware: BCM43455"; then
    echo "  ✓ BCM43455 firmware loaded"
else
    echo "  ✗ BCM43455 firmware NOT loaded"
fi

if systemctl is-active --quiet connman; then
    echo "  ✓ connman service running"
else
    echo "  ✗ connman service NOT running"
fi

echo ""
echo "For detailed analysis, review: $OUTPUT_FILE"
echo ""
echo "To access from another system (e.g., if WiFi not working):"
echo "  1. Remove SD card"
echo "  2. Mount boot partition on another PC"
echo "  3. Read: /boot/adu-diags/wifi-diag-*.txt"
echo ""
echo "========================================================================="

exit 0
