#!/bin/bash
# Mock helpers for BATS tests
# Provides fake fw_printenv/fw_setenv that read/write a temp file

MOCK_UBOOT_ENV=""

# Initialize mock environment
setup_mock_uboot_env() {
    MOCK_UBOOT_ENV=$(mktemp)
    export MOCK_UBOOT_ENV
    
    # Set initial defaults
    mock_set_env "boot_partition" "rootA"
    mock_set_env "boot_attempts" "0"
    mock_set_env "boot_result" "unknown"
    mock_set_env "upgrade_available" "0"
    mock_set_env "max_boot_attempts" "5"
    mock_set_env "last_known_good_partition" "rootA"
    mock_set_env "rescue_required" "0"
    mock_set_env "rollback_occurred" "0"
    mock_set_env "rollback_failed_partition" ""
    mock_set_env "boot_attempts_A" "0"
    mock_set_env "boot_attempts_B" "0"
    mock_set_env "boot_result_A" "unknown"
    mock_set_env "boot_result_B" "unknown"
    mock_set_env "manual_boot_override" "0"
}

teardown_mock_uboot_env() {
    [[ -n "$MOCK_UBOOT_ENV" ]] && rm -f "$MOCK_UBOOT_ENV"
}

# Set a mock U-Boot env variable
mock_set_env() {
    local var="$1"
    local value="$2"
    
    if grep -q "^${var}=" "$MOCK_UBOOT_ENV" 2>/dev/null; then
        sed -i "s|^${var}=.*|${var}=${value}|" "$MOCK_UBOOT_ENV"
    else
        echo "${var}=${value}" >> "$MOCK_UBOOT_ENV"
    fi
}

# Get a mock U-Boot env variable
mock_get_env() {
    local var="$1"
    grep "^${var}=" "$MOCK_UBOOT_ENV" 2>/dev/null | cut -d= -f2-
}

# Mock fw_printenv (used by scripts under test)
fw_printenv() {
    if [[ "$1" == "-n" ]]; then
        local var="$2"
        local val
        val=$(mock_get_env "$var")
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        else
            return 1
        fi
    else
        local var="$1"
        local val
        val=$(mock_get_env "$var")
        if [[ -n "$val" ]]; then
            echo "${var}=${val}"
            return 0
        else
            return 1
        fi
    fi
}

# Mock fw_setenv (used by scripts under test)
fw_setenv() {
    local var="$1"
    local value="$2"
    mock_set_env "$var" "$value"
    return 0
}

# Export mocks so subshells see them
export -f fw_printenv
export -f fw_setenv
export -f mock_set_env
export -f mock_get_env

# Mock systemctl
mock_active_services=()

mock_add_active_service() {
    mock_active_services+=("$1")
}

systemctl() {
    if [[ "$1" == "is-active" && "$2" == "--quiet" ]]; then
        local svc="$3"
        for s in "${mock_active_services[@]}"; do
            if [[ "$s" == "$svc" ]]; then
                return 0
            fi
        done
        return 1
    elif [[ "$1" == "is-enabled" && "$2" == "--quiet" ]]; then
        return 0  # Always enabled in tests
    elif [[ "$1" == "restart" ]]; then
        return 0
    fi
    return 1
}
export -f systemctl

# Mock logger
logger() {
    # Silently consume log messages in tests
    :
}
export -f logger

# Mock reboot (never actually reboot in tests!)
reboot() {
    echo "MOCK_REBOOT_CALLED"
    return 0
}
export -f reboot

# Mock /proc/cmdline
MOCK_PROC_CMDLINE=""

setup_mock_cmdline() {
    MOCK_PROC_CMDLINE=$(mktemp)
    echo "console=serial0,115200 root=/dev/mmcblk0p2 rootfstype=ext4" > "$MOCK_PROC_CMDLINE"
    export MOCK_PROC_CMDLINE
}

teardown_mock_cmdline() {
    [[ -n "$MOCK_PROC_CMDLINE" ]] && rm -f "$MOCK_PROC_CMDLINE"
}

# Helper to set which partition /proc/cmdline reports
set_cmdline_partition() {
    local partition="$1"
    if [[ "$partition" == "rootA" ]]; then
        echo "console=serial0,115200 root=/dev/mmcblk0p2 rootfstype=ext4" > "$MOCK_PROC_CMDLINE"
    elif [[ "$partition" == "rootB" ]]; then
        echo "console=serial0,115200 root=/dev/mmcblk0p3 rootfstype=ext4" > "$MOCK_PROC_CMDLINE"
    fi
}
export -f set_cmdline_partition
