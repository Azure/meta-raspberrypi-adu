#!/bin/bash
# ADU Error Code Decoder
# Translates hexadecimal error codes into human-readable descriptions

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

show_usage() {
    cat << EOF
${BOLD}ADU Error Code Decoder${NC}

${BOLD}USAGE:${NC}
    $(basename $0) <error_code>
    $(basename $0) --last-boot
    $(basename $0) --help

${BOLD}ARGUMENTS:${NC}
    error_code      Hexadecimal error code (e.g., 0x04020001)
    --last-boot     Decode error from last boot (reads U-Boot env)
    --help          Show this help message

${BOLD}EXAMPLES:${NC}
    $(basename $0) 0x04020001
    $(basename $0) 67633153        (decimal also supported)
    $(basename $0) --last-boot

EOF
}

decode_uboot_error() {
    local error=$1
    case $error in
        1) echo "UBOOT_ENV_READ_FAILED - Cannot read U-Boot environment" ;;
        2) echo "UBOOT_ENV_WRITE_FAILED - Cannot write U-Boot environment" ;;
        3) echo "UBOOT_PARTITION_INVALID - Invalid boot partition specified" ;;
        4) echo "UBOOT_KERNEL_LOAD_FAILED - Failed to load kernel from boot partition" ;;
        5) echo "UBOOT_DTB_LOAD_FAILED - Failed to load device tree" ;;
        6) echo "UBOOT_MAX_ATTEMPTS_EXCEEDED - Boot attempts >= 3, rollback triggered" ;;
        7) echo "UBOOT_SAVEENV_FAILED - Cannot save environment to storage" ;;
        8) echo "UBOOT_BOOTCMD_FAILED - Boot command execution failed" ;;
        *) echo "Unknown U-Boot error code: $error" ;;
    esac
}

decode_kernel_error() {
    local error=$1
    case $error in
        1) echo "KERNEL_PANIC - Kernel panic during init" ;;
        2) echo "KERNEL_ROOTFS_MOUNT_FAILED - Cannot mount root filesystem" ;;
        3) echo "KERNEL_MODULE_LOAD_FAILED - Critical module failed to load" ;;
        4) echo "KERNEL_INIT_NOT_FOUND - Init process not found" ;;
        5) echo "KERNEL_DEVICE_TIMEOUT - Hardware device timeout" ;;
        6) echo "KERNEL_OOM - Out of memory during boot" ;;
        7) echo "KERNEL_CMDLINE_INVALID - Invalid kernel command line" ;;
        *) echo "Unknown Kernel error code: $error" ;;
    esac
}

decode_systemd_error() {
    local error=$1
    case $error in
        1) echo "SYSTEMD_TARGET_FAILED - Boot target failed to reach" ;;
        2) echo "SYSTEMD_MOUNT_FAILED - Critical mount failed" ;;
        3) echo "SYSTEMD_SERVICE_DEPENDENCY_FAILED - Service dependency chain broken" ;;
        4) echo "SYSTEMD_EMERGENCY_MODE - Dropped to emergency mode" ;;
        5) echo "SYSTEMD_TIMEOUT_STARTUP - Startup timeout exceeded" ;;
        6) echo "SYSTEMD_GENERATOR_FAILED - systemd generator failed" ;;
        1001) echo "ADU_MOUNT_FAILED - /adu partition mount failed" ;;
        1002) echo "ADU_MOUNT_READONLY - /adu mounted read-only" ;;
        1003) echo "ADU_MOUNT_WRONG_DEVICE - Wrong device mounted on /adu" ;;
        *) echo "Unknown Systemd error code: $error" ;;
    esac
}

decode_adu_service_error() {
    local error=$1
    local sub_facility=$((error / 10000))
    
    case $sub_facility in
        1) # OOBE errors (0x0401xxxx)
            local oobe_error=$((error % 10000))
            case $oobe_error in
                1) echo "OOBE_DIR_CREATE_FAILED - Cannot create /adu directories" ;;
                2) echo "OOBE_CHOWN_FAILED - Cannot set ownership to adu:adu" ;;
                3) echo "OOBE_TEMPLATE_COPY_FAILED - Cannot copy config templates" ;;
                4) echo "OOBE_SYMLINK_FAILED - Cannot create symlinks" ;;
                5) echo "OOBE_MARKER_FAILED - Cannot create marker file" ;;
                *) echo "Unknown OOBE error code: $oobe_error" ;;
            esac
            ;;
        2) # Boot Health errors (0x0402xxxx)
            local health_error=$((error % 10000))
            case $health_error in
                1) echo "HEALTH_SERVICE_FAILED - Critical service not running" ;;
                2) echo "HEALTH_ROOTFS_READONLY - Root filesystem is read-only" ;;
                3) echo "HEALTH_ADU_NOT_MOUNTED - /adu partition not mounted" ;;
                4) echo "HEALTH_DISK_FULL - /adu partition >90% full" ;;
                5) echo "HEALTH_NETWORK_DOWN - No network interfaces up" ;;
                6) echo "HEALTH_MARKER_EXISTS - Already marked successful (not an error)" ;;
                7) echo "HEALTH_FWENV_ACCESS_FAILED - Cannot access U-Boot environment" ;;
                8) echo "HEALTH_TIMESTAMP_FAILED - Cannot set boot timestamp" ;;
                *) echo "Unknown Boot Health error code: $health_error" ;;
            esac
            ;;
        3) # Swap Setup errors (0x0403xxxx)
            local swap_error=$((error % 10000))
            case $swap_error in
                1) echo "SWAP_FILE_CREATE_FAILED - Cannot create swap file" ;;
                2) echo "SWAP_MKSWAP_FAILED - mkswap command failed" ;;
                3) echo "SWAP_SWAPON_FAILED - Cannot activate swap" ;;
                4) echo "SWAP_SIZE_INSUFFICIENT - Not enough space for swap file" ;;
                *) echo "Unknown Swap Setup error code: $swap_error" ;;
            esac
            ;;
        *) echo "Unknown ADU Service error code: $error" ;;
    esac
}

decode_boot_menu_error() {
    local error=$1
    case $error in
        1) echo "BOOT_MENU_FWENV_UNAVAILABLE - Cannot access U-Boot environment" ;;
        2) echo "BOOT_MENU_TTY_UNAVAILABLE - Cannot open console TTY" ;;
        3) echo "BOOT_MENU_CONFIG_WRITE_FAILED - Cannot write /run/adu-boot-config" ;;
        4) echo "BOOT_MENU_INVALID_PARTITION - Invalid partition selection" ;;
        5) echo "BOOT_MENU_TIMESTAMP_PARSE_FAILED - Cannot parse boot timestamp" ;;
        *) echo "Unknown Boot Menu error code: $error" ;;
    esac
}

decode_health_check_error() {
    local error=$1
    # Health check errors are duplicated from ADU service errors
    # Using same decoder
    decode_adu_service_error $((20000 + error))
}

decode_adu_update_error() {
    local error=$1
    if [ $error -lt 1000 ]; then
        # Update handler errors (0x305000xx)
        case $error in
            1) echo "ADU_UPDATE_DOWNLOAD_FAILED - Update file download failed" ;;
            2) echo "ADU_UPDATE_INSTALL_FAILED - Update installation failed" ;;
            3) echo "ADU_UPDATE_APPLY_FAILED - Update apply failed" ;;
            4) echo "ADU_UPDATE_VERIFY_FAILED - Update verification failed" ;;
            5) echo "ADU_HANDLER_NOT_FOUND - Update handler not found" ;;
            6) echo "ADU_SWUPDATE_FAILED - SWUpdate execution failed" ;;
            7) echo "ADU_PARTITION_WRITE_FAILED - Cannot write to target partition" ;;
            8) echo "ADU_INSUFFICIENT_SPACE - Not enough disk space" ;;
            *) echo "Unknown ADU Update error code: $error" ;;
        esac
    else
        # Agent health check errors (0x30501xxx)
        local agent_error=$((error % 1000))
        case $agent_error in
            1) echo "ADU_AGENT_CONFIG_INVALID - Invalid configuration file" ;;
            2) echo "ADU_AGENT_IOTHUB_CONNECT_FAILED - Cannot connect to IoT Hub" ;;
            3) echo "ADU_AGENT_PERMISSION_DENIED - Permission denied accessing resources" ;;
            4) echo "ADU_AGENT_CERT_INVALID - Certificate validation failed" ;;
            *) echo "Unknown ADU Agent error code: $agent_error" ;;
        esac
    fi
}

decode_error_code() {
    local input=$1
    local error_code
    
    # Convert to decimal if hex
    if [[ $input =~ ^0x[0-9A-Fa-f]+$ ]]; then
        error_code=$((input))
    elif [[ $input =~ ^[0-9]+$ ]]; then
        error_code=$input
    else
        echo -e "${RED}Invalid error code format: $input${NC}"
        return 1
    fi
    
    # Extract facility and error parts
    local facility=$((error_code >> 16))
    local error=$((error_code & 0xFFFF))
    
    # Display header
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}Error Code Analysis${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    printf "%-20s: ${CYAN}0x%08X${NC} (decimal: %d)\n" "Error Code" $error_code $error_code
    printf "%-20s: ${CYAN}0x%04X${NC} (decimal: %d)\n" "Facility Code" $facility $facility
    printf "%-20s: ${CYAN}0x%04X${NC} (decimal: %d)\n" "Error Number" $error $error
    echo ""
    
    # Decode facility
    local facility_name
    local description
    local recovery_hint
    
    case $facility in
        0x0100)
            facility_name="${YELLOW}U-Boot Bootloader${NC}"
            description=$(decode_uboot_error $error)
            recovery_hint="Check U-Boot console output, verify /etc/fw_env.config"
            ;;
        0x0200)
            facility_name="${YELLOW}Kernel Initialization${NC}"
            description=$(decode_kernel_error $error)
            recovery_hint="Check kernel logs: dmesg or /boot/adu-diagnostics/rpi-boot-dmesg.log"
            ;;
        0x0300)
            facility_name="${YELLOW}Systemd Init${NC}"
            description=$(decode_systemd_error $error)
            recovery_hint="Check systemd status: systemctl status, journalctl -xb"
            ;;
        0x0400)
            facility_name="${YELLOW}ADU Services${NC}"
            description=$(decode_adu_service_error $error)
            recovery_hint="Check service logs: journalctl -u <service-name>"
            ;;
        0x0500)
            facility_name="${YELLOW}Boot Menu${NC}"
            description=$(decode_boot_menu_error $error)
            recovery_hint="Check boot menu service: systemctl status adu-boot-menu.service"
            ;;
        0x0600)
            facility_name="${YELLOW}Health Checks${NC}"
            description=$(decode_health_check_error $error)
            recovery_hint="Check health logs: journalctl -u adu-boot-health.service"
            ;;
        0x3050)
            facility_name="${YELLOW}ADU Update Process${NC}"
            description=$(decode_adu_update_error $error)
            recovery_hint="Check ADU logs: journalctl -u deviceupdate-agent.service"
            ;;
        *)
            facility_name="${RED}Unknown Facility${NC}"
            description="Unrecognized facility code"
            recovery_hint="Check documentation for custom error codes"
            ;;
    esac
    
    # Display results
    printf "%-20s: %b\n" "Facility" "$facility_name"
    echo -e "${BOLD}Description:${NC}"
    echo -e "  ${description}"
    echo ""
    echo -e "${BOLD}Recovery Suggestion:${NC}"
    echo -e "  ${GREEN}→${NC} ${recovery_hint}"
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
}

decode_last_boot_error() {
    if ! command -v fw_printenv >/dev/null 2>&1; then
        echo -e "${RED}Error: fw_printenv not found. Install u-boot-fw-utils.${NC}"
        return 1
    fi
    
    local boot_result=$(fw_printenv -n boot_result 2>/dev/null)
    local boot_error_code=$(fw_printenv -n boot_error_code 2>/dev/null)
    local boot_partition=$(fw_printenv -n boot_partition 2>/dev/null || echo "unknown")
    local boot_attempts=$(fw_printenv -n boot_attempts 2>/dev/null || echo "unknown")
    
    echo -e "${BOLD}Last Boot Status${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    printf "%-20s: %s\n" "Boot Result" "${boot_result:-unknown}"
    printf "%-20s: %s\n" "Boot Partition" "$boot_partition"
    printf "%-20s: %s\n" "Boot Attempts" "$boot_attempts"
    echo ""
    
    if [ -n "$boot_error_code" ] && [ "$boot_error_code" != "0" ]; then
        decode_error_code "$boot_error_code"
    else
        if [ "$boot_result" = "success" ]; then
            echo -e "${GREEN}✓ No errors detected - last boot was successful${NC}"
        else
            echo -e "${YELLOW}⚠ Boot result indicates failure but no error code set${NC}"
        fi
        echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    fi
}

# Main script logic
if [ $# -eq 0 ]; then
    show_usage
    exit 1
fi

case "$1" in
    --help|-h)
        show_usage
        exit 0
        ;;
    --last-boot|-l)
        decode_last_boot_error
        exit 0
        ;;
    *)
        decode_error_code "$1"
        exit 0
        ;;
esac
