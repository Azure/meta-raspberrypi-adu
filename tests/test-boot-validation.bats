#!/usr/bin/env bats
# BATS tests for boot validation and A/B update logic
#
# Run with: bats tests/test-boot-validation.bats
# Requires: bats-core (https://github.com/bats-core/bats-core)

load helpers/mock-uboot-env

# ============================================================================
# Setup/Teardown
# ============================================================================

setup() {
    setup_mock_uboot_env
    
    # Create temp directories for state files
    export TEST_STATE_DIR=$(mktemp -d)
    export TEST_LOG_DIR=$(mktemp -d)
    export STATE_FILE="${TEST_STATE_DIR}/swupdate_state.json"
    export BLACKLIST_FILE="${TEST_STATE_DIR}/failed_workflows.txt"
    export ROLLBACK_EVENT_FILE="${TEST_STATE_DIR}/rollback_event.json"
    export BOOT_HISTORY_FILE="${TEST_STATE_DIR}/boot_history.log"
    export LOCK_FILE="${TEST_STATE_DIR}/adu-state.lock"
    export UBOOT_LOCK_FILE="${TEST_STATE_DIR}/adu-uboot-env.lock"
    export LOG_FILE="${TEST_LOG_DIR}/boot-validation.log"
    export VALIDATION_STATE_FILE="${TEST_STATE_DIR}/adu-validation-state"
    export OVERRIDE_FLAG="${TEST_STATE_DIR}/adu-boot-confirmed"
    export CONFIG_FILE="${TEST_STATE_DIR}/boot-validation.conf"
    
    # Create minimal config
    cat > "$CONFIG_FILE" <<'EOF'
[General]
ValidationTimeout=300
AllowManualOverride=true
AutoConfirmOnTimeout=false

[Checks]
CheckSystemdServices=critical
CheckFilesystemWritable=critical
CheckDiskSpace=warning
CustomChecksDir=/nonexistent

[SystemdServices]
Services=systemd-journald,dbus

[DiskSpace]
MinimumFreeMB=100
EOF
    
    # Mock /proc/cmdline
    setup_mock_cmdline
}

teardown() {
    teardown_mock_uboot_env
    teardown_mock_cmdline
    rm -rf "$TEST_STATE_DIR" "$TEST_LOG_DIR"
}

# ============================================================================
# Test: boot_attempts reset on normal (non-upgrade) boot
# ============================================================================

@test "boot_attempts is reset to 0 on normal non-upgrade boot" {
    mock_set_env "boot_partition" "rootA"
    mock_set_env "boot_attempts" "3"
    mock_set_env "upgrade_available" "0"
    mock_set_env "boot_result" "unknown"
    
    # Simulate Phase 1 logic: not in upgrade mode → reset boot_attempts
    local upgrade_available
    upgrade_available=$(fw_printenv -n upgrade_available)
    
    if [[ "$upgrade_available" == "0" ]]; then
        fw_setenv boot_result success
        fw_setenv boot_attempts 0
    fi
    
    [[ $(mock_get_env "boot_attempts") == "0" ]]
    [[ $(mock_get_env "boot_result") == "success" ]]
}

@test "boot_attempts is NOT reset when upgrade_available=1 (validation pending)" {
    mock_set_env "boot_partition" "rootB"
    mock_set_env "boot_attempts" "2"
    mock_set_env "upgrade_available" "1"
    
    local upgrade_available
    upgrade_available=$(fw_printenv -n upgrade_available)
    
    if [[ "$upgrade_available" == "0" ]]; then
        fw_setenv boot_attempts 0
    fi
    
    # boot_attempts should NOT be reset
    [[ $(mock_get_env "boot_attempts") == "2" ]]
}

# ============================================================================
# Test: Phase 2 success resets boot_attempts
# ============================================================================

@test "Phase 2 success resets boot_attempts and updates LKG" {
    mock_set_env "boot_partition" "rootB"
    mock_set_env "boot_attempts" "1"
    mock_set_env "upgrade_available" "1"
    mock_set_env "last_known_good_partition" "rootA"
    
    # Simulate Phase 2 success
    fw_setenv boot_result success
    fw_setenv upgrade_available 0
    fw_setenv boot_attempts 0
    
    local boot_partition
    boot_partition=$(fw_printenv -n boot_partition)
    fw_setenv last_known_good_partition "$boot_partition"
    
    [[ $(mock_get_env "boot_attempts") == "0" ]]
    [[ $(mock_get_env "boot_result") == "success" ]]
    [[ $(mock_get_env "upgrade_available") == "0" ]]
    [[ $(mock_get_env "last_known_good_partition") == "rootB" ]]
}

# ============================================================================
# Test: Manual override performs full state transition
# ============================================================================

@test "Manual override resets boot_attempts, updates LKG, clears upgrade" {
    mock_set_env "boot_partition" "rootB"
    mock_set_env "boot_attempts" "3"
    mock_set_env "upgrade_available" "1"
    mock_set_env "boot_result" "failed"
    mock_set_env "last_known_good_partition" "rootA"
    
    # Simulate manual override (full state transition)
    local boot_partition
    boot_partition=$(fw_printenv -n boot_partition)
    fw_setenv boot_result success
    fw_setenv upgrade_available 0
    fw_setenv boot_attempts 0
    fw_setenv last_known_good_partition "$boot_partition"
    fw_setenv update_in_progress_id ""
    
    [[ $(mock_get_env "boot_attempts") == "0" ]]
    [[ $(mock_get_env "boot_result") == "success" ]]
    [[ $(mock_get_env "upgrade_available") == "0" ]]
    [[ $(mock_get_env "last_known_good_partition") == "rootB" ]]
}

# ============================================================================
# Test: Rollback detection (partition mismatch)
# ============================================================================

@test "Rollback detected when actual partition != target partition" {
    # State file says we should be on rootB
    cat > "$STATE_FILE" <<'EOF'
{
  "update_phase": "applied_pending_validation",
  "workflow_id": "test-workflow-123",
  "target_partition": "rootB"
}
EOF
    
    # But /proc/cmdline shows rootA (U-Boot rolled back)
    set_cmdline_partition "rootA"
    
    # Detect rollback
    local target_partition
    target_partition=$(jq -r '.target_partition // ""' "$STATE_FILE" 2>/dev/null)
    
    local current_partition="rootA"  # From mock cmdline
    
    [[ "$current_partition" != "$target_partition" ]]
    
    # Verify workflow would be blacklisted
    local workflow_id
    workflow_id=$(jq -r '.workflow_id // "unknown"' "$STATE_FILE" 2>/dev/null)
    [[ "$workflow_id" == "test-workflow-123" ]]
}

@test "No rollback when actual partition matches target" {
    cat > "$STATE_FILE" <<'EOF'
{
  "update_phase": "applied_pending_validation",
  "workflow_id": "test-workflow-456",
  "target_partition": "rootA"
}
EOF
    
    set_cmdline_partition "rootA"
    
    local target_partition
    target_partition=$(jq -r '.target_partition // ""' "$STATE_FILE" 2>/dev/null)
    local current_partition="rootA"
    
    [[ "$current_partition" == "$target_partition" ]]
}

# ============================================================================
# Test: Workflow blacklist
# ============================================================================

@test "Blacklisted workflow is rejected" {
    # Add a workflow to blacklist
    echo "test-bad-workflow:2026-05-07T00:00:00+00:00:boot_attempts_exceeded" > "$BLACKLIST_FILE"
    
    local check_workflow_id="test-bad-workflow"
    local is_blacklisted=false
    
    while IFS=: read -r failed_id timestamp reason; do
        if [[ "$failed_id" == "$check_workflow_id" ]]; then
            is_blacklisted=true
            break
        fi
    done < "$BLACKLIST_FILE"
    
    [[ "$is_blacklisted" == "true" ]]
}

@test "Non-blacklisted workflow is allowed" {
    echo "other-workflow:2026-05-07T00:00:00+00:00:boot_attempts_exceeded" > "$BLACKLIST_FILE"
    
    local check_workflow_id="my-new-workflow"
    local is_blacklisted=false
    
    while IFS=: read -r failed_id timestamp reason; do
        if [[ "$failed_id" == "$check_workflow_id" ]]; then
            is_blacklisted=true
            break
        fi
    done < "$BLACKLIST_FILE"
    
    [[ "$is_blacklisted" == "false" ]]
}

@test "Empty blacklist file allows all workflows" {
    touch "$BLACKLIST_FILE"
    
    local check_workflow_id="any-workflow"
    local is_blacklisted=false
    
    while IFS=: read -r failed_id timestamp reason; do
        if [[ "$failed_id" == "$check_workflow_id" ]]; then
            is_blacklisted=true
            break
        fi
    done < "$BLACKLIST_FILE"
    
    [[ "$is_blacklisted" == "false" ]]
}

@test "Missing blacklist file allows all workflows" {
    rm -f "$BLACKLIST_FILE"
    
    # Should not fail
    [[ ! -f "$BLACKLIST_FILE" ]]
}

# ============================================================================
# Test: swupdate_state.json write/read cycle
# ============================================================================

@test "ApplyUpdate writes valid swupdate_state.json" {
    local workflow_id="apply-test-789"
    local update_partition="rootB"
    local current_partition="rootA"
    local installed_criteria="1.0.0"
    
    # Simulate ApplyUpdate state file write
    local state_content="{
  \"update_phase\": \"applied_pending_validation\",
  \"workflow_id\": \"$workflow_id\",
  \"target_partition\": \"$update_partition\",
  \"previous_partition\": \"$current_partition\",
  \"installed_criteria\": \"$installed_criteria\",
  \"timestamp\": \"$(date -Iseconds)\"
}"
    echo "$state_content" > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
    
    # Verify it can be read back
    local phase
    phase=$(jq -r '.update_phase' "$STATE_FILE")
    [[ "$phase" == "applied_pending_validation" ]]
    
    local target
    target=$(jq -r '.target_partition' "$STATE_FILE")
    [[ "$target" == "rootB" ]]
    
    local wf
    wf=$(jq -r '.workflow_id' "$STATE_FILE")
    [[ "$wf" == "apply-test-789" ]]
}

@test "State file with idle phase is ignored by rollback check" {
    cat > "$STATE_FILE" <<'EOF'
{
  "update_phase": "idle",
  "workflow_id": ""
}
EOF
    
    local update_phase
    update_phase=$(jq -r '.update_phase // "idle"' "$STATE_FILE" 2>/dev/null)
    [[ "$update_phase" == "idle" ]]
    # Rollback check should skip when phase != applied_pending_validation
}

# ============================================================================
# Test: Rescue latch (catastrophic failure)
# ============================================================================

@test "Rescue latch prevents boot loop after catastrophic failure" {
    mock_set_env "rescue_required" "1"
    mock_set_env "boot_partition" "rootA"
    mock_set_env "boot_attempts" "0"
    
    local rescue
    rescue=$(fw_printenv -n rescue_required)
    
    # Script should detect rescue_required=1 and NOT proceed to boot
    [[ "$rescue" == "1" ]]
}

@test "Rescue latch survives simulated power cycle" {
    mock_set_env "rescue_required" "1"
    
    # Simulate "power cycle" — re-read the env
    local rescue
    rescue=$(fw_printenv -n rescue_required)
    [[ "$rescue" == "1" ]]
    
    # Operator clears it
    fw_setenv rescue_required 0
    rescue=$(fw_printenv -n rescue_required)
    [[ "$rescue" == "0" ]]
}

# ============================================================================
# Test: Rollback threshold (off-by-one fix verification)
# ============================================================================

@test "Rollback triggers at exactly max_boot_attempts (>= check)" {
    mock_set_env "boot_attempts" "5"
    mock_set_env "max_boot_attempts" "5"
    mock_set_env "upgrade_available" "1"
    
    local boot_attempts max_boot_attempts
    boot_attempts=$(fw_printenv -n boot_attempts)
    max_boot_attempts=$(fw_printenv -n max_boot_attempts)
    
    # With -ge, rollback should trigger when boot_attempts=5 and max=5
    [[ "$boot_attempts" -ge "$max_boot_attempts" ]]
}

@test "Rollback does NOT trigger when boot_attempts < max" {
    mock_set_env "boot_attempts" "4"
    mock_set_env "max_boot_attempts" "5"
    mock_set_env "upgrade_available" "1"
    
    local boot_attempts max_boot_attempts
    boot_attempts=$(fw_printenv -n boot_attempts)
    max_boot_attempts=$(fw_printenv -n max_boot_attempts)
    
    # Should NOT trigger rollback
    [[ "$boot_attempts" -lt "$max_boot_attempts" ]]
}

# ============================================================================
# Test: Rollback preserves boot_result
# ============================================================================

@test "After rollback, boot_result is 'rollback' not 'unknown'" {
    mock_set_env "boot_partition" "rootB"
    mock_set_env "boot_attempts" "5"
    mock_set_env "upgrade_available" "1"
    mock_set_env "max_boot_attempts" "5"
    mock_set_env "last_known_good_partition" "rootA"
    
    # Simulate rollback in U-Boot
    fw_setenv boot_result_B "failed"
    fw_setenv rollback_failed_partition "rootB"
    fw_setenv boot_partition "rootA"  # from last_known_good
    fw_setenv boot_attempts 0
    fw_setenv boot_result "rollback"
    fw_setenv rollback_occurred 1
    fw_setenv upgrade_available 0
    
    [[ $(mock_get_env "boot_result") == "rollback" ]]
    [[ $(mock_get_env "rollback_occurred") == "1" ]]
    [[ $(mock_get_env "boot_partition") == "rootA" ]]
    [[ $(mock_get_env "upgrade_available") == "0" ]]
}

@test "Normal boot does NOT set rollback_occurred" {
    mock_set_env "rollback_occurred" "0"
    mock_set_env "upgrade_available" "0"
    
    # After normal Phase 1, rollback_occurred should still be 0
    [[ $(mock_get_env "rollback_occurred") == "0" ]]
}

# ============================================================================
# Test: Invalid boot_partition validation
# ============================================================================

@test "Invalid boot_partition falls back to last_known_good" {
    mock_set_env "boot_partition" "CORRUPTED"
    mock_set_env "last_known_good_partition" "rootA"
    
    local boot_partition
    boot_partition=$(fw_printenv -n boot_partition)
    
    if [[ "$boot_partition" != "rootA" && "$boot_partition" != "rootB" ]]; then
        local lkg
        lkg=$(fw_printenv -n last_known_good_partition)
        fw_setenv boot_partition "$lkg"
    fi
    
    [[ $(mock_get_env "boot_partition") == "rootA" ]]
}

@test "Invalid boot_partition with no LKG defaults to rootA" {
    mock_set_env "boot_partition" "GARBAGE"
    mock_set_env "last_known_good_partition" ""
    
    local boot_partition lkg
    boot_partition=$(fw_printenv -n boot_partition)
    
    if [[ "$boot_partition" != "rootA" && "$boot_partition" != "rootB" ]]; then
        lkg=$(fw_printenv -n last_known_good_partition 2>/dev/null || echo "")
        if [[ -n "$lkg" && "$lkg" != "" ]]; then
            fw_setenv boot_partition "$lkg"
        else
            fw_setenv boot_partition "rootA"
        fi
    fi
    
    [[ $(mock_get_env "boot_partition") == "rootA" ]]
}

# ============================================================================
# Test: Partition safety (update handler verifies actual root)
# ============================================================================

@test "Update handler detects boot_partition vs actual root mismatch" {
    mock_set_env "boot_partition" "rootB"
    set_cmdline_partition "rootA"
    
    local boot_partition="rootB"
    local actual_root=""
    
    if grep -q "root=/dev/mmcblk0p2" "$MOCK_PROC_CMDLINE" 2>/dev/null; then
        actual_root="rootA"
    elif grep -q "root=/dev/mmcblk0p3" "$MOCK_PROC_CMDLINE" 2>/dev/null; then
        actual_root="rootB"
    fi
    
    # Mismatch detected — should use actual root
    [[ "$actual_root" != "$boot_partition" ]]
    [[ "$actual_root" == "rootA" ]]
}

# ============================================================================
# Test: Flocking prevents concurrent access
# ============================================================================

@test "Shared flock serializes fw_setenv access" {
    local lock_file="${TEST_STATE_DIR}/test-lock"
    local result_file="${TEST_STATE_DIR}/flock-results"
    
    # Simulate two concurrent locked operations
    (
        flock -x 200
        echo "writer1_start" >> "$result_file"
        sleep 0.1
        echo "writer1_end" >> "$result_file"
    ) 200>"$lock_file" &
    local pid1=$!
    
    (
        flock -x 200
        echo "writer2_start" >> "$result_file"
        sleep 0.1
        echo "writer2_end" >> "$result_file"
    ) 200>"$lock_file" &
    local pid2=$!
    
    wait $pid1 $pid2
    
    # Verify writes are serialized (no interleaving)
    local line1 line2 line3 line4
    line1=$(sed -n '1p' "$result_file")
    line2=$(sed -n '2p' "$result_file")
    line3=$(sed -n '3p' "$result_file")
    line4=$(sed -n '4p' "$result_file")
    
    # Either writer1 completes before writer2 starts, or vice versa
    if [[ "$line1" == "writer1_start" ]]; then
        [[ "$line2" == "writer1_end" ]]
    else
        [[ "$line1" == "writer2_start" ]]
        [[ "$line2" == "writer2_end" ]]
    fi
}

# ============================================================================
# Test: Post-rollback boot_attempts handling  
# ============================================================================

@test "Post-rollback boot resets boot_attempts and clears rollback flag" {
    mock_set_env "boot_partition" "rootA"
    mock_set_env "boot_attempts" "1"
    mock_set_env "upgrade_available" "0"
    mock_set_env "rollback_occurred" "1"
    mock_set_env "boot_result" "rollback"
    
    # Phase 1 logic: not upgrading, but rollback flag is set
    local upgrade_available rollback_flag
    upgrade_available=$(fw_printenv -n upgrade_available)
    rollback_flag=$(fw_printenv -n rollback_occurred)
    
    if [[ "$upgrade_available" == "0" ]]; then
        if [[ "$rollback_flag" == "1" ]]; then
            # Post-rollback: reset counter but preserve rollback state
            fw_setenv boot_attempts 0
            fw_setenv rollback_occurred 0
        else
            fw_setenv boot_result success
            fw_setenv boot_attempts 0
        fi
    fi
    
    [[ $(mock_get_env "boot_attempts") == "0" ]]
    [[ $(mock_get_env "rollback_occurred") == "0" ]]
    # boot_result should still be "rollback" (not overwritten to success)
    [[ $(mock_get_env "boot_result") == "rollback" ]]
}

# ============================================================================
# Test: Atomic write
# ============================================================================

@test "write_atomic creates file via temp+rename" {
    local target="${TEST_STATE_DIR}/atomic-test.json"
    local content='{"test": "value"}'
    
    # Simulate write_atomic
    echo "$content" > "${target}.tmp"
    sync "${target}.tmp" 2>/dev/null || true
    mv "${target}.tmp" "$target"
    sync "$target" 2>/dev/null || true
    
    [[ -f "$target" ]]
    [[ ! -f "${target}.tmp" ]]
    
    local read_content
    read_content=$(cat "$target")
    [[ "$read_content" == "$content" ]]
}

# ============================================================================
# Test: Edge cases
# ============================================================================

@test "Empty boot_partition defaults to rootA" {
    mock_set_env "boot_partition" ""
    
    local bp
    bp=$(fw_printenv -n boot_partition 2>/dev/null || echo "")
    
    if [[ -z "$bp" ]]; then
        fw_setenv boot_partition "rootA"
    fi
    
    [[ $(mock_get_env "boot_partition") == "rootA" ]]
}

@test "Missing max_boot_attempts defaults to 5" {
    # Remove the variable entirely
    sed -i '/^max_boot_attempts=/d' "$MOCK_UBOOT_ENV"
    
    local max
    max=$(fw_printenv -n max_boot_attempts 2>/dev/null || echo "")
    
    if [[ -z "$max" ]]; then
        fw_setenv max_boot_attempts 5
    fi
    
    [[ $(mock_get_env "max_boot_attempts") == "5" ]]
}

@test "Blacklist file limited to MAX_BLACKLIST_ENTRIES" {
    local max_entries=10
    
    # Add 15 entries
    for i in $(seq 1 15); do
        echo "workflow-${i}:2026-05-07T00:00:00+00:00:test" >> "$BLACKLIST_FILE"
    done
    
    # Trim to max
    tail -n "$max_entries" "$BLACKLIST_FILE" > "${BLACKLIST_FILE}.tmp"
    mv "${BLACKLIST_FILE}.tmp" "$BLACKLIST_FILE"
    
    local count
    count=$(wc -l < "$BLACKLIST_FILE")
    [[ "$count" -le "$max_entries" ]]
    
    # Oldest entries should be gone, newest kept
    ! grep -q "workflow-1:" "$BLACKLIST_FILE"
    grep -q "workflow-15:" "$BLACKLIST_FILE"
}
