#!/bin/bash
################################################################################
# ADU Boot Validator Service
################################################################################
#
# PURPOSE:
#   This service is the gatekeeper for A/B update validation. It runs early in
#   the boot sequence (BEFORE deviceupdate-agent.service) to detect update
#   failures and prevent infinite update retry loops.
#
# HOW IT AFFECTS A/B UPDATE OUTCOMES:
#
#   1. ROLLBACK DETECTION (Primary Function)
#      - When an update is applied, the system reboots to the new partition
#      - If the new partition fails to boot properly (kernel panic, service
#        failures, etc.), U-Boot automatically rolls back after 5 boot attempts
#      - This service DETECTS the rollback by comparing:
#        * Expected partition (from /var/lib/adu/states/swupdate_state.json)
#        * Actual partition (from /proc/cmdline)
#      - If mismatch detected:
#        → Adds workflow_id to BLACKLIST (/var/lib/adu/states/failed_workflows.txt)
#        → Future update attempts with this workflow_id are REJECTED in download/install/apply
#        → Prevents ADU agent from repeatedly trying the same broken update
#
#   2. FLAPPING PREVENTION (Secondary Function)
#      - Detects rapid partition switching (>3 switches in 10 minutes)
#      - If flapping detected during an active update:
#        → Blacklists the workflow_id
#        → Forces boot to last_known_good_partition
#        → Sets upgrade_available=0 to stop update cycle
#      - Prevents system instability from bad updates that partially boot
#
#   3. BOOT SUCCESS MARKING (Safety Mechanism)
#      - If NOT in update validation mode (upgrade_available=0):
#        → Sets boot_result=success
#        → Prevents rollback loops when ADU agent can't connect to IoT Hub
#        → Ensures stable partition stays stable
#
# UPDATE WORKFLOW INTEGRATION:
#
#   Normal Update Flow:
#     1. ADU Agent downloads/installs update to inactive partition (rootB)
#     2. yocto-a-b-update.sh sets: upgrade_available=1, boot_attempts=0, boot_partition=rootB
#     3. System reboots
#     4. → THIS SERVICE RUNS ← (checks for rollback/flapping)
#     5. If boot successful: adu-boot-health.sh marks success (boot_result=success)
#     6. ADU agent reports success to IoT Hub
#
#   Failed Update Flow (Service Impact):
#     1. ADU Agent installs broken update to rootB
#     2. System reboots, new rootB fails to boot properly
#     3. U-Boot increments boot_attempts (1, 2, 3, 4, 5)
#     4. After 5 failed attempts, U-Boot auto-rollback to rootA
#     5. → THIS SERVICE RUNS ← DETECTS ROLLBACK (expected rootB, got rootA)
#     6. → Adds workflow_id to blacklist file
#     7. Next time ADU tries same update:
#        → yocto-a-b-update.sh checks blacklist
#        → Update REJECTED with error (infinite loop prevented!)
#
# KEY FILES:
#   - Blacklist: /var/lib/adu/states/failed_workflows.txt
#   - State: /var/lib/adu/states/swupdate_state.json
#   - Boot History: /var/lib/adu/states/boot_history.log
#
# SYSTEMD DEPENDENCIES:
#   - Runs BEFORE: deviceupdate-agent.service (must detect issues first)
#   - Runs AFTER: mount-overlays.service (needs /var/lib/adu available)
#
# ERROR HANDLING:
#   - All failures are NON-FATAL (system will boot even if validation fails)
#   - Uses logging for diagnostics (journalctl -u adu-boot-validator)
#
################################################################################

# Note: We do NOT use 'set -e' because we want to handle errors gracefully
# and ensure the system boots even if validation fails
set -u  # Exit on undefined variables

# Configuration
STATE_DIR="/var/lib/adu/states"
STATE_FILE="${STATE_DIR}/swupdate_state.json"
BLACKLIST_FILE="${STATE_DIR}/failed_workflows.txt"
ROLLBACK_EVENT_FILE="${STATE_DIR}/rollback_event.json"
BOOT_HISTORY_FILE="${STATE_DIR}/boot_history.log"
LOCK_FILE="/var/lock/adu-state.lock"
MAX_BLACKLIST_ENTRIES=10

# Flapping detection configuration
MAX_PARTITION_SWITCHES=3    # Maximum allowed partition switches
FLAPPING_WINDOW_SECONDS=600 # Within 10 minutes


# Logging functions
log() {
    echo "[adu-boot-validator] $*" | systemd-cat -t adu-boot-validator -p info
}

error() {
    echo "[adu-boot-validator] ERROR: $*" | systemd-cat -t adu-boot-validator -p err
}

# Ensure directories exist with proper ownership
if [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR" || log "Warning: Failed to create $STATE_DIR"
    
    # Get adu user UID/GID dynamically (should be 800:800)
    ADU_UID=$(id -u adu 2>/dev/null || echo "800")
    ADU_GID=$(id -g adu 2>/dev/null || echo "800")
    
    # Set ownership and permissions
    chown "${ADU_UID}:${ADU_GID}" "$STATE_DIR" 2>/dev/null || log "Warning: Failed to set ownership on $STATE_DIR"
    chmod 770 "$STATE_DIR" 2>/dev/null || log "Warning: Failed to set permissions on $STATE_DIR"
    log "Created $STATE_DIR with ownership ${ADU_UID}:${ADU_GID} and mode 770"
fi

if [ ! -d /var/lock ]; then
    mkdir -p /var/lock || log "Warning: Failed to create /var/lock"
fi

# Get current partition from kernel command line
get_current_partition() {
    if grep -q "root=/dev/mmcblk0p2" /proc/cmdline; then
        echo "rootA"
    elif grep -q "root=/dev/mmcblk0p3" /proc/cmdline; then
        echo "rootB"
    else
        error "Unknown root partition in /proc/cmdline"
        echo "unknown"
    fi
}

# Write data atomically with sync
write_atomic() {
    local file="$1"
    local content="$2"
    
    if ! echo "$content" > "${file}.tmp" 2>/dev/null; then
        error "Failed to write to ${file}.tmp"
        return 1
    fi
    
    sync "${file}.tmp" 2>/dev/null
    
    if ! mv "${file}.tmp" "$file" 2>/dev/null; then
        error "Failed to move ${file}.tmp to $file"
        rm -f "${file}.tmp" 2>/dev/null
        return 1
    fi
    
    sync "$file" 2>/dev/null
    return 0
}

# Detect partition flapping (rapid switching between partitions)
# Returns 0 if flapping detected, 1 if normal
#
# To reset flapping detection state for intentional testing/reboots:
#   Option 1: Delete boot history: rm /var/lib/adu/states/boot_history.log
#   Option 2: Set manual override: fw_setenv manual_boot_override 1
#             (This will skip rollback detection on next boot and auto-clear)
detect_partition_flapping() {
    local current_partition="$1"
    local current_time=$(date +%s)
    
    # Append current boot to history: timestamp:partition
    if ! echo "${current_time}:${current_partition}" >> "$BOOT_HISTORY_FILE" 2>/dev/null; then
        log "Warning: Failed to write to boot history file"
        # Continue anyway - flapping detection is not critical for boot
    fi
    
    # Read boot history and filter recent entries
    local switch_count=0
    local last_partition=""
    local cutoff_time=$((current_time - FLAPPING_WINDOW_SECONDS))
    
    # Only read if file exists
    if [ -f "$BOOT_HISTORY_FILE" ]; then
        while IFS=: read -r timestamp partition; do
            # Skip entries outside time window (only compare if timestamp is numeric)
            if [[ "$timestamp" =~ ^[0-9]+$ ]] && [ "$timestamp" -lt "$cutoff_time" ]; then
                continue
            fi
            
            # Count partition switches
            if [ -n "$last_partition" ] && [ "$last_partition" != "$partition" ]; then
                switch_count=$((switch_count + 1))
            fi
            last_partition="$partition"
        done < "$BOOT_HISTORY_FILE"
    fi
    
    log "Partition switches in last ${FLAPPING_WINDOW_SECONDS}s: $switch_count"
    
    # Cleanup old entries (keep only entries within window + some buffer)
    local keep_cutoff=$((current_time - FLAPPING_WINDOW_SECONDS - 300))
    if [ -f "$BOOT_HISTORY_FILE" ]; then
        if awk -v cutoff="$keep_cutoff" -F: '$1 >= cutoff' "$BOOT_HISTORY_FILE" > "${BOOT_HISTORY_FILE}.tmp" 2>/dev/null; then
            mv "${BOOT_HISTORY_FILE}.tmp" "$BOOT_HISTORY_FILE" 2>/dev/null || log "Warning: Failed to cleanup boot history"
        else
            log "Warning: awk command failed during boot history cleanup"
            rm -f "${BOOT_HISTORY_FILE}.tmp" 2>/dev/null
        fi
    fi
    
    # Check if flapping
    if [ $switch_count -ge $MAX_PARTITION_SWITCHES ]; then
        error "FLAPPING DETECTED: $switch_count partition switches in ${FLAPPING_WINDOW_SECONDS}s (threshold: $MAX_PARTITION_SWITCHES)"
        return 0
    fi
    
    return 1
}

# Check for rollback condition
check_rollback() {
    log "Starting rollback detection..."
    
    # Check for manual boot override flag
    local manual_override=$(fw_printenv -n manual_boot_override 2>/dev/null || echo "0")
    if [ "$manual_override" = "1" ]; then
        log "Manual boot override detected, skipping rollback detection"
        fw_setenv manual_boot_override 0 || log "Warning: Failed to clear manual_boot_override"
        return 0
    fi
    
    # Check if state file exists
    if [ ! -f "$STATE_FILE" ]; then
        log "No state file found, nothing to validate"
        return 0
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        error "jq command not found, cannot parse state file"
        return 1
    fi
    
    # Read update phase from state file
    local update_phase=$(jq -r '.update_phase // "idle"' "$STATE_FILE" 2>/dev/null)
    
    if [ "$update_phase" != "applied_pending_validation" ]; then
        log "Update phase is '$update_phase', not pending validation"
        return 0
    fi
    
    # Get target partition from state file
    local target_partition=$(jq -r '.target_partition // ""' "$STATE_FILE" 2>/dev/null)
    if [ -z "$target_partition" ] || [ "$target_partition" = "null" ]; then
        log "No target partition in state file"
        return 0
    fi
    
    # Get current partition
    local current_partition=$(get_current_partition)
    
    if [ "$current_partition" = "unknown" ]; then
        error "Cannot determine current partition"
        return 1
    fi
    
    # Compare partitions
    if [ "$current_partition" != "$target_partition" ]; then
        error "ROLLBACK DETECTED: expected $target_partition, got $current_partition"
        
        local workflow_id=$(jq -r '.workflow_id // "unknown"' "$STATE_FILE" 2>/dev/null)
        local reason="uboot_rollback_boot_attempts_exceeded"
        
        # Use file locking for atomic operations
        {
            flock -x 200
            
            log "Acquiring lock for state operations..."
            
            # Update state file with rollback info
            local updated_state=$(jq \
                --arg phase "rolled_back" \
                --arg reason "$reason" \
                '.update_phase = $phase | .rollback_reason = $reason' \
                "$STATE_FILE" 2>/dev/null)
            
            if [ -n "$updated_state" ]; then
                if write_atomic "$STATE_FILE" "$updated_state"; then
                    log "Updated state file with rollback status"
                else
                    error "Failed to write rollback status to state file"
                fi
            fi
            
            # Add to blacklist file (persistent storage on /adu partition)
            # File format: workflow_id:timestamp:reason
            if echo "$workflow_id:$(date -Iseconds):$reason" >> "$BLACKLIST_FILE" 2>/dev/null; then
                sync "$BLACKLIST_FILE" 2>/dev/null
                log "Added workflow $workflow_id to blacklist file"
            else
                error "Failed to write to blacklist file $BLACKLIST_FILE"
            fi
            
            # Cleanup old file blacklist entries (keep last N entries)
            if [ -f "$BLACKLIST_FILE" ]; then
                if tail -n "$MAX_BLACKLIST_ENTRIES" "$BLACKLIST_FILE" > "${BLACKLIST_FILE}.tmp" 2>/dev/null; then
                    if mv "${BLACKLIST_FILE}.tmp" "$BLACKLIST_FILE" 2>/dev/null; then
                        sync "$BLACKLIST_FILE" 2>/dev/null
                        log "Cleaned up file blacklist (keeping last $MAX_BLACKLIST_ENTRIES entries)"
                    else
                        log "Warning: Failed to move blacklist temp file"
                        rm -f "${BLACKLIST_FILE}.tmp" 2>/dev/null
                    fi
                else
                    log "Warning: Failed to cleanup blacklist file"
                fi
            fi
            
            # Write rollback event for ADU agent to read
            local rollback_event=$(cat <<EOF
{
  "event": "rollback_occurred",
  "timestamp": "$(date -Iseconds)",
  "failed_workflow_id": "$workflow_id",
  "reason": "$reason",
  "expected_partition": "$target_partition",
  "actual_partition": "$current_partition"
}
EOF
)
            if write_atomic "$ROLLBACK_EVENT_FILE" "$rollback_event"; then
                log "Wrote rollback event for ADU agent"
            else
                error "Failed to write rollback event file"
            fi
            
            # Clean up state - set back to idle
            updated_state=$(jq '.update_phase = "idle"' "$STATE_FILE" 2>/dev/null)
            if [ -n "$updated_state" ]; then
                if write_atomic "$STATE_FILE" "$updated_state"; then
                    log "Reset update phase to idle"
                else
                    error "Failed to reset update phase to idle"
                fi
            fi
            
        } 200>"$LOCK_FILE"
        
        log "Rollback detection complete - workflow blacklisted"
        return 0
        
    else
        log "Boot validation passed: on expected partition $current_partition"
        return 0
    fi
}

# Main execution
log "=== ADU Boot Validator Starting ==="

# Get current partition
current_partition=$(get_current_partition)
log "Current partition: $current_partition"

# Check for partition flapping (rapid switching between partitions)
if detect_partition_flapping "$current_partition"; then
    error "Partition flapping detected - system unstable"
    
    # Get workflow ID from state file if available (only blacklist if there was an active update)
    workflow_id="unknown"
    if [ -f "$STATE_FILE" ] && command -v jq &> /dev/null; then
        workflow_id=$(jq -r '.workflow_id // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
        update_phase=$(jq -r '.update_phase // "idle"' "$STATE_FILE" 2>/dev/null || echo "idle")
    else
        update_phase="idle"
    fi
    
    # Only blacklist if there was an update in progress (not for manual partition switches)
    if [ "$update_phase" = "applied_pending_validation" ] && [ "$workflow_id" != "unknown" ] && [ -n "$workflow_id" ]; then
        log "Blacklisting workflow $workflow_id due to flapping during update validation"
        
        # Add to file blacklist (persistent storage on /adu partition)
        if echo "$workflow_id:$(date -Iseconds):partition_flapping" >> "$BLACKLIST_FILE" 2>/dev/null; then
            sync "$BLACKLIST_FILE" 2>/dev/null
            log "Added to file blacklist with reason: partition_flapping"
        else
            error "Failed to write to blacklist file $BLACKLIST_FILE"
        fi
    fi
    
    # Force stable boot to last known good partition
    lkg_partition=$(fw_printenv -n last_known_good_partition 2>/dev/null || echo "rootA")
    log "Forcing boot to last known good partition: $lkg_partition"
    
    # Set U-Boot variables (non-fatal if they fail)
    fw_setenv boot_partition "$lkg_partition" || log "Warning: Failed to set boot_partition"
    fw_setenv upgrade_available 0 || log "Warning: Failed to set upgrade_available"
    fw_setenv boot_attempts 0 || log "Warning: Failed to set boot_attempts"
    fw_setenv boot_result success || log "Warning: Failed to set boot_result"
    
    # Clear state file
    if [ -f "$STATE_FILE" ] && command -v jq &> /dev/null; then
        if ! echo '{"update_phase":"idle","flapping_detected":true}' > "$STATE_FILE" 2>/dev/null; then
            log "Warning: Failed to update state file after flapping detection"
        fi
    fi
    
    log "System stabilized to $lkg_partition, future updates blocked for this workflow"
fi

# Check for rollback
if check_rollback; then
    log "Rollback check complete"
else
    error "Rollback check failed - continuing boot anyway"
    # Note: We don't exit 1 here because we want the system to boot even if validation fails
fi

# Safety mechanism: If not in validation mode, ensure boot_result is set to success
# This prevents rollback loops when ADU agent can't connect to IoT Hub (e.g., misconfigured du-config.json)
upgrade_available=$(fw_printenv -n upgrade_available 2>/dev/null || echo "0")
if [ "$upgrade_available" = "0" ]; then
    log "Not in validation mode - marking boot as successful"
    fw_setenv boot_result success || log "Warning: Failed to set boot_result"
    log "Set boot_result=success (stable partition, no validation needed)"
else
    log "In validation mode - ADU agent must report success"
fi

log "=== ADU Boot Validator Complete ==="
exit 0
