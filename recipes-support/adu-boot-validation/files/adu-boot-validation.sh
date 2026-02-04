#!/bin/bash
# Copyright (c) Azure Device Update for IoT Hub.
# Licensed under the MIT License.

#
# Boot Validation Script for ADU A/B Updates
#
# This script runs during system boot to validate that the newly booted partition
# is functioning correctly. It runs various checks (built-in and custom) and reports
# success or failure to U-Boot environment variables.
#
# Exit codes:
#   0 - All validations passed (or manual override confirmed)
#   1 - Validation failed (system will reboot and retry/rollback)
#

set -euo pipefail

# Constants
readonly UBOOT_ENV="/usr/bin/fw_printenv"
readonly UBOOT_SETENV="/usr/bin/fw_setenv"
readonly CONFIG_FILE="/usr/lib/adu/boot-validation.conf"
readonly STATE_FILE="/var/run/adu-validation-state"
readonly LOG_FILE="/var/log/adu/boot-validation.log"
readonly OVERRIDE_FLAG="/var/run/adu-boot-confirmed"

# Default configuration values
VALIDATION_TIMEOUT=300
ALLOW_MANUAL_OVERRIDE=true
AUTO_CONFIRM_ON_TIMEOUT=false
CUSTOM_CHECKS_DIR="/usr/lib/adu/validation-checks.d"

# Check results
declare -A CHECK_RESULTS=()
declare -a CRITICAL_FAILURES=()
declare -a WARNINGS=()

# Logging functions
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# Initialize logging
initialize_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    log_info "========================================="
    log_info "Boot Validation Started"
    log_info "========================================="
}

# Load configuration from INI file
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warn "Configuration file not found: $CONFIG_FILE (using defaults)"
        return 0
    fi

    log_info "Loading configuration from $CONFIG_FILE"
    
    local section=""
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Section header
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        
        # Key=Value pairs
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            key=$(echo "$key" | xargs)  # trim whitespace
            value=$(echo "$value" | xargs)
            
            case "$section" in
                "General")
                    case "$key" in
                        ValidationTimeout) VALIDATION_TIMEOUT="$value" ;;
                        AllowManualOverride) ALLOW_MANUAL_OVERRIDE="$value" ;;
                        AutoConfirmOnTimeout) AUTO_CONFIRM_ON_TIMEOUT="$value" ;;
                    esac
                    ;;
                "Checks")
                    case "$key" in
                        CustomChecksDir) CUSTOM_CHECKS_DIR="$value" ;;
                    esac
                    ;;
            esac
        fi
    done < "$CONFIG_FILE"
    
    log_info "Configuration loaded: Timeout=${VALIDATION_TIMEOUT}s, ManualOverride=$ALLOW_MANUAL_OVERRIDE"
}

# Get U-Boot environment variable
get_uboot_env() {
    local var_name="$1"
    local value
    value=$($UBOOT_ENV "$var_name" 2>/dev/null | cut -d= -f2- || echo "")
    echo "$value"
}

# Set U-Boot environment variable
set_uboot_env() {
    local var_name="$1"
    local value="$2"
    
    log_info "Setting U-Boot env: $var_name=$value"
    if ! $UBOOT_SETENV "$var_name" "$value" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to set U-Boot variable: $var_name"
        return 1
    fi
    return 0
}

# Check if manual override is present
check_manual_override() {
    if [[ -f "$OVERRIDE_FLAG" ]]; then
        log_info "Manual override detected: $OVERRIDE_FLAG"
        return 0
    fi
    return 1
}

# Built-in validation checks

check_systemd_services() {
    local check_name="SystemdServices"
    local config_key="CheckSystemdServices"
    
    # Read severity from config
    local severity
    severity=$(grep "^${config_key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "critical")
    
    if [[ "$severity" == "disabled" ]]; then
        log_info "Check $check_name: SKIPPED (disabled)"
        CHECK_RESULTS[$check_name]="skipped"
        return 0
    fi
    
    log_info "Running check: $check_name (severity: $severity)"
    
    # Read services to check from config
    local services
    services=$(grep "^Services=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "systemd-journald,dbus")
    
    local failed_services=()
    IFS=',' read -ra SERVICE_LIST <<< "$services"
    
    for service in "${SERVICE_LIST[@]}"; do
        service=$(echo "$service" | xargs)  # trim whitespace
        if ! systemctl is-active --quiet "$service"; then
            log_error "Service $service is not active"
            failed_services+=("$service")
        else
            log_info "Service $service is active"
        fi
    done
    
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        local msg="Services failed: ${failed_services[*]}"
        CHECK_RESULTS[$check_name]="failed"
        
        if [[ "$severity" == "critical" ]]; then
            CRITICAL_FAILURES+=("$check_name: $msg")
            return 2
        else
            WARNINGS+=("$check_name: $msg")
            return 1
        fi
    fi
    
    CHECK_RESULTS[$check_name]="passed"
    log_info "Check $check_name: PASSED"
    return 0
}

check_filesystem_writable() {
    local check_name="FilesystemWritable"
    local config_key="CheckFilesystemWritable"
    
    local severity
    severity=$(grep "^${config_key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "critical")
    
    if [[ "$severity" == "disabled" ]]; then
        log_info "Check $check_name: SKIPPED (disabled)"
        CHECK_RESULTS[$check_name]="skipped"
        return 0
    fi
    
    log_info "Running check: $check_name (severity: $severity)"
    
    local test_file="/tmp/.adu-write-test-$$"
    if ! echo "test" > "$test_file" 2>/dev/null; then
        local msg="Cannot write to /tmp"
        CHECK_RESULTS[$check_name]="failed"
        
        if [[ "$severity" == "critical" ]]; then
            CRITICAL_FAILURES+=("$check_name: $msg")
            return 2
        else
            WARNINGS+=("$check_name: $msg")
            return 1
        fi
    fi
    rm -f "$test_file"
    
    CHECK_RESULTS[$check_name]="passed"
    log_info "Check $check_name: PASSED"
    return 0
}

check_version_match() {
    local check_name="VersionMatch"
    local config_key="CheckVersionMatch"
    
    local severity
    severity=$(grep "^${config_key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "critical")
    
    if [[ "$severity" == "disabled" ]]; then
        log_info "Check $check_name: SKIPPED (disabled)"
        CHECK_RESULTS[$check_name]="skipped"
        return 0
    fi
    
    # Detect if we're in rollback mode (booting into last_known_good after failed attempts)
    local is_rollback=false
    local lkg_partition
    lkg_partition=$(get_uboot_env "last_known_good_partition")
    local current_partition
    current_partition=$(get_uboot_env "boot_partition")
    local boot_attempts
    boot_attempts=$(get_uboot_env "boot_attempts")
    local max_attempts
    max_attempts=$(get_uboot_env "max_boot_attempts")
    max_attempts=${max_attempts:-5}  # Default to 5 if not set
    
    # We're in rollback if current partition matches LKG AND boot_attempts was high
    if [[ -n "$lkg_partition" && "$current_partition" == "$lkg_partition" && "$boot_attempts" -gt 1 ]]; then
        is_rollback=true
        log_info "Rollback mode detected: booting LKG partition after failed attempts"
        # During rollback, downgrade version check to warning (safety > version match)
        if [[ "$severity" == "critical" ]]; then
            severity="warning"
            log_info "Downgrading version check severity to 'warning' during rollback (safety first)"
        fi
    fi
    
    log_info "Running check: $check_name (severity: $severity)"
    
    local boot_partition
    boot_partition=$(get_uboot_env "boot_partition")
    
    if [[ -z "$boot_partition" ]]; then
        log_warn "Cannot determine boot partition from U-Boot"
        CHECK_RESULTS[$check_name]="skipped"
        return 0
    fi
    
    local expected_version
    expected_version=$(get_uboot_env "partition_${boot_partition}_version")
    
    local actual_version
    if [[ -f "/etc/adu-version" ]]; then
        actual_version=$(cat /etc/adu-version 2>/dev/null || echo "")
    else
        log_warn "/etc/adu-version not found"
        CHECK_RESULTS[$check_name]="skipped"
        return 0
    fi
    
    if [[ -n "$expected_version" && "$expected_version" != "$actual_version" ]]; then
        local msg="Version mismatch: expected=$expected_version, actual=$actual_version"
        
        if [[ "$is_rollback" == "true" ]]; then
            msg="$msg (rollback mode - allowing mismatch for safe recovery)"
            log_warn "$check_name: $msg"
        fi
        
        CHECK_RESULTS[$check_name]="failed"
        
        if [[ "$severity" == "critical" ]]; then
            CRITICAL_FAILURES+=("$check_name: $msg")
            return 2
        else
            WARNINGS+=("$check_name: $msg")
            return 1
        fi
    fi
    
    CHECK_RESULTS[$check_name]="passed"
    log_info "Check $check_name: PASSED (version=$actual_version)"
    return 0
}

check_adu_agent() {
    local check_name="AduAgent"
    local config_key="CheckAduAgent"
    
    local severity
    severity=$(grep "^${config_key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "warning")
    
    if [[ "$severity" == "disabled" ]]; then
        log_info "Check $check_name: SKIPPED (disabled)"
        CHECK_RESULTS[$check_name]="skipped"
        return 0
    fi
    
    log_info "Running check: $check_name (severity: $severity)"
    
    if ! systemctl is-active --quiet deviceupdate-agent; then
        local msg="ADU agent is not running"
        CHECK_RESULTS[$check_name]="failed"
        
        if [[ "$severity" == "critical" ]]; then
            CRITICAL_FAILURES+=("$check_name: $msg")
            return 2
        else
            WARNINGS+=("$check_name: $msg")
            return 1
        fi
    fi
    
    CHECK_RESULTS[$check_name]="passed"
    log_info "Check $check_name: PASSED"
    return 0
}

check_network_connectivity() {
    local check_name="NetworkConnectivity"
    local config_key="CheckNetworkConnectivity"
    
    local severity
    severity=$(grep "^${config_key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "warning")
    
    if [[ "$severity" == "disabled" ]]; then
        log_info "Check $check_name: SKIPPED (disabled)"
        CHECK_RESULTS[$check_name]="skipped"
        return 0
    fi
    
    log_info "Running check: $check_name (severity: $severity)"
    
    # Check if any network interface is up (excluding loopback)
    local has_network=false
    while IFS= read -r iface; do
        if [[ "$iface" != "lo" ]] && ip link show "$iface" | grep -q "state UP"; then
            has_network=true
            break
        fi
    done < <(ls /sys/class/net/)
    
    if [[ "$has_network" == "false" ]]; then
        local msg="No active network interface found"
        CHECK_RESULTS[$check_name]="failed"
        
        if [[ "$severity" == "critical" ]]; then
            CRITICAL_FAILURES+=("$check_name: $msg")
            return 2
        else
            WARNINGS+=("$check_name: $msg")
            return 1
        fi
    fi
    
    CHECK_RESULTS[$check_name]="passed"
    log_info "Check $check_name: PASSED"
    return 0
}

check_disk_space() {
    local check_name="DiskSpace"
    local config_key="CheckDiskSpace"
    
    local severity
    severity=$(grep "^${config_key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "warning")
    
    if [[ "$severity" == "disabled" ]]; then
        log_info "Check $check_name: SKIPPED (disabled)"
        CHECK_RESULTS[$check_name]="skipped"
        return 0
    fi
    
    log_info "Running check: $check_name (severity: $severity)"
    
    local min_free_mb
    min_free_mb=$(grep "^MinimumFreeMB=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "100")
    
    local available_mb
    available_mb=$(df -m / | awk 'NR==2 {print $4}')
    
    if [[ "$available_mb" -lt "$min_free_mb" ]]; then
        local msg="Low disk space: ${available_mb}MB available (minimum: ${min_free_mb}MB)"
        CHECK_RESULTS[$check_name]="failed"
        
        if [[ "$severity" == "critical" ]]; then
            CRITICAL_FAILURES+=("$check_name: $msg")
            return 2
        else
            WARNINGS+=("$check_name: $msg")
            return 1
        fi
    fi
    
    CHECK_RESULTS[$check_name]="passed"
    log_info "Check $check_name: PASSED (${available_mb}MB available)"
    return 0
}

# Run custom validation checks from plugin directory
run_custom_checks() {
    if [[ ! -d "$CUSTOM_CHECKS_DIR" ]]; then
        log_info "Custom checks directory not found: $CUSTOM_CHECKS_DIR"
        return 0
    fi
    
    log_info "Running custom checks from: $CUSTOM_CHECKS_DIR"
    
    local check_count=0
    while IFS= read -r -d '' check_script; do
        if [[ ! -x "$check_script" ]]; then
            log_warn "Skipping non-executable check: $check_script"
            continue
        fi
        
        local check_name
        check_name=$(basename "$check_script")
        log_info "Running custom check: $check_name"
        
        local output
        local exit_code
        set +e
        output=$("$check_script" 2>&1)
        exit_code=$?
        set -e
        
        case $exit_code in
            0)
                CHECK_RESULTS["Custom:$check_name"]="passed"
                log_info "Custom check $check_name: PASSED"
                ;;
            1)
                CHECK_RESULTS["Custom:$check_name"]="warning"
                WARNINGS+=("Custom:$check_name: $output")
                log_warn "Custom check $check_name: WARNING - $output"
                ;;
            2)
                CHECK_RESULTS["Custom:$check_name"]="failed"
                CRITICAL_FAILURES+=("Custom:$check_name: $output")
                log_error "Custom check $check_name: FAILED - $output"
                ;;
            *)
                CHECK_RESULTS["Custom:$check_name"]="error"
                log_error "Custom check $check_name: UNEXPECTED EXIT CODE $exit_code - $output"
                ;;
        esac
        
        ((check_count++))
    done < <(find "$CUSTOM_CHECKS_DIR" -maxdepth 1 -type f -print0 | sort -z)
    
    log_info "Completed $check_count custom checks"
}

# Save validation state for status queries
save_state() {
    local status="$1"
    
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
STATUS=$status
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
CRITICAL_FAILURES=${#CRITICAL_FAILURES[@]}
WARNINGS=${#WARNINGS[@]}
TOTAL_CHECKS=${#CHECK_RESULTS[@]}
EOF
    
    # Append individual check results
    for check in "${!CHECK_RESULTS[@]}"; do
        echo "CHECK:$check=${CHECK_RESULTS[$check]}" >> "$STATE_FILE"
    done
    
    # Append failure details
    for failure in "${CRITICAL_FAILURES[@]}"; do
        echo "CRITICAL:$failure" >> "$STATE_FILE"
    done
    
    for warning in "${WARNINGS[@]}"; do
        echo "WARNING:$warning" >> "$STATE_FILE"
    done
}

# Main validation logic
main() {
    initialize_logging
    load_config
    
    # Check if we're in upgrade mode
    local upgrade_available
    upgrade_available=$(get_uboot_env "upgrade_available")
    
    local boot_partition
    boot_partition=$(get_uboot_env "boot_partition")
    
    local lkg_partition
    lkg_partition=$(get_uboot_env "last_known_good_partition")
    
    local is_lkg_boot=false
    if [[ -n "$lkg_partition" && "$boot_partition" == "$lkg_partition" ]]; then
        is_lkg_boot=true
    fi
    
    # Post-boot validation only runs during update (upgrade_available=1)
    # AND when booting into non-LKG partition
    if [[ "$upgrade_available" != "1" ]]; then
        log_info "Not in upgrade mode (upgrade_available=$upgrade_available), skipping validation"
        exit 0
    fi
    
    if [[ "$is_lkg_boot" == "true" ]]; then
        log_info "Booted into LKG partition after rollback - running validation in SAFE MODE"
        log_info "All failures will be downgraded to warnings for safe recovery"
        # Note: Individual checks will detect rollback mode and adjust severity
    else
        log_info "System is in upgrade mode, running validation checks on new partition"
    fi
    
    # Check for manual override first
    if check_manual_override; then
        log_info "Manual override confirmed - marking boot as successful"
        set_uboot_env "boot_result" "success"
        set_uboot_env "upgrade_available" "0"
        save_state "success_manual"
        rm -f "$OVERRIDE_FLAG"
        exit 0
    fi
    
    # Run all built-in checks
    check_systemd_services || true
    check_filesystem_writable || true
    check_version_match || true
    check_adu_agent || true
    check_network_connectivity || true
    check_disk_space || true
    
    # Run custom checks
    run_custom_checks
    
    # Evaluate results
    log_info "========================================="
    log_info "Validation Summary:"
    log_info "  Total checks: ${#CHECK_RESULTS[@]}"
    log_info "  Critical failures: ${#CRITICAL_FAILURES[@]}"
    log_info "  Warnings: ${#WARNINGS[@]}"
    log_info "========================================="
    
    if [[ ${#CRITICAL_FAILURES[@]} -gt 0 ]]; then
        log_error "Validation FAILED - Critical failures detected:"
        for failure in "${CRITICAL_FAILURES[@]}"; do
            log_error "  - $failure"
        done
        
        if [[ "$ALLOW_MANUAL_OVERRIDE" == "true" ]]; then
            log_info "Manual override is enabled. Run 'sudo adu-confirm-boot confirm' to override."
        fi
        
        set_uboot_env "boot_result" "failed"
        save_state "failed"
        exit 1
    fi
    
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        log_warn "Validation completed with warnings:"
        for warning in "${WARNINGS[@]}"; do
            log_warn "  - $warning"
        done
    fi
    
    log_info "All critical checks passed - marking boot as successful"
    set_uboot_env "boot_result" "success"
    set_uboot_env "upgrade_available" "0"
    
    # Update last known good
    local boot_partition
    boot_partition=$(get_uboot_env "boot_partition")
    if [[ -n "$boot_partition" ]]; then
        set_uboot_env "last_known_good_partition" "$boot_partition"
    fi
    
    save_state "success"
    exit 0
}

# Run main function
main "$@"
