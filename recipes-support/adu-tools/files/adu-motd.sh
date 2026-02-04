#!/bin/bash
# ADU Device Login Banner
# Shows device status and helpful information on login

# Detect Unicode emoji support
# Check if terminal supports UTF-8 and has emoji-capable font
has_emoji_support() {
    # Check UTF-8 locale
    if [[ "$LANG" =~ UTF-8 ]] || [[ "$LC_ALL" =~ UTF-8 ]]; then
        # Check if we're in a graphical terminal (likely has emoji fonts)
        if [ -n "$SSH_CONNECTION" ] || [ "$TERM" = "xterm-256color" ] || [ "$TERM" = "screen-256color" ]; then
            return 0
        fi
    fi
    return 1
}

# Color definitions
if [ -t 1 ] && [ -n "$TERM" ] && [ "$TERM" != "dumb" ]; then
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    BLUE='' CYAN='' GREEN='' YELLOW='' RED='' BOLD='' NC=''
fi

# Set symbols based on terminal capability
if has_emoji_support; then
    # Modern terminals with emoji support
    ICON_CHECK="✅"
    ICON_CROSS="❌"
    ICON_WARN="⚠️"
    ICON_INFO="ℹ️"
    ICON_WIFI="📶"
    ICON_NETWORK="🌐"
    ICON_TEMP="🌡️"
    ICON_MEMORY="💾"
    ICON_DISK="💿"
    ICON_CLOUD="☁️"
    ICON_ROCKET="🚀"
    ICON_BLANK=" "
else
    # # Fallback to basic Unicode symbols
    # ICON_CHECK="${GREEN}✓${NC}"
    # ICON_CROSS="${RED}✗${NC}"
    # ICON_WARN="${YELLOW}⚠${NC}"
    # ICON_INFO="${BLUE}ℹ${NC}"
    # ICON_WIFI="WiFi"
    # ICON_NETWORK="Net"
    # ICON_TEMP="Temp"
    # ICON_MEMORY="Mem"
    # ICON_DISK="Disk"
    # ICON_CLOUD="Cloud"
    # ICON_ROCKET="=>"

     # Fallback to basic Unicode symbols
    ICON_CHECK="${GREEN}(+)${NC}"
    ICON_CROSS="${RED}(X)${NC}"
    ICON_WARN="${YELLOW}(!)${NC}"
    ICON_INFO="${BLUE}(i)${NC}"
    ICON_WIFI="   "
    ICON_NETWORK="   "
    ICON_TEMP="   "
    ICON_MEMORY="   "
    ICON_DISK="   "
    ICON_CLOUD="   "
    ICON_ROCKET="   "
    ICON_BLANK="   "
fi

# Clear screen for clean display
clear

# Banner
echo -e "${BOLD}######################################${NC}"
echo -e "${BOLD}#  Azure Device Update - IoT Device  #${NC}"                    
echo -e "${BOLD}######################################${NC}"
echo ""

# System Information
echo -e "${BOLD}SYSTEM INFORMATION${NC}"
echo -e "${BOLD}==================${NC}"
hostname_info=$(hostname)
uptime_info=$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}')
kernel_info=$(uname -r)
cpu_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f°C", $1/1000}' || echo "N/A")
mem_info=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
disk_info=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 " used)"}')

echo -e "  ${CYAN}Hostname:${NC}  $hostname_info"
echo -e "  ${CYAN}Uptime:${NC}    $uptime_info"
echo -e "  ${CYAN}Kernel:${NC}    $kernel_info"
echo -e "  ${CYAN}CPU Temp:${NC}  $cpu_temp"
echo -e "  ${CYAN}Memory:${NC}    $mem_info"
echo -e "  ${CYAN}Disk:${NC}      $disk_info"
echo ""

# Network Status
echo -e "${BOLD}NETWORK STATUS${NC}"
echo -e "${BOLD}==============${NC}"

# Check WiFi connection
if ip link show wlan0 &>/dev/null; then
    wifi_state=$(ip link show wlan0 | grep "state UP" &>/dev/null && echo "UP" || echo "DOWN")
    if [ "$wifi_state" = "UP" ]; then
        wifi_ip=$(ip addr show wlan0 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        wifi_ssid=$(iw dev wlan0 info 2>/dev/null | grep ssid | awk '{print $2}')
        signal=$(iw dev wlan0 link 2>/dev/null | grep signal | awk '{print $2" "$3}')
        
        if [ -n "$wifi_ssid" ]; then
            echo -e "  $ICON_CHECK $ICON_WIFI ${CYAN}WiFi:${NC}     Connected to ${BOLD}$wifi_ssid${NC}"
            echo -e "  $ICON_BLANK $ICON_BLANK ${CYAN}IP:${NC}       $wifi_ip"
            echo -e "  $ICON_BLANK $ICON_BLANK ${CYAN}Signal:${NC}   $signal"
        else
            echo -e "  $ICON_WARN $ICON_WIFI ${CYAN}WiFi:${NC}     Interface UP, not connected"
        fi
    else
        echo -e "  $ICON_CROSS $ICON_WIFI ${CYAN}WiFi:${NC}     Interface DOWN"
    fi
else
    echo -e "  $ICON_CROSS $ICON_WIFI ${CYAN}WiFi:${NC}     Not available"
fi

# Check Ethernet
if ip link show eth0 &>/dev/null; then
    eth_state=$(ip link show eth0 | grep "state UP" &>/dev/null && echo "UP" || echo "DOWN")
    if [ "$eth_state" = "UP" ]; then
        eth_ip=$(ip addr show eth0 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        echo -e "  $ICON_BLANK $ICON_CHECK ${CYAN}Ethernet:${NC} $eth_ip"
    else
        echo -e "  $ICON_BLANK $ICON_WARN ${CYAN}Ethernet:${NC} Disconnected"
    fi
fi

# Internet connectivity
if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    echo -e "  $ICON_CHECK $ICON_NETWORK ${CYAN}Internet:${NC} Connected"
else
    echo -e "  $ICON_CROSS $ICON_NETWORK ${CYAN}Internet:${NC} No connectivity"
fi
echo ""

# ADU Agent Status
echo -e "${BOLD}AZURE DEVICE UPDATE${NC}"
echo -e "${BOLD}===================${NC}"

if systemctl is-active --quiet deviceupdate-agent.service 2>/dev/null; then
    echo -e "  $ICON_CHECK ${CYAN}ADU Agent:${NC}   Running"
    
    # Check if configured
    if [ -f /adu/conf/du-config.json ]; then
        if grep -q '"connectionType": "string"' /adu/conf/du-config.json 2>/dev/null; then
            echo -e "  $ICON_WARN ${CYAN}Config:${NC}      Not configured (using template)"
        else
            echo -e "  $ICON_CHECK ${CYAN}Config:${NC}      Configured"
        fi
    else
        echo -e "  $ICON_CROSS ${CYAN}Config:${NC}      Missing"
    fi
else
    echo -e "  $ICON_CROSS ${CYAN}ADU Agent:${NC}   Stopped"
fi

# Show version if available
if [ -f /etc/adu-version ]; then
    adu_version=$(cat /etc/adu-version)
    echo -e "  ${CYAN}Installed Criteria (etc/adu-version):${NC}     $adu_version"
fi
echo ""

# Quick Reference
echo -e "${BOLD}QUICK REFERENCE${NC}"
echo -e "${BOLD}===============${NC}"
echo -e "  ${CYAN}WiFi Setup:${NC}             sudo adu-wifi-setup.sh"
echo -e "  ${CYAN}WiFi Diagnostics:${NC}       sudo adu-wifi-diagnostics.sh"
echo -e "  ${CYAN}ADU Diagnostics:${NC}        sudo adu-diag"
echo -e "  ${CYAN}Health Check:${NC}            sudo adu-health-check"
echo -e "  ${CYAN}Boot Validation:${NC}         sudo adu-confirm-boot"
echo -e "  ${CYAN}ADU Control:${NC}             adu-ctl service [start|stop|restart|status]"
echo -e ""
echo -e "  ${CYAN}ADU Config:${NC}              sudo nano /etc/adu/du-config.json"
echo -e "  ${CYAN}ADU Logs:${NC}                tail -f /var/log/adu/du-agent.log"
echo -e "  ${CYAN}DO Service:${NC}              sudo systemctl status deliveryoptimization-agent"
echo -e "  ${CYAN}ADU Service:${NC}             sudo systemctl status deviceupdate-agent"
echo -e ""
echo -e "  ${CYAN}Getting Started:${NC}         cat /usr/share/adu/GETTING-STARTED.txt"
echo ""
echo -e "${BOLD}=================================================${NC}"
echo -e "      Ready to deploy Azure IoT updates!${NC}"
echo -e "${BOLD}=================================================${NC}"
echo ""
