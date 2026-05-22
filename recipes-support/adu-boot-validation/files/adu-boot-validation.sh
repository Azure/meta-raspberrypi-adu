#!/bin/bash
################################################################################
# ADU Boot Validation Service - Unified Boot Validation for A/B Updates
################################################################################
#
# PURPOSE:
#   This service provides comprehensive boot validation for A/B partition updates.
#   It runs early in the boot sequence (BEFORE deviceupdate-agent.service) and
#   performs two phases of validation:
#
# PHASE 1: ROLLBACK DETECTION (Critical - runs first)
#   - Detects if U-Boot auto-rolled back from a failed update
#   - Detects partition flapping (rapid switching indicating instability)
#   - Blacklists failed workflow_ids to prevent infinite retry loops
#
# PHASE 2: HEALTH VALIDATION (Runs if no rollback detected)
#   - Runs configurable health checks (services, filesystem, network, etc.)
#   - Supports custom validation scripts via plugins
#   - Allows manual override for edge cases
#
# UPDATE WORKFLOW INTEGRATION:
#
#   Normal Update Flow:
#     1. ADU Agent downloads/installs update to inactive partition (rootB)
#     2. yocto-a-b-update.sh sets: upgrade_available=1, boot_attempts=0, boot_partition=rootB
#     3. System reboots
#     4. → THIS SERVICE RUNS ← (Phase 1: rollback check, Phase 2: health checks)
#     5. If all pass: Sets boot_result=success, upgrade_available=0
#     6. ADU agent reports success to IoT Hub
#
#   Failed Update Flow:
#     1. ADU Agent installs broken update to rootB
#     2. System reboots, new rootB fails to boot properly
#     3. U-Boot increments boot_attempts (1, 2, 3, 4, 5)
#     4. After 5 failed attempts, U-Boot auto-rollback to rootA
#     5. → THIS SERVICE RUNS ← DETECTS ROLLBACK (expected rootB, got rootA)
#     6. → Adds workflow_id to blacklist file
#     7. Next time ADU tries same update: REJECTED (infinite loop prevented!)
#
# KEY FILES:
#   - Blacklist: /var/lib/adu/states/failed_workflows.txt
#   - State: /var/lib/adu/states/swupdate_state.json
#   - Boot History: /var/lib/adu/states/boot_history.log
#   - Config: /usr/lib/adu/boot-validation.conf
#   - Validation Log: /var/log/adu/boot-validation.log
#   - Manual Override: /var/run/adu-boot-confirmed
#
# SYSTEMD DEPENDENCIES:
#   - Runs BEFORE: deviceupdate-agent.service
#   - Runs AFTER: local-fs.target network.target
#
# ERROR HANDLING:
#   - Phase 1 failures are NON-FATAL (system will boot even if validation fails)
#   - Phase 2 critical failures can trigger reboot for retry (configurable)
#
################################################################################

# Strict mode for Phase 2, but Phase 1 uses error handling
set -u  # Exit on undefined variables

# ============================================================================
# Configuration
# ============================================================================

# Phase 1: Rollback Detection Configuration
STATE_DIR="/var/lib/adu/states"
STATE_FILE="${STATE_DIR}/swupdate_state.json"
BLACKLIST_FILE="${STATE_DIR}/failed_workflows.txt"
ROLLBACK_EVENT_FILE="${STATE_DIR}/rollback_event.json"
BOOT_HISTORY_FILE="${STATE_DIR}/boot_history.log"
LOCK_FILE="/var/lock/adu-state.lock"
MAX_BLACKLIST_ENTRIES=10
MAX_PARTITION_SWITCHES=3
FLAPPING_WINDOW_SECONDS=600

# Phase 2: Health Validation Configuration
readonly UBOOT_ENV="/usr/bin/fw_printenv"
readonly UBOOT_SETENV="/usr/bin/fw_setenv"
readonly CONFIG_FILE="/usr/lib/adu/boot-validation.conf"
readonly VALIDATION_STATE_FILE="/var/run/adu-validation-state"
readonly LOG_FILE="/var/log/adu/boot-validation.log"
readonly OVERRIDE_FLAG="/var/run/adu-boot-confirmed"

# Default configuration values (can be overridden by config file)
VALIDATION_TIMEOUT=300
ALLOW_MANUAL_OVERRIDE=true
AUTO_CONFIRM_ON_TIMEOUT=false
CUSTOM_CHECKS_DIR="/usr/lib/adu/validation-checks.d"

# Check results for Phase 2
declare -A CHECK_RESULTS=()
declare -a CRITICAL_FAILURES=()
declare -a WARNINGS=()

# Track which phase we're in
CURRENT_PHASE="init"
ROLLBACK_DETECTED=false

# ============================================================================
# Logging Functions
# ============================================================================

log_phase1() {
    echo "[adu-boot-validation:phase1] $*" | systemd-cat -t adu-boot-validation -p info
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PHASE1] [INFO] $*" >> "$LOG_FILE" 2>/dev/null || true
}

error_phase1() {
    echo "[adu-boot-validation:phase1] ERROR: $*" | systemd-cat -t adu-boot-validation -p err
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PHASE1] [ERROR] $*" >> "$LOG_FILE" 2>/dev/null || true
}

log_info() {
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [PHASE2] [INFO] $msg" | tee -a "$LOG_FILE"
}

log_warn() {
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [PHASE2] [WARN] $msg" | tee -a "$LOG_FILE"
}

log_error() {
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [PHASE2] [ERROR] $msg" | tee -a "$LOG_FILE"
}

# Initialize logging
initialize_logging() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "" >> "$LOG_FILE" 2>/dev/null || true
    log_info "========================================="
    log_info "ADU Boot Validation Service Started"
    log_info "========================================="
}

# ============================================================================
# Phase 1: Rollback Detection Functions
# ============================================================================

# Ensure directories exist with proper ownership
ensure_directories() {
    if [ ! -d "$STATE_DIR" ]; then
        mkdir -p "$STATE_DIR" || log_phase1 "Warning: Failed to create $STATE_DIR"
        
        # Get adu user UID/GID dynamically (should be 800:800)
        ADU_UID=$(id -u adu 2>/dev/null || echo "800")
        ADU_GID=$(id -g adu 2>/dev/null || echo "800")
        
        chown "${ADU_UID}:${ADU_GID}" "$STATE_DIR" 2>/dev/null || true
        chmod 770 "$STATE_DIR" 2>/dev/null || true
        log_phase1 "Created $STATE_DIR with ownership ${ADU_UID}:${ADU_GID}"
    fi
    
    if [ ! -d /var/lock ]; then
        mkdir -p /var/lock || log_phase1 "Warning: Failed to create /var/lock"
    fi
}

# Get current partition from kernel command line
get_current_partition() {
    if grep -q "root=/dev/mmcblk0p2" /proc/cmdline; then
        echo "rootA"
    elif grep -q "root=/dev/mmcblk0p3" /proc/cmdline; then
        echo "rootB"
    else
        error_phase1 "Unknown root partition in /proc/cmdline"
        echo "unknown"
    fi
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

# Write data atomically with sync
write_atomic() {
    local file="$1"
    local content="$2"
    
    if ! echo "$content" > "${file}.tmp" 2>/dev/null; then
        error_phase1 "Failed to write to ${file}.tmp"
        return 1
    fi
    
    sync "${file}.tmp" 2>/dev/null
    
    if ! mv "${file}.tmp" "$file" 2>/dev/null; then
        error_phase1 "Failed to move ${file}.tmp to $file"
        rm -f "${file}.tmp" 2>/dev/null
        return 1
    fi
    
    sync "$file" 2>/dev/null
    return 0
}

# Detect partition flapping (rapid switching between partitions)
detect_partition_flapping() {
    local current_partition="$1"
    local current_time=$(date +%s)
    
    # Append current boot to history
    echo "${current_time}:${current_partition}" >> "$BOOT_HISTORY_FILE" 2>/dev/null || true
    
    local switch_count=0
    local last_partition=""
    local cutoff_time=$((current_time - FLAPPING_WINDOW_SECONDS))
    
    if [ -f "$BOOT_HISTORY_FILE" ]; then
        while IFS=: read -r timestamp partition; do
            if [[ "$timestamp" =~ ^[0-9]+$ ]] && [ "$timestamp" -lt "$cutoff_time" ]; then
                continue
            fi
            
            if [ -n "$last_partition" ] && [ "$last_partition" != "$partition" ]; then
                switch_count=$((switch_count + 1))
            fi
            last_partition="$partition"
        done < "$BOOT_HISTORY_FILE"
    fi
    
    log_phase1 "Partition switches in last ${FLAPPING_WINDOW_SECONDS}s: $switch_count"
    
    # Cleanup old entries
    local keep_cutoff=$((current_time - FLAPPING_WINDOW_SECONDS - 300))
    if [ -f "$BOOT_HISTORY_FILE" ]; then
        awk -v cutoff="$keep_cutoff" -F: '$1 >= cutoff' "$BOOT_HISTORY_FILE" > "${BOOT_HISTORY_FILE}.tmp" 2>/dev/null && \
            mv "${BOOT_HISTORY_FILE}.tmp" "$BOOT_HISTORY_FILE" 2>/dev/null || true
    fi
    
    if [ $switch_count -ge $MAX_PARTITION_SWITCHES ]; then
        error_phase1 "FLAPPING DETECTED: $switch_count partition switches (threshold: $MAX_PARTITION_SWITCHES)"
        return 0
    fi
    
    return 1
}

# Check for rollback condition
check_rollback() {
    log_phase1 "Starting rollback detection..."
    
    # Check for manual boot override flag
    local manual_override=$(fw_printenv -n manual_boot_override 2>/dev/null || echo "0")
    if [ "$manual_override" = "1" ]; then
        log_phase1 "Manual boot override detected, skipping rollback detection"
        fw_setenv manual_boot_override 0 2>/dev/null || true
        return 0
    fi
    
    # Check if state file exists
    if [ ! -f "$STATE_FILE" ]; then
        log_phase1 "No state file found, nothing to validate"
        return 0
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        error_phase1 "jq command not found, cannot parse state file"
        return 1
    fi
    
    # Read update phase from state file
    local update_phase=$(jq -r '.update_phase // "idle"' "$STATE_FILE" 2>/dev/null)
    
    if [ "$update_phase" != "applied_pending_validation" ]; then
        log_phase1 "Update phase is '$update_phase', not pending validation"
        return 0
    fi
    
    # Get target partition from state file
    local target_partition=$(jq -r '.target_partition // ""' "$STATE_FILE" 2>/dev/null)
    if [ -z "$target_partition" ] || [ "$target_partition" = "null" ]; then
        log_phase1 "No target partition in state file"
        return 0
    fi
    
    # Get current partition
    local current_partition=$(get_current_partition)
    
    if [ "$current_partition" = "unknown" ]; then
        error_phase1 "Cannot determine current partition"
        return 1
    fi
    
    # Compare partitions
    if [ "$current_partition" != "$target_partition" ]; then
        error_phase1 "ROLLBACK DETECTED: expected $target_partition, got $current_partition"
        ROLLBACK_DETECTED=true
        
        local workflow_id=$(jq -r '.workflow_id // "unknown"' "$STATE_FILE" 2>/dev/null)
        local reason="uboot_rollback_boot_attempts_exceeded"
        
        # Use file locking for atomic operations
        {
            flock -x 200
            
            log_phase1 "Acquiring lock for state operations..."
            
            # Update state file with rollback info
            local updated_state=$(jq \
                --arg phase "rolled_back" \
                --arg reason "$reason" \
                '.update_phase = $phase | .rollback_reason = $reason' \
                "$STATE_FILE" 2>/dev/null)
            
            if [ -n "$updated_state" ]; then
                write_atomic "$STATE_FILE" "$updated_state" || true
            fi
            
            # Add to blacklist file
            echo "$workflow_id:$(date -Iseconds):$reason" >> "$BLACKLIST_FILE" 2>/dev/null && \
                sync "$BLACKLIST_FILE" 2>/dev/null || true
            log_phase1 "Added workflow $workflow_id to blacklist"
            
            # Cleanup old blacklist entries
            if [ -f "$BLACKLIST_FILE" ]; then
                tail -n "$MAX_BLACKLIST_ENTRIES" "$BLACKLIST_FILE" > "${BLACKLIST_FILE}.tmp" 2>/dev/null && \
                    mv "${BLACKLIST_FILE}.tmp" "$BLACKLIST_FILE" 2>/dev/null || true
            fi
            
            # Write rollback event for ADU agent
            local rollback_event="{
  \"event\": \"rollback_occurred\",
  \"timestamp\": \"$(date -Iseconds)\",
  \"failed_workflow_id\": \"$workflow_id\",
  \"reason\": \"$reason\",
  \"expected_partition\": \"$target_partition\",
  \"actual_partition\": \"$current_partition\"
}"
            write_atomic "$ROLLBACK_EVENT_FILE" "$rollback_event" || true
            
            # Reset state to idle
            updated_state=$(jq '.update_phase = "idle"' "$STATE_FILE" 2>/dev/null)
            [ -n "$updated_state" ] && write_atomic "$STATE_FILE" "$updated_state" || true
            
        } 200>"$LOCK_FILE"
        
        log_phase1 "Rollback detection complete - workflow blacklisted"
        return 0
    else
        log_phase1 "Boot validation passed: on expected partition $current_partition"
        return 0
    fi
}

# Handle partition flapping
handle_flapping() {
    local current_partition="$1"
    
    # Get workflow ID from state file if available
    local workflow_id="unknown"
    local update_phase="idle"
    
    if [ -f "$STATE_FILE" ] && command -v jq &> /dev/null; then
        workflow_id=$(jq -r '.workflow_id // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
        update_phase=$(jq -r '.update_phase // "idle"' "$STATE_FILE" 2>/dev/null || echo "idle")
    fi
    
    # Only blacklist if there was an update in progress
    if [ "$update_phase" = "applied_pending_validation" ] && [ "$workflow_id" != "unknown" ] && [ -n "$workflow_id" ]; then
        log_phase1 "Blacklisting workflow $workflow_id due to flapping during update validation"
        echo "$workflow_id:$(date -Iseconds):partition_flapping" >> "$BLACKLIST_FILE" 2>/dev/null && \
            sync "$BLACKLIST_FILE" 2>/dev/null || true
    fi
    
    # Force stable boot to last known good partition
    local lkg_partition=$(fw_printenv -n last_known_good_partition 2>/dev/null || echo "rootA")
    log_phase1 "Forcing boot to last known good partition: $lkg_partition"
    
    fw_setenv boot_partition "$lkg_partition" 2>/dev/null || true
    fw_setenv upgrade_available 0 2>/dev/null || true
    fw_setenv boot_attempts 0 2>/dev/null || true
    fw_setenv boot_result success 2>/dev/null || true
    
    # Clear state file
    if [ -f "$STATE_FILE" ]; then
        echo '{"update_phase":"idle","flapping_detected":true}' > "$STATE_FILE" 2>/dev/null || true
    fi
    
    log_phase1 "System stabilized to $lkg_partition"
}

# Run Phase 1: Rollback Detection
run_phase1() {
    CURRENT_PHASE="phase1"
    log_phase1 "=== Phase 1: Rollback Detection Starting ==="
    
    ensure_directories
    
    local current_partition=$(get_current_partition)
    log_phase1 "Current partition: $current_partition"
    
    # Check for partition flapping
    if detect_partition_flapping "$current_partition"; then
        error_phase1 "Partition flapping detected - system unstable"
        handle_flapping "$current_partition"
        ROLLBACK_DETECTED=true
    fi
    
    # Check for rollback
    if check_rollback; then
        log_phase1 "Rollback check complete"
    else
        error_phase1 "Rollback check failed - continuing boot anyway"
    fi
    
    # Safety mechanism: If not in validation mode, ensure boot_result is set to success
    local upgrade_available=$(fw_printenv -n upgrade_available 2>/dev/null || echo "0")
    if [ "$upgrade_available" = "0" ]; then
        log_phase1 "Not in validation mode - marking boot as successful"
        fw_setenv boot_result success 2>/dev/null || true
    else
        log_phase1 "In validation mode - proceeding to Phase 2 for health checks"
    fi
    
    log_phase1 "=== Phase 1: Rollback Detection Complete ==="
}

# ============================================================================
# Phase 2: Health Validation Functions
# ============================================================================

# Load configuration from INI file
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warn "Configuration file not found: $CONFIG_FILE (using defaults)"
        return 0
    fi
    
    log_info "Loading configuration from $CONFIG_FILE"
    
    local section=""
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            key=$(echo "$key" | xargs)
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

# Check for manual override
check_manual_override() {
    if [[ -f "$OVERRIDE_FLAG" ]]; then
        log_info "Manual override detected: $OVERRIDE_FLAG"
        return 0
    fi
    return 1
}

# Built-in health checks
check_systemd_services() {
    local check_name="SystemdServices"
    local severity
    severity=$(grep "^CheckSystemdServices=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "critical")
    
    if [[ "$severity" == "disabled" ]]; then
        CHECK_RESULTS[$check_name]="skipped"
        return 0
    fi
    
    log_info "Running check: $check_name (severity: $severity)"
    
    local services
    services=$(grep "^Services=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "systemd-journald,dbus")
    
    local failed_services=()
    IFS=',' read -ra SERVICE_LIST <<< "$services"
    
    for service in "${SERVICE_LIST[@]}"; do
        service=$(echo "$service" | xargs)
        if ! systemctl is-active --quiet "$service" 2>/dev/null; then
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
    return 0
}

check_filesystem_writable() {
    local check_name="FilesystemWritable"
    local severity
    severity=$(grep "^CheckFilesystemWritable=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "critical")
    
    if [[ "$severity" == "disabled" ]]; then
        CHECK_RESULTS[$check_name]="skipped"
        return 0
    fi
    
    log_info "Running check: $check_name"
    
    local test_file="/tmp/.adu-write-test-$$"
    if ! echo "test" > "$test_file" 2>/dev/null; then
        CHECK_RESULTS[$check_name]="failed"
        if [[ "$severity" == "critical" ]]; then
            CRITICAL_FAILURES+=("$check_name: Cannot write to /tmp")
            return 2
        else
            WARNINGS+=("$check_name: Cannot write to /tmp")
            return 1
        fi
    fi
    rm -f "$test_file"
    
    CHECK_RESULTS[$check_name]="passed"
    return 0
}

check_disk_space() {
    local check_name="DiskSpace"
    local severity
    severity=$(grep "^CheckDiskSpace=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "warning")
    
    if [[ "$severity" == "disabled" ]]; then
        CHECK_RESULTS[$check_name]="skipped"
        return 0
    fi
    
    log_info "Running check: $check_name"
    
    local min_free_mb
    min_free_mb=$(grep "^MinimumFreeMB=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | xargs || echo "100")
    
    local available_mb
    available_mb=$(df -m / | awk 'NR==2 {print $4}')
    
    if [[ "$available_mb" -lt "$min_free_mb" ]]; then
        CHECK_RESULTS[$check_name]="failed"
        local msg="Low disk space: ${available_mb}MB (min: ${min_free_mb}MB)"
        if [[ "$severity" == "critical" ]]; then
            CRITICAL_FAILURES+=("$check_name: $msg")
            return 2
        else
            WARNINGS+=("$check_name: $msg")
            return 1
        fi
    fi
    
    CHECK_RESULTS[$check_name]="passed"
    return 0
}

# Run custom validation checks
run_custom_checks() {
    if [[ ! -d "$CUSTOM_CHECKS_DIR" ]]; then
        log_info "Custom checks directory not found: $CUSTOM_CHECKS_DIR"
        return 0
    fi
    
    log_info "Running custom checks from: $CUSTOM_CHECKS_DIR"
    
    local check_count=0
    while IFS= read -r -d '' check_script; do
        if [[ ! -x "$check_script" ]]; then
            continue
        fi
        
        local check_name
        check_name=$(basename "$check_script")
        log_info "Running custom check: $check_name"
        
        local output exit_code
        set +e
        output=$("$check_script" 2>&1)
        exit_code=$?
        set -e
        
        case $exit_code in
            0) CHECK_RESULTS["Custom:$check_name"]="passed" ;;
            1) CHECK_RESULTS["Custom:$check_name"]="warning"; WARNINGS+=("Custom:$check_name: $output") ;;
            2) CHECK_RESULTS["Custom:$check_name"]="failed"; CRITICAL_FAILURES+=("Custom:$check_name: $output") ;;
            *) CHECK_RESULTS["Custom:$check_name"]="error" ;;
        esac
        
        ((check_count++))
    done < <(find "$CUSTOM_CHECKS_DIR" -maxdepth 1 -type f -executable -print0 2>/dev/null | sort -z)
    
    log_info "Completed $check_count custom checks"
}

# Save validation state for status queries
save_state() {
    local status="$1"
    
    mkdir -p "$(dirname "$VALIDATION_STATE_FILE")" 2>/dev/null || true
    cat > "$VALIDATION_STATE_FILE" <<EOF
STATUS=$status
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
CRITICAL_FAILURES=${#CRITICAL_FAILURES[@]}
WARNINGS=${#WARNINGS[@]}
TOTAL_CHECKS=${#CHECK_RESULTS[@]}
ROLLBACK_DETECTED=$ROLLBACK_DETECTED
EOF
}

# Run Phase 2: Health Validation
run_phase2() {
    CURRENT_PHASE="phase2"
    log_info "=== Phase 2: Health Validation Starting ==="
    
    load_config
    
    # Check if we're in upgrade mode
    local upgrade_available
    upgrade_available=$(get_uboot_env "upgrade_available")
    
    if [[ "$upgrade_available" != "1" ]]; then
        log_info "Not in upgrade mode (upgrade_available=$upgrade_available), skipping health checks"
        return 0
    fi
    
    # If rollback was detected in Phase 1, we're in safe mode
    if [[ "$ROLLBACK_DETECTED" == "true" ]]; then
        log_info "Rollback detected in Phase 1 - running in SAFE MODE (all failures downgraded to warnings)"
    fi
    
    # Check for manual override first
    if check_manual_override; then
        log_info "Manual override confirmed - marking boot as successful"
        set_uboot_env "boot_result" "success"
        set_uboot_env "upgrade_available" "0"
        save_state "success_manual"
        rm -f "$OVERRIDE_FLAG"
        return 0
    fi
    
    # Run all built-in checks
    check_systemd_services || true
    check_filesystem_writable || true
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
    
    # In rollback/safe mode, downgrade all failures to warnings
    if [[ "$ROLLBACK_DETECTED" == "true" && ${#CRITICAL_FAILURES[@]} -gt 0 ]]; then
        log_warn "In SAFE MODE - downgrading ${#CRITICAL_FAILURES[@]} critical failure(s) to warnings"
        for failure in "${CRITICAL_FAILURES[@]}"; do
            WARNINGS+=("(downgraded) $failure")
        done
        CRITICAL_FAILURES=()
    fi
    
    if [[ ${#CRITICAL_FAILURES[@]} -gt 0 ]]; then
        log_error "Validation FAILED - Critical failures detected:"
        for failure in "${CRITICAL_FAILURES[@]}"; do
            log_error "  - $failure"
        done
        
        if [[ "$ALLOW_MANUAL_OVERRIDE" == "true" ]]; then
            log_info "Manual override enabled. Run 'sudo adu-confirm-boot confirm' to override."
        fi
        
        set_uboot_env "boot_result" "failed"
        save_state "failed"
        return 1
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
    log_info "=== Phase 2: Health Validation Complete ==="
    return 0
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    initialize_logging
    
    # Phase 1: Rollback Detection (always runs, non-fatal errors)
    run_phase1
    
    # Phase 2: Health Validation (runs if upgrade_available=1)
    if ! run_phase2; then
        log_error "Health validation failed"
        exit 1
    fi
    
    log_info "========================================="
    log_info "ADU Boot Validation Service Complete"
    log_info "========================================="
    exit 0
}

# Run main
main "$@"
