#!/bin/bash
# ADU Splash Screen Diagnostic Script
# Collects comprehensive information about Plymouth, boot splash, and boot menu status
# Usage: Run as root on the target device
#   adu-splash-screen-diagnostics.sh
#
# Output is automatically saved to /boot/adu-diags/splash-screen-diag-<timestamp>.log

set +e  # Don't exit on errors, collect all info

# Create output directory and file
DIAG_DIR="/boot/adu-diags"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE="$DIAG_DIR/splash-screen-diag-$TIMESTAMP.log"

mkdir -p "$DIAG_DIR"

# Redirect all output to file and console
exec > >(tee -a "$OUTPUT_FILE") 2>&1

DIVIDER="========================================================================"

echo "$DIVIDER"
echo "ADU Splash Screen Diagnostics"
echo "Generated: $(date)"
echo "Output: $OUTPUT_FILE"
echo "Hostname: $(hostname)"
echo "Kernel: $(uname -r)"
echo "$DIVIDER"
echo ""

# ============================================================================
# SECTION 1: Kernel Command Line
# ============================================================================
echo "$DIVIDER"
echo "1. KERNEL COMMAND LINE PARAMETERS"
echo "$DIVIDER"
echo ""
echo "Current kernel cmdline:"
cat /proc/cmdline
echo ""
echo "Checking for Plymouth-related parameters:"
grep -o "splash\|quiet\|plymouth\.[^[:space:]]*" /proc/cmdline || echo "  No Plymouth parameters found"
echo ""
echo "Expected: plymouth.enable=0 (present), quiet splash (absent)"
echo ""
echo "Checking for duplicate parameters:"
cmdline=$(cat /proc/cmdline)
for param in root console; do
    count=$(echo "$cmdline" | grep -o "$param=" | wc -l)
    if [ "$count" -gt 1 ]; then
        echo "  ⚠ WARNING: '$param=' appears $count times (duplicates detected)"
    else
        echo "  ✓ '$param=' appears once"
    fi
done
echo ""
echo "Boot configuration files:"
if [ -f /boot/cmdline.txt ]; then
    echo "  /boot/cmdline.txt:"
    cat /boot/cmdline.txt
else
    echo "  /boot/cmdline.txt: NOT FOUND (normal with U-Boot)"
fi
echo ""

# ============================================================================
# SECTION 2: Plymouth Service Status
# ============================================================================
echo "$DIVIDER"
echo "2. PLYMOUTH SYSTEMD SERVICE STATUS"
echo "$DIVIDER"
echo ""

PLYMOUTH_SERVICES=(
    "plymouth-start.service"
    "plymouth-quit.service"
    "plymouth-quit-wait.service"
    "plymouth-read-write.service"
)

for service in "${PLYMOUTH_SERVICES[@]}"; do
    echo "--- $service ---"
    systemctl status "$service" --no-pager --full 2>&1 | head -20
    echo ""
    echo "  Enabled status:"
    systemctl is-enabled "$service" 2>&1
    echo ""
    echo "  Active status:"
    systemctl is-active "$service" 2>&1
    echo ""
done

# ============================================================================
# SECTION 3: File System Check - Service Unit Files
# ============================================================================
echo "$DIVIDER"
echo "3. PLYMOUTH SERVICE UNIT FILE LOCATIONS"
echo "$DIVIDER"
echo ""

echo "A. /etc/systemd/system/ (HIGHEST PRIORITY - overrides):"
ls -la /etc/systemd/system/plymouth*.service 2>&1 || echo "  No Plymouth services found in /etc/systemd/system/"
echo ""

echo "B. /usr/lib/systemd/system/ (LOWER PRIORITY - package defaults):"
ls -la /usr/lib/systemd/system/plymouth*.service 2>&1 || echo "  No Plymouth services found in /usr/lib/systemd/system/"
echo ""

echo "C. /lib/systemd/system/ (symlink to /usr/lib/systemd/system/):"
if [ -L /lib/systemd/system ]; then
    echo "  Symlink target: $(readlink -f /lib/systemd/system)"
fi
ls -la /lib/systemd/system/plymouth*.service 2>&1 || echo "  No Plymouth services found in /lib/systemd/system/"
echo ""

echo "D. Checking symlink targets for masking:"
for service in "${PLYMOUTH_SERVICES[@]}"; do
    echo "  $service:"
    for path in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
        file="$path/$service"
        if [ -e "$file" ] || [ -L "$file" ]; then
            if [ -L "$file" ]; then
                target=$(readlink -f "$file")
                echo "    $file -> $target"
                if [ "$target" = "/dev/null" ]; then
                    echo "      ✓ MASKED (correct)"
                else
                    echo "      ⚠ Symlink but NOT to /dev/null"
                fi
            else
                echo "    $file (regular file - NOT masked)"
            fi
        fi
    done
    echo ""
done

# ============================================================================
# SECTION 4: Systemd Target Dependencies
# ============================================================================
echo "$DIVIDER"
echo "4. SYSTEMD TARGET DEPENDENCIES"
echo "$DIVIDER"
echo ""

echo "A. sysinit.target wants (should include adu-boot-menu, NOT plymouth-start):"
ls -la /etc/systemd/system/sysinit.target.wants/ | grep -E "adu-boot-menu|plymouth" || echo "  No matching services found"
echo ""

echo "B. multi-user.target wants:"
ls -la /etc/systemd/system/multi-user.target.wants/ | grep plymouth || echo "  No Plymouth services found"
echo ""

# ============================================================================
# SECTION 5: ADU Boot Menu Service Status
# ============================================================================
echo "$DIVIDER"
echo "5. ADU BOOT MENU SERVICE STATUS"
echo "$DIVIDER"
echo ""

echo "A. Service status:"
systemctl status adu-boot-menu.service --no-pager --full 2>&1 | head -30
echo ""

echo "B. Service file location:"
systemctl cat adu-boot-menu.service 2>&1
echo ""

echo "C. Enabled status:"
systemctl is-enabled adu-boot-menu.service 2>&1
echo ""

# ============================================================================
# SECTION 6: Plymouth Packages Installed
# ============================================================================
echo "$DIVIDER"
echo "6. PLYMOUTH PACKAGES INSTALLED"
echo "$DIVIDER"
echo ""

if command -v dpkg >/dev/null 2>&1; then
    echo "Debian packages (dpkg):"
    dpkg -l | grep plymouth || echo "  No Plymouth packages found"
elif command -v opkg >/dev/null 2>&1; then
    echo "OpenEmbedded packages (opkg):"
    opkg list-installed | grep plymouth || echo "  No Plymouth packages found"
elif command -v rpm >/dev/null 2>&1; then
    echo "RPM packages:"
    rpm -qa | grep plymouth || echo "  No Plymouth packages found"
else
    echo "  Unknown package manager"
fi
echo ""

echo "ADU Boot Splash package:"
if command -v dpkg >/dev/null 2>&1; then
    dpkg -l | grep adu-boot-splash || echo "  adu-boot-splash NOT installed (dpkg)"
elif command -v opkg >/dev/null 2>&1; then
    opkg list-installed | grep adu-boot-splash || echo "  adu-boot-splash NOT installed (opkg)"
else
    echo "  Cannot check (unknown package manager)"
fi
echo ""

# ============================================================================
# SECTION 7: Plymouth Binaries and Processes
# ============================================================================
echo "$DIVIDER"
echo "7. PLYMOUTH BINARIES AND RUNNING PROCESSES"
echo "$DIVIDER"
echo ""

echo "A. Plymouth daemon binary:"
which plymouthd 2>&1 || echo "  plymouthd NOT found in PATH"
ls -la /usr/sbin/plymouthd 2>&1 || echo "  /usr/sbin/plymouthd NOT found"
echo ""

echo "B. Plymouth client binary:"
which plymouth 2>&1 || echo "  plymouth NOT found in PATH"
ls -la /usr/bin/plymouth 2>&1 || echo "  /usr/bin/plymouth NOT found"
echo ""

echo "C. Running Plymouth processes:"
ps aux | grep "[p]lymouth" || echo "  No Plymouth processes running"
echo ""

echo "D. Plymouth PID file:"
if [ -f /run/plymouth/pid ]; then
    echo "  /run/plymouth/pid exists:"
    cat /run/plymouth/pid
    pid=$(cat /run/plymouth/pid)
    if ps -p "$pid" >/dev/null 2>&1; then
        echo "  ✓ Process $pid is running"
    else
        echo "  ⚠ PID file exists but process $pid is NOT running"
    fi
else
    echo "  /run/plymouth/pid does NOT exist (good - Plymouth not running)"
fi
echo ""

# ============================================================================
# SECTION 8: Boot Logs and Timing
# ============================================================================
echo "$DIVIDER"
echo "8. BOOT LOGS AND TIMING"
echo "$DIVIDER"
echo ""

echo "A. Systemd boot analysis:"
systemd-analyze 2>&1 || echo "  systemd-analyze failed"
echo ""

echo "B. Critical chain for adu-boot-menu:"
systemd-analyze critical-chain adu-boot-menu.service 2>&1 || echo "  Failed to analyze critical chain"
echo ""

echo "C. Service timing (first 30 services):"
systemd-analyze blame 2>&1 | head -30 || echo "  Failed to get blame info"
echo ""

echo "D. Plymouth-related boot logs:"
journalctl -b | grep -i plymouth | head -50 || echo "  No Plymouth-related boot logs found"
echo ""

echo "E. ADU boot menu logs:"
journalctl -b -u adu-boot-menu.service --no-pager || echo "  No adu-boot-menu logs found"
echo ""

# ============================================================================
# SECTION 9: Console and TTY Status
# ============================================================================
echo "$DIVIDER"
echo "9. CONSOLE AND TTY STATUS"
echo "$DIVIDER"
echo ""

echo "A. Active consoles:"
cat /sys/class/tty/console/active 2>&1 || echo "  Failed to read active consoles"
echo ""

echo "B. TTY devices:"
ls -la /dev/tty[0-9]* 2>&1 | head -10
echo ""

echo "C. Current TTY:"
tty 2>&1
echo ""

echo "D. Framebuffer devices:"
ls -la /dev/fb* 2>&1 || echo "  No framebuffer devices found"
echo ""

# ============================================================================
# SECTION 10: Plymouth Themes
# ============================================================================
echo "$DIVIDER"
echo "10. PLYMOUTH THEMES"
echo "$DIVIDER"
echo ""

echo "A. Installed themes:"
ls -la /usr/share/plymouth/themes/ 2>&1 || echo "  /usr/share/plymouth/themes/ not found"
echo ""

echo "B. Plymouth configuration:"
if [ -f /etc/plymouth/plymouthd.conf ]; then
    echo "  /etc/plymouth/plymouthd.conf:"
    cat /etc/plymouth/plymouthd.conf
else
    echo "  /etc/plymouth/plymouthd.conf NOT found"
fi
echo ""

# ============================================================================
# SECTION 11: U-Boot Environment (if accessible)
# ============================================================================
echo "$DIVIDER"
echo "11. U-BOOT CONFIGURATION"
echo "$DIVIDER"
echo ""

if [ -f /boot/boot.scr ]; then
    echo "A. /boot/boot.scr exists (compiled U-Boot script)"
    ls -la /boot/boot.scr
    echo ""
    echo "Extracting readable content from boot.scr:"
    strings /boot/boot.scr | grep -E "bootargs|quiet|splash|plymouth|root=" | head -20
    echo ""
fi

if [ -f /boot/boot.cmd ]; then
    echo "B. /boot/boot.cmd (source U-Boot script):"
    cat /boot/boot.cmd
else
    echo "B. /boot/boot.cmd NOT found"
fi
echo ""

echo "C. U-Boot environment variables (if fw_printenv available):"
if command -v fw_printenv >/dev/null 2>&1; then
    fw_printenv 2>&1 | grep -E "boot_partition|bootargs|upgrade_available" || echo "  No relevant U-Boot variables found"
else
    echo "  fw_printenv not available"
fi
echo ""

# ============================================================================
# SECTION 12: Raspberry Pi Config
# ============================================================================
echo "$DIVIDER"
echo "12. RASPBERRY PI CONFIGURATION"
echo "$DIVIDER"
echo ""

if [ -f /boot/config.txt ]; then
    echo "A. /boot/config.txt:"
    cat /boot/config.txt | grep -v "^#" | grep -v "^$"
else
    echo "A. /boot/config.txt NOT found"
fi
echo ""

# ============================================================================
# SECTION 13: Summary and Recommendations
# ============================================================================
echo "$DIVIDER"
echo "13. DIAGNOSTIC SUMMARY"
echo "$DIVIDER"
echo ""

echo "Checking for common issues:"
echo ""

# Check 1: Kernel cmdline has splash
if grep -q "splash" /proc/cmdline; then
    echo "❌ ISSUE: Kernel cmdline contains 'splash' parameter"
    echo "   Action: Remove 'splash' from U-Boot boot.cmd.in or distro configuration"
else
    echo "✓ OK: No 'splash' parameter in kernel cmdline"
fi
echo ""

# Check 1b: Kernel cmdline has quiet
if grep -q "quiet" /proc/cmdline; then
    echo "❌ ISSUE: Kernel cmdline contains 'quiet' parameter (hides boot messages)"
    echo "   Action: Remove 'quiet' from U-Boot boot.cmd.in or distro configuration"
else
    echo "✓ OK: No 'quiet' parameter in kernel cmdline"
fi
echo ""

# Check 1c: Kernel cmdline has plymouth.enable=0
if grep -q "plymouth.enable=0" /proc/cmdline; then
    echo "✓ OK: plymouth.enable=0 found in kernel cmdline"
else
    echo "❌ ISSUE: plymouth.enable=0 NOT found in kernel cmdline"
    echo "   Action: Add plymouth.enable=0 to U-Boot boot.cmd.in or distro configuration"
fi
echo ""

# Check 1d: Duplicate root= parameter
root_count=$(grep -o "root=" /proc/cmdline | wc -l)
if [ "$root_count" -gt 1 ]; then
    echo "❌ ISSUE: 'root=' appears $root_count times in kernel cmdline (duplicates)"
    echo "   Cmdline: $(cat /proc/cmdline)"
    echo "   Action: Fix U-Boot boot.cmd.in to use clean bootargs without duplicates"
else
    echo "✓ OK: 'root=' parameter appears only once"
fi
echo ""

# Check 2: Plymouth services not masked
issue_found=0
for service in "${PLYMOUTH_SERVICES[@]}"; do
    if [ -e "/etc/systemd/system/$service" ]; then
        if [ -L "/etc/systemd/system/$service" ]; then
            target=$(readlink "/etc/systemd/system/$service")
            if [ "$target" != "/dev/null" ]; then
                echo "❌ ISSUE: $service is symlink but NOT to /dev/null"
                issue_found=1
            fi
        else
            echo "❌ ISSUE: $service exists in /etc but is NOT a symlink (should be symlink to /dev/null)"
            issue_found=1
        fi
    else
        echo "❌ ISSUE: $service NOT found in /etc/systemd/system/ (masking missing)"
        issue_found=1
    fi
done

if [ $issue_found -eq 0 ]; then
    echo "✓ OK: All Plymouth services properly masked in /etc/systemd/system/"
fi
echo ""

# Check 3: Plymouth process running
if pgrep -x plymouthd >/dev/null; then
    echo "❌ ISSUE: plymouthd process is running (should NOT be running)"
    echo "   PID: $(pgrep -x plymouthd)"
elif [ -f /run/plymouth/pid ]; then
    echo "⚠ WARNING: /run/plymouth/pid exists but process not running (stale PID file)"
else
    echo "✓ OK: Plymouth daemon not running"
fi
echo ""

# Check 4: adu-boot-menu service enabled
if systemctl is-enabled adu-boot-menu.service >/dev/null 2>&1; then
    echo "✓ OK: adu-boot-menu.service is enabled"
else
    echo "❌ ISSUE: adu-boot-menu.service is NOT enabled"
    echo "   Action: Run 'systemctl enable adu-boot-menu.service'"
fi
echo ""

# Check 5: adu-boot-splash package installed
if command -v opkg >/dev/null 2>&1; then
    if opkg list-installed | grep -q adu-boot-splash; then
        echo "✓ OK: adu-boot-splash package is installed"
    else
        echo "❌ ISSUE: adu-boot-splash package NOT installed"
        echo "   Action: Install adu-boot-splash package"
    fi
elif command -v dpkg >/dev/null 2>&1; then
    if dpkg -l | grep -q adu-boot-splash; then
        echo "✓ OK: adu-boot-splash package is installed"
    else
        echo "❌ ISSUE: adu-boot-splash package NOT installed"
        echo "   Action: Install adu-boot-splash package"
    fi
fi
echo ""

echo "$DIVIDER"
echo "END OF DIAGNOSTICS"
echo "$DIVIDER"
echo ""
echo "Diagnostic report saved to: $OUTPUT_FILE"
echo ""
echo "To retrieve this file from the device:"
echo "  scp root@<device-ip>:$OUTPUT_FILE ."
echo ""
echo "Previous diagnostic reports in $DIAG_DIR:"
ls -lh "$DIAG_DIR"/splash-screen-diag-*.log 2>/dev/null | tail -5 || echo "  (none)"
