#!/bin/bash
# ADU Boot Menu - Interactive boot configuration
# Runs early in boot process to allow user to configure boot behavior

set -e

# Detect color support (gracefully degrades on basic consoles)
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    # Terminal supports colors
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    # Plain text for basic consoles
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

# Config file for this boot session
BOOT_CONFIG="/run/adu-boot-config"

# Default values
DEBUG_MODE=false
BOOT_LOGGING=false
SHOW_CONSOLE=false
VERBOSE_LOGGING=false
SHOW_PARTITION_INFO=false

# Initialize config file
init_config() {
    mkdir -p /run
    cat > "$BOOT_CONFIG" << EOF
# ADU Boot Configuration (this boot session only)
DEBUG_MODE=$DEBUG_MODE
BOOT_LOGGING=$BOOT_LOGGING
SHOW_CONSOLE=$SHOW_CONSOLE
VERBOSE_LOGGING=$VERBOSE_LOGGING
SHOW_PARTITION_INFO=$SHOW_PARTITION_INFO
EOF
}

# Read A/B partition info from u-boot environment
read_partition_info() {
    local boot_partition=""
    local boot_attempts=""
    local boot_result=""
    
    if command -v fw_printenv >/dev/null 2>&1; then
        boot_partition=$(fw_printenv -n boot_partition 2>/dev/null || echo "rootA")
        boot_attempts=$(fw_printenv -n boot_attempts 2>/dev/null || echo "0")
        boot_result=$(fw_printenv -n boot_result 2>/dev/null || echo "unknown")
    else
        boot_partition="rootA"
        boot_attempts="0"
        boot_result="unknown"
    fi
    
    echo "$boot_partition|$boot_attempts|$boot_result"
}

# Display main boot menu
show_main_menu() {
    local partition_info=$(read_partition_info)
    local boot_partition=$(echo "$partition_info" | cut -d'|' -f1)
    local boot_attempts=$(echo "$partition_info" | cut -d'|' -f2)
    local boot_result=$(echo "$partition_info" | cut -d'|' -f3)
    
    # Determine status icon
    local status_icon="✓"
    local status_text="OK"
    if [ "$boot_result" = "failed" ] || [ "$boot_attempts" -gt 0 ]; then
        status_icon="⚠"
        status_text="WARN"
    fi
    
    clear
    echo -e "${BOLD}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│  ${CYAN}Azure Device Update - Boot Menu (5s)${NC}${BOLD}           │${NC}"
    echo -e "${BOLD}├─────────────────────────────────────────────────┤${NC}"
    echo -e "${BOLD}│${NC}  Current: ${GREEN}$boot_partition${NC}  │  Boot attempts: ${YELLOW}$boot_attempts/3${NC}          ${BOLD}│${NC}"
    echo -e "${BOLD}│${NC}  Status: $status_icon ${status_text}    │  Last boot: ${boot_result}          ${BOLD}│${NC}"
    echo -e "${BOLD}├─────────────────────────────────────────────────┤${NC}"
    echo -e "${BOLD}│${NC}  ${BLUE}[d]${NC} Debug Mode      ${BLUE}[p]${NC} Partition Override     ${BOLD}│${NC}"
    echo -e "${BOLD}│${NC}  ${BLUE}[Enter]${NC} Continue boot                          ${BOLD}│${NC}"
    echo -e "${BOLD}└─────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Show partition override menu
show_partition_menu() {
    local partition_info=$(read_partition_info)
    local boot_partition=$(echo "$partition_info" | cut -d'|' -f1)
    local boot_attempts=$(echo "$partition_info" | cut -d'|' -f2)
    
    # Read both partitions' info
    local rootA_attempts="0"
    local rootA_result="unknown"
    local rootA_timestamp=""
    local rootB_attempts="0"
    local rootB_result="unknown"
    local rootB_timestamp=""
    
    if command -v fw_printenv >/dev/null 2>&1; then
        rootA_attempts=$(fw_printenv -n boot_attempts_A 2>/dev/null || echo "0")
        rootA_result=$(fw_printenv -n boot_result_A 2>/dev/null || echo "success")
        rootA_timestamp=$(fw_printenv -n boot_timestamp_A 2>/dev/null || echo "")
        rootB_attempts=$(fw_printenv -n boot_attempts_B 2>/dev/null || echo "0")
        rootB_result=$(fw_printenv -n boot_result_B 2>/dev/null || echo "unknown")
        rootB_timestamp=$(fw_printenv -n boot_timestamp_B 2>/dev/null || echo "")
    fi
    
    clear
    echo -e "${BOLD}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│  ${CYAN}A/B Partition Status${NC}${BOLD}                           │${NC}"
    echo -e "${BOLD}├─────────────────────────────────────────────────┤${NC}"
    
    # Highlight active partition
    if [ "$boot_partition" = "rootA" ]; then
        echo -e "${BOLD}│  ${GREEN}→ rootA (ACTIVE)${NC}${BOLD}                               │${NC}"
    else
        echo -e "${BOLD}│    rootA (STANDBY)                              │${NC}"
    fi
    echo -e "${BOLD}│${NC}     boot_attempts: $rootA_attempts/3                          ${BOLD}│${NC}"
    echo -e "${BOLD}│${NC}     last_boot_result: $rootA_result                      ${BOLD}│${NC}"
    if [ -n "$rootA_timestamp" ]; then
        local rootA_date=$(date -d "@$rootA_timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "invalid")
        echo -e "${BOLD}│${NC}     last_boot: $rootA_date               ${BOLD}│${NC}"
    fi
    echo -e "${BOLD}│${NC}                                                 ${BOLD}│${NC}"
    
    if [ "$boot_partition" = "rootB" ]; then
        echo -e "${BOLD}│  ${GREEN}→ rootB (ACTIVE)${NC}${BOLD}                               │${NC}"
    else
        echo -e "${BOLD}│    rootB (STANDBY)                              │${NC}"
    fi
    echo -e "${BOLD}│${NC}     boot_attempts: $rootB_attempts/3                          ${BOLD}│${NC}"
    echo -e "${BOLD}│${NC}     last_boot_result: $rootB_result                      ${BOLD}│${NC}"
    if [ -n "$rootB_timestamp" ]; then
        local rootB_date=$(date -d "@$rootB_timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "invalid")
        echo -e "${BOLD}│${NC}     last_boot: $rootB_date               ${BOLD}│${NC}"
    fi
    
    echo -e "${BOLD}├─────────────────────────────────────────────────┤${NC}"
    echo -e "${BOLD}│${NC}  ${BLUE}[Enter]${NC} Boot from $boot_partition (default)              ${BOLD}│${NC}"
    
    if [ "$boot_partition" = "rootA" ]; then
        echo -e "${BOLD}│${NC}  ${BLUE}[o]${NC} Override - Boot from rootB                 ${BOLD}│${NC}"
    else
        echo -e "${BOLD}│${NC}  ${BLUE}[o]${NC} Override - Boot from rootA                 ${BOLD}│${NC}"
    fi
    
    echo -e "${BOLD}│${NC}  ${BLUE}[r]${NC} Reset boot attempts to 0                   ${BOLD}│${NC}"
    echo -e "${BOLD}│${NC}  ${BLUE}[b]${NC} Back to main menu                          ${BOLD}│${NC}"
    echo -e "${BOLD}└─────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Show debug mode configuration
show_debug_menu() {
    clear
    echo -e "${BOLD}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│  ${CYAN}ADU Debug Mode${NC}${BOLD}                                 │${NC}"
    echo -e "${BOLD}├─────────────────────────────────────────────────┤${NC}"
    echo -e "${BOLD}│${NC}  ${BLUE}Enable boot diagnostics?${NC}                 ${YELLOW}[Y/n]${NC}   ${BOLD}│${NC}"
    echo -e "${BOLD}│${NC}    → Logs to /boot/adu-diags/                  ${BOLD}│${NC}"
    echo ""
    
    read -t 10 -n 1 -p "  " response || response="y"
    echo ""
    if [[ "$response" =~ ^[Nn]$ ]]; then
        BOOT_LOGGING=false
    else
        BOOT_LOGGING=true
        echo -e "  ${GREEN}✓${NC} Boot diagnostics enabled"
    fi
    
    echo ""
    echo -e "${BOLD}│${NC}  ${BLUE}Show console messages?${NC}                   ${YELLOW}[Y/n]${NC}   ${BOLD}│${NC}"
    echo -e "${BOLD}│${NC}    → Disable Plymouth splash                   ${BOLD}│${NC}"
    echo ""
    
    read -t 10 -n 1 -p "  " response || response="y"
    echo ""
    if [[ "$response" =~ ^[Nn]$ ]]; then
        SHOW_CONSOLE=false
    else
        SHOW_CONSOLE=true
        echo -e "  ${GREEN}✓${NC} Console output enabled"
    fi
    
    echo ""
    echo -e "${BOLD}│${NC}  ${BLUE}Verbose kernel logging?${NC}                  ${YELLOW}[Y/n]${NC}   ${BOLD}│${NC}"
    echo -e "${BOLD}│${NC}    → loglevel=7, systemd.log_level=debug      ${BOLD}│${NC}"
    echo ""
    
    read -t 10 -n 1 -p "  " response || response="y"
    echo ""
    if [[ "$response" =~ ^[Nn]$ ]]; then
        VERBOSE_LOGGING=false
    else
        VERBOSE_LOGGING=true
        echo -e "  ${GREEN}✓${NC} Verbose logging enabled"
    fi
    
    echo ""
    echo -e "${BOLD}│${NC}  ${BLUE}Show A/B partition details?${NC}              ${YELLOW}[Y/n]${NC}   ${BOLD}│${NC}"
    echo -e "${BOLD}│${NC}    → Display u-boot environment               ${BOLD}│${NC}"
    echo ""
    
    read -t 10 -n 1 -p "  " response || response="y"
    echo ""
    if [[ "$response" =~ ^[Nn]$ ]]; then
        SHOW_PARTITION_INFO=false
    else
        SHOW_PARTITION_INFO=true
        echo -e "  ${GREEN}✓${NC} Partition info will be displayed"
    fi
    
    echo ""
    echo -e "${BOLD}└─────────────────────────────────────────────────┘${NC}"
    
    DEBUG_MODE=true
    
    # Show summary
    echo ""
    echo -e "${GREEN}Debug mode configured. Continuing boot...${NC}"
    sleep 2
}

# Handle partition override
handle_partition_override() {
    local current_partition=$(fw_printenv -n boot_partition 2>/dev/null || echo "rootA")
    local target_partition="rootB"
    
    if [ "$current_partition" = "rootB" ]; then
        target_partition="rootA"
    fi
    
    echo ""
    echo -e "${YELLOW}Overriding boot partition to: $target_partition${NC}"
    
    if command -v fw_setenv >/dev/null 2>&1; then
        fw_setenv boot_partition "$target_partition" 2>/dev/null || {
            echo -e "${RED}Failed to set boot partition!${NC}"
            sleep 2
            return 1
        }
        echo -e "${GREEN}✓ Boot partition set to $target_partition${NC}"
        echo -e "${YELLOW}System will now reboot...${NC}"
        sleep 2
        reboot
    else
        echo -e "${RED}fw_setenv not available. Cannot override partition.${NC}"
        sleep 2
        return 1
    fi
}

# Reset boot attempts
reset_boot_attempts() {
    echo ""
    echo -e "${YELLOW}Resetting boot attempts to 0...${NC}"
    
    if command -v fw_setenv >/dev/null 2>&1; then
        fw_setenv boot_attempts 0 2>/dev/null || {
            echo -e "${RED}Failed to reset boot attempts!${NC}"
            sleep 2
            return 1
        }
        echo -e "${GREEN}✓ Boot attempts reset to 0${NC}"
        sleep 2
    else
        echo -e "${RED}fw_setenv not available.${NC}"
        sleep 2
        return 1
    fi
}

# Main menu loop
main_menu_loop() {
    show_main_menu
    
    # Read with timeout
    read -t 5 -n 1 -p "Select option: " choice || choice=""
    echo ""
    
    case "$choice" in
        d|D)
            show_debug_menu
            ;;
        p|P)
            # Partition menu loop
            while true; do
                show_partition_menu
                read -t 10 -n 1 -p "Select option: " pchoice || pchoice=""
                echo ""
                
                case "$pchoice" in
                    o|O)
                        handle_partition_override
                        break
                        ;;
                    r|R)
                        reset_boot_attempts
                        ;;
                    b|B)
                        break
                        ;;
                    *)
                        break
                        ;;
                esac
            done
            ;;
        *)
            # Default: continue boot
            ;;
    esac
}

# Save configuration
save_config() {
    cat > "$BOOT_CONFIG" << EOF
# ADU Boot Configuration (this boot session only)
DEBUG_MODE=$DEBUG_MODE
BOOT_LOGGING=$BOOT_LOGGING
SHOW_CONSOLE=$SHOW_CONSOLE
VERBOSE_LOGGING=$VERBOSE_LOGGING
SHOW_PARTITION_INFO=$SHOW_PARTITION_INFO
EOF
    
    chmod 644 "$BOOT_CONFIG"
}

# Show partition info if requested
show_partition_details() {
    if [ "$SHOW_PARTITION_INFO" = true ] && command -v fw_printenv >/dev/null 2>&1; then
        echo ""
        echo -e "${BOLD}=== U-Boot Environment ===${NC}"
        fw_printenv | grep -E "boot_|upgrade_" || echo "No partition info available"
        echo ""
        sleep 3
    fi
}

# Main execution
main() {
    # Initialize
    init_config
    
    # Show menu
    main_menu_loop
    
    # Save configuration
    save_config
    
    # Show additional info if debug mode
    if [ "$DEBUG_MODE" = true ]; then
        show_partition_details
        echo -e "${CYAN}Debug mode active. Boot diagnostics will be collected.${NC}"
        sleep 1
    fi
    
    echo -e "${GREEN}Continuing boot...${NC}"
}

main
