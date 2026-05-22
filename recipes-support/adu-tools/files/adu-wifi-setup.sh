#!/bin/bash
# ADU WiFi Setup - Interactive WiFi connection helper
# Description: Guides user through WiFi setup with connmanctl
# Usage: sudo adu-wifi-setup.sh

set -u

# Detect color support (gracefully degrades on basic consoles)
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    # Terminal supports colors
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    # Plain text for basic consoles
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    echo "Usage: sudo $0"
    exit 1
fi

# Check if connmanctl is available
if ! command -v connmanctl &> /dev/null; then
    echo -e "${RED}Error: connmanctl not found${NC}"
    echo "Please install connman package"
    exit 1
fi

echo "==============================================================================="
echo -e "  ${BLUE}Azure Device Update - WiFi Setup Wizard${NC}"
echo "==============================================================================="
echo ""

# Function to print status
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Step 1: Enable WiFi
echo "Step 1: Enabling WiFi..."
if connmanctl enable wifi &>/dev/null; then
    print_status "WiFi enabled"
else
    print_warning "WiFi may already be enabled"
fi
sleep 1

# Step 2: Check WiFi hardware
echo ""
echo "Step 2: Checking WiFi hardware..."
if rfkill list wifi | grep -q "Soft blocked: no"; then
    print_status "WiFi hardware is active"
elif rfkill list wifi | grep -q "Soft blocked: yes"; then
    print_error "WiFi is soft-blocked (disabled in software)"
    echo ""
    read -p "Do you want to unblock WiFi? (Y/n): " unblock_choice
    if [ "$unblock_choice" = "n" ] || [ "$unblock_choice" = "N" ]; then
        echo "WiFi setup cancelled. WiFi remains blocked."
        echo "To unblock later, run: sudo rfkill unblock wifi"
        exit 0
    fi
    
    print_info "Unblocking WiFi..."
    rfkill unblock wifi
    sleep 1
    if rfkill list wifi | grep -q "Soft blocked: no"; then
        print_status "WiFi unblocked successfully"
    else
        print_error "Failed to unblock WiFi. Please check hardware switch."
        exit 1
    fi
else
    print_warning "Could not determine WiFi hardware status"
fi

# Step 3: Ensure WiFi is enabled in ConnMan
echo ""
echo "Step 3: Enabling WiFi technology..."
if ! connmanctl enable wifi 2>/dev/null; then
    print_warning "WiFi already enabled or command failed"
fi
sleep 1

# Step 4: Scan for networks
echo ""
echo "Step 4: Scanning for WiFi networks..."
print_info "This may take a few seconds..."
connmanctl scan wifi &>/dev/null
sleep 3

# Step 5: List available networks
echo ""
echo "Step 5: Available WiFi Networks:"
echo "==============================================================================="

# Get list of WiFi services
services=$(connmanctl services | grep "^[* ].*wifi_")

if [ -z "$services" ]; then
    print_error "No WiFi networks found"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check if WiFi is enabled: connmanctl technologies"
    echo "  2. Verify antenna is connected (if external)"
    echo "  3. Try moving closer to access point"
    echo "  4. Run diagnostics: sudo adu-wifi-diagnostics.sh"
    exit 1
fi

# Display networks with numbers
declare -a network_ids
declare -a network_names
index=1

while IFS= read -r line; do
    # Extract SSID and service ID
    ssid=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /wifi_/) {for(j=1;j<i;j++) printf "%s ", $j; break}}' | sed 's/ *$//')
    service_id=$(echo "$line" | grep -o 'wifi_[^ ]*')
    
    # Check if already connected
    status=""
    if echo "$line" | grep -q "^\*"; then
        status=" ${GREEN}[CONNECTED]${NC}"
    fi
    
    echo -e "  ${BLUE}[$index]${NC} $ssid$status"
    network_ids[$index]=$service_id
    network_names[$index]=$ssid
    ((index++))
done <<< "$services"

echo "==============================================================================="
echo ""

# Step 6: Select network
while true; do
    read -p "Select network number (1-$((index-1))) or 'q' to quit: " selection
    
    if [ "$selection" = "q" ] || [ "$selection" = "Q" ]; then
        echo "WiFi setup cancelled"
        exit 0
    fi
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -lt "$index" ]; then
        selected_id="${network_ids[$selection]}"
        selected_name="${network_names[$selection]}"
        break
    else
        print_error "Invalid selection. Please enter a number between 1 and $((index-1))"
    fi
done

echo ""
print_info "Selected network: $selected_name"

# Verify the service still exists (it may have disappeared)
echo ""
print_info "Verifying network is still available..."
if ! connmanctl services | grep -q "$selected_id"; then
    print_error "Network '$selected_name' is no longer available"
    echo ""
    echo "This can happen if:"
    echo "  - Network went out of range"
    echo "  - Access point was turned off"
    echo "  - WiFi service restarted"
    echo ""
    echo "Please run this script again to rescan."
    exit 1
fi

# Step 7: Check if network is already connected
if connmanctl services | grep "^\*.*$selected_id"; then
    echo ""
    print_status "Already connected to '$selected_name'"
    
    # Show connection details
    echo ""
    echo "Connection Details:"
    echo "-------------------"
    ip_addr=$(ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print $2}')
    if [ -n "$ip_addr" ]; then
        echo "IP Address: $ip_addr"
        gateway=$(ip route | grep default | awk '{print $3}')
        echo "Gateway: $gateway"
        
        # Test connectivity
        echo ""
        print_info "Testing internet connectivity..."
        if ping -c 2 -W 5 8.8.8.8 &>/dev/null; then
            print_status "Internet connectivity: OK"
        else
            print_warning "Internet connectivity: FAILED"
            echo "  Your WiFi is connected but internet access may not be working"
        fi
    fi
    
    read -p "Do you want to disconnect and reconnect? (y/N): " reconnect
    if [ "$reconnect" != "y" ] && [ "$reconnect" != "Y" ]; then
        echo ""
        print_status "WiFi setup complete!"
        exit 0
    fi
    
    echo ""
    print_info "Disconnecting from '$selected_name'..."
    connmanctl disconnect "$selected_id" &>/dev/null
    sleep 2
fi

# Step 8: Get WiFi passphrase from user
echo ""
echo "Step 8: Enter WiFi Passphrase"
echo ""

# Check if wpa_passphrase is available for hashing
if ! command -v wpa_passphrase >/dev/null 2>&1; then
    print_error "wpa_passphrase utility not found"
    echo "This tool is needed to securely hash the WiFi password"
    echo "Install with: opkg install wpa-supplicant"
    exit 1
fi

# Read password securely (no echo)
read -s -p "Enter passphrase for '$selected_name': " wifi_password
echo ""

if [ -z "$wifi_password" ]; then
    print_error "Password cannot be empty"
    exit 1
fi

# Validate password length (WPA requires 8-63 characters)
if [ ${#wifi_password} -lt 8 ] || [ ${#wifi_password} -gt 63 ]; then
    print_error "WiFi password must be 8-63 characters"
    exit 1
fi

# Step 9: Create ConnMan configuration file with hashed passphrase
echo ""
echo "Step 9: Creating secure configuration..."

# Generate PSK hash using wpa_passphrase (this hashes the password so it's not stored in plaintext)
print_info "Hashing passphrase (this may take a moment)..."
psk_hash=$(wpa_passphrase "$selected_name" "$wifi_password" | grep "^\s*psk=" | grep -v "#psk=" | cut -d= -f2)

if [ -z "$psk_hash" ]; then
    print_error "Failed to generate PSK hash"
    exit 1
fi

# Create ConnMan config directory
mkdir -p /var/lib/connman

# Generate safe config filename from SSID (replace spaces/special chars with underscores)
safe_ssid=$(echo "$selected_name" | sed 's/[^a-zA-Z0-9]/_/g')
config_file="/var/lib/connman/${safe_ssid}.config"

# Create config file with hashed PSK (not plaintext)
print_info "Writing configuration to $config_file..."
cat > "$config_file" <<EOF
[service_${selected_id}]
Type = wifi
Name = ${selected_name}
Security = psk
Passphrase = ${psk_hash}
AutoConnect = true
Favorite = true
EOF

chmod 600 "$config_file"
print_status "Configuration saved (passphrase securely hashed)"

# Step 10: Restart ConnMan to apply configuration
echo ""
echo "Step 10: Restarting ConnMan service..."
print_info "This will briefly disconnect existing connections..."

if ! systemctl restart connman; then
    print_error "Failed to restart ConnMan"
    echo "Try manually: sudo systemctl restart connman"
    exit 1
fi

sleep 3
print_status "ConnMan restarted"

# Wait for ConnMan to initialize
print_info "Waiting for ConnMan to initialize..."
sleep 2

# Wait for ConnMan to initialize
print_info "Waiting for ConnMan to initialize..."
sleep 2

# Step 11: Verify connection
echo ""
echo "Step 11: Verifying connection..."
print_info "ConnMan should automatically connect using the saved configuration..."

# Wait for connection to establish (up to 20 seconds)
max_wait=20
waited=0
connected=false

while [ $waited -lt $max_wait ]; do
    service_line=$(connmanctl services | grep "$selected_id" || true)
    service_state=$(echo "$service_line" | awk '{print $1}')
    
    # Check for success states: *AR (ready) or *AO (online)
    if [[ "$service_state" == *"R"* ]] || [[ "$service_state" == *"O"* ]]; then
        connected=true
        break
    fi
    
    if [ $((waited % 3)) -eq 0 ] && [ $waited -gt 0 ]; then
        echo -n "."
    fi
    
    sleep 1
    waited=$((waited + 1))
done
echo ""

if [ "$connected" = false ]; then
    print_error "Connection timed out after ${max_wait}s"
    echo ""
    echo "Possible issues:"
    echo "  - Incorrect password (PSK hash mismatch)"
    echo "  - Network out of range"
    echo "  - Router rejecting connection"
    echo ""
    echo "Configuration file: $config_file"
    echo "Remove with: sudo rm $config_file"
    echo "Check logs: journalctl -u connman -n 50"
    exit 1
fi

print_status "Successfully connected to '$selected_name'"
    
    # Wait for IP address with polling (up to 15 seconds)
    print_info "Obtaining IP address..."
    max_wait=15
    waited=0
    ip_addr=""
    
    while [ $waited -lt $max_wait ]; do
        ip_addr=$(ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print $2}')
        if [ -n "$ip_addr" ]; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
        if [ $((waited % 3)) -eq 0 ]; then
            echo -n "."
        fi
    done
    echo ""
    
    # Show connection details
    echo ""
    echo "Connection Details:"
    echo "-------------------"
    if [ -n "$ip_addr" ]; then
        echo "IP Address: $ip_addr"
        gateway=$(ip route | grep default | awk '{print $3}')
        echo "Gateway: $gateway"
        echo "Interface: wlan0"
    else
        print_warning "No IP address assigned after ${max_wait}s. DHCP may be taking longer than usual."
        print_warning "Check with: ip addr show wlan0"
        print_warning "Or wait a few more seconds and retry"
    fi
    
    # Test connectivity
    echo ""
    print_info "Testing internet connectivity..."
    if ping -c 3 -W 5 8.8.8.8 &>/dev/null; then
        print_status "Internet connectivity: OK"
        
        # Test DNS resolution
        if ping -c 2 -W 5 www.google.com &>/dev/null; then
            print_status "DNS resolution: OK"
        else
            print_warning "DNS resolution may have issues"
        fi
    else
        print_error "Internet connectivity: FAILED"
        echo ""
        echo "Troubleshooting steps:"
        echo "  1. Verify router has internet access"
        echo "  2. Check if router requires additional authentication (captive portal)"
        echo "  3. Verify firewall settings"
        echo "  4. Try: ping <gateway_ip>"
    fi
    
    echo ""
    echo "==============================================================================="
    print_status "WiFi setup complete!"
    echo "==============================================================================="
    echo ""
    echo "Your device is now connected to: $selected_name"
    echo ""
    echo "Next steps:"
    echo "  1. Configure Azure IoT Hub connection"
    echo "     sudo nano /adu/conf/du-config.json"
    echo ""
    echo "  2. Start ADU agent"
    echo "     sudo systemctl start deviceupdate-agent.service"
    echo ""
    echo "  3. Check status"
    echo "     sudo systemctl status deviceupdate-agent.service"
    echo ""
    echo "For detailed instructions, see: /usr/share/doc/adu/GETTING-STARTED.txt"
    echo ""
    
else
    echo ""
    print_error "Failed to connect to '$selected_name'"
    echo ""
    echo "==============================================================================="
    echo "  TROUBLESHOOTING WIFI CONNECTION FAILURE"
    echo "==============================================================================="
    echo ""
    echo "Common Issues:"
    echo "  ${YELLOW}1. Incorrect Password${NC}"
    echo "     • Double-check WiFi password (case-sensitive)"
    echo "     • Try connecting again with correct password"
    echo ""
    echo "  ${YELLOW}2. Network Out of Range${NC}"
    echo "     • Move device closer to router/access point"
    echo "     • Check signal strength: iwlist wlan0 scan | grep -A 5 \"$selected_name\""
    echo ""
    echo "  ${YELLOW}3. Router MAC Filtering${NC}"
    echo "     • Check your MAC address: ip link show wlan0 | grep ether"
    echo "     • Add device MAC to router's allowed list"
    echo ""
    echo "  ${YELLOW}4. Router Client Limit${NC}"
    echo "     • Disconnect unused devices from router"
    echo "     • Check router's maximum client setting"
    echo ""
    echo "  ${YELLOW}5. WiFi Still Blocked${NC}"
    echo "     • Check: rfkill list wifi"
    echo "     • Unblock: sudo rfkill unblock wifi"
    echo ""
    echo "  ${YELLOW}6. Firmware Not Loaded${NC}"
    echo "     • Check: dmesg | grep -i brcm"
    echo "     • Restart: sudo systemctl restart connman"
    echo ""
    echo "  ${YELLOW}7. Wrong Security Type${NC}"
    echo "     • WPA3-only networks may not be supported"
    echo "     • Try enabling WPA2 compatibility on router"
    echo ""
    echo "==============================================================================="
    echo "  MANUAL CONNECTION STEPS"
    echo "==============================================================================="
    echo ""
    echo "${BLUE}If WiFi is Soft-Blocked:${NC}"
    echo "  1. Check status:     rfkill list wifi"
    echo "  2. Unblock WiFi:     sudo rfkill unblock wifi"
    echo "  3. Verify:           rfkill list wifi  # Should show 'Soft blocked: no'"
    echo ""
    echo "${BLUE}Manual WiFi Connection with connmanctl:${NC}"
    echo "  1. Enable WiFi:      sudo connmanctl enable wifi"
    echo "  2. Scan networks:    sudo connmanctl scan wifi"
    echo "  3. List networks:    connmanctl services"
    echo "  4. Start agent:      sudo connmanctl agent on"
    echo "  5. Connect:"
    echo "     sudo connmanctl connect wifi_<SERVICE_ID>"
    echo "     # Enter password when prompted"
    echo ""
    echo "${BLUE}Alternative - Interactive Mode:${NC}"
    echo "  sudo connmanctl"
    echo "  > agent on"
    echo "  > scan wifi"
    echo "  > services"
    echo "  > connect wifi_<SERVICE_ID>"
    echo "  > quit"
    echo ""
    echo "==============================================================================="
    echo ""
    echo "Diagnostic Commands:"
    echo "  • Full diagnostics:  sudo adu-wifi-diagnostics.sh"
    echo "  • Check WiFi status:  connmanctl technologies"
    echo "  • View kernel logs:   dmesg | grep -i 'wlan\\|wifi\\|brcm'"
    echo "  • Network scan:       sudo iwlist wlan0 scan"
    echo "  • Restart network:    sudo systemctl restart connman"
    echo ""
    echo "Try Again:"
    echo "  • Run this script:    sudo $0"
    echo "  • Manual connection:  See /usr/share/doc/adu/GETTING-STARTED.txt"
    echo ""
    echo "==============================================================================="
    exit 1
fi

exit 0
