#!/usr/bin/env bats
# BATS tests: Agent failure → watchdog escalation → rollback lifecycle
#
# Tests the critical scenario:
#   1. A/B update applied to rootB
#   2. Agent crashes on rootB after update
#   3. Watchdog detects failure, restarts agent (up to MAX_RESTARTS)
#   4. After MAX_RESTARTS exceeded, watchdog triggers reboot
#   5. U-Boot increments boot_attempts on each reboot
#   6. At threshold (boot_attempts >= max_boot_attempts), U-Boot rolls back to LKG
#   7. Post-rollback: Phase 1 detects rollback, blacklists workflow, resets state
#
# Run with: bats tests/test-agent-failure-lifecycle.bats

load helpers/mock-uboot-env

setup() {
    setup_mock_uboot_env
    setup_mock_cmdline

    export TEST_STATE_DIR=$(mktemp -d)
    export STATE_FILE="${TEST_STATE_DIR}/swupdate_state.json"
    export BLACKLIST_FILE="${TEST_STATE_DIR}/failed_workflows.txt"
    export ROLLBACK_EVENT_FILE="${TEST_STATE_DIR}/rollback_event.json"
    export BOOT_HISTORY_FILE="${TEST_STATE_DIR}/boot_history.log"
    export RESTART_COUNT_FILE="${TEST_STATE_DIR}/watchdog_restart_count"
    export UBOOT_LOCK_FILE="${TEST_STATE_DIR}/adu-uboot-env.lock"
    export MAX_RESTARTS=3
    export MAX_BOOT_ATTEMPTS=5
}

teardown() {
    teardown_mock_uboot_env
    teardown_mock_cmdline
    rm -rf "$TEST_STATE_DIR"
}

# ============================================================================
# Helper: Simulate applying an update (yocto-a-b-update.sh ApplyUpdate)
# ============================================================================
simulate_apply_update() {
    local workflow_id="$1"
    local target_partition="$2"
    local current_partition="$3"

    # Write state file atomically (as yocto-a-b-update.sh does)
    cat > "${STATE_FILE}.tmp" <<EOF
{
  "update_phase": "applied_pending_validation",
  "workflow_id": "${workflow_id}",
  "target_partition": "${target_partition}",
  "previous_partition": "${current_partition}",
  "installed_criteria": "2.0.0",
  "timestamp": "$(date -Iseconds)"
}
EOF
    mv "${STATE_FILE}.tmp" "$STATE_FILE"

    # Set U-Boot env (as yocto-a-b-update.sh does)
    fw_setenv upgrade_available 1
    fw_setenv boot_attempts 0
    fw_setenv boot_result unknown
    fw_setenv boot_partition "$target_partition"
    fw_setenv update_in_progress_id "$workflow_id"
}

# ============================================================================
# Helper: Simulate U-Boot boot (increments boot_attempts)
# ============================================================================
simulate_uboot_boot() {
    local boot_attempts
    boot_attempts=$(fw_printenv -n boot_attempts)
    boot_attempts=$((boot_attempts + 1))
    fw_setenv boot_attempts "$boot_attempts"

    local boot_partition
    boot_partition=$(fw_printenv -n boot_partition)

    # Store per-partition attempt count
    if [[ "$boot_partition" == "rootA" ]]; then
        fw_setenv boot_attempts_A "$boot_attempts"
    else
        fw_setenv boot_attempts_B "$boot_attempts"
    fi
}

# ============================================================================
# Helper: Simulate U-Boot rollback check
# ============================================================================
simulate_uboot_rollback_check() {
    local boot_attempts max_boot_attempts upgrade_available
    boot_attempts=$(fw_printenv -n boot_attempts)
    max_boot_attempts=$(fw_printenv -n max_boot_attempts)
    upgrade_available=$(fw_printenv -n upgrade_available)

    if [[ "$upgrade_available" == "1" && "$boot_attempts" -ge "$max_boot_attempts" ]]; then
        # Rollback!
        local boot_partition lkg
        boot_partition=$(fw_printenv -n boot_partition)
        lkg=$(fw_printenv -n last_known_good_partition)

        fw_setenv boot_result_B "failed"
        fw_setenv rollback_failed_partition "$boot_partition"
        fw_setenv boot_partition "$lkg"
        fw_setenv boot_attempts 0
        fw_setenv boot_result "rollback"
        fw_setenv rollback_occurred 1
        fw_setenv upgrade_available 0
        return 0  # rollback happened
    fi
    return 1  # no rollback
}

# ============================================================================
# Helper: Simulate watchdog check cycle
# ============================================================================
simulate_watchdog_cycle() {
    local agent_active="$1"  # true/false

    if [[ "$agent_active" == "true" ]]; then
        # Agent is running — reset count
        echo "0" > "$RESTART_COUNT_FILE"
        return 0  # no action needed
    fi

    # Agent is down — increment restart count
    local count
    count=$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo "0")
    count=$((count + 1))
    echo "$count" > "$RESTART_COUNT_FILE"

    if [[ "$count" -ge "$MAX_RESTARTS" ]]; then
        return 2  # reboot needed
    fi
    return 1  # restart attempted
}

# ============================================================================
# Helper: Simulate Phase 1 rollback detection
# ============================================================================
simulate_phase1_rollback_detection() {
    local actual_partition="$1"

    local upgrade_available rollback_flag
    upgrade_available=$(fw_printenv -n upgrade_available)
    rollback_flag=$(fw_printenv -n rollback_occurred)

    # Non-upgrade boot with rollback flag
    if [[ "$upgrade_available" == "0" && "$rollback_flag" == "1" ]]; then
        # Detect rollback via state file
        if [[ -f "$STATE_FILE" ]]; then
            local target_partition workflow_id
            target_partition=$(jq -r '.target_partition // ""' "$STATE_FILE" 2>/dev/null)
            workflow_id=$(jq -r '.workflow_id // "unknown"' "$STATE_FILE" 2>/dev/null)

            if [[ -n "$target_partition" && "$actual_partition" != "$target_partition" ]]; then
                # Rollback confirmed — blacklist workflow
                echo "${workflow_id}:$(date -Iseconds):boot_attempts_exceeded" >> "$BLACKLIST_FILE"

                # Write rollback event
                cat > "$ROLLBACK_EVENT_FILE" <<EOF
{
  "event": "rollback_detected",
  "failed_workflow": "${workflow_id}",
  "failed_partition": "${target_partition}",
  "current_partition": "${actual_partition}",
  "timestamp": "$(date -Iseconds)"
}
EOF
                # Update state file to idle
                cat > "${STATE_FILE}.tmp" <<EOF
{
  "update_phase": "idle",
  "workflow_id": "",
  "previous_workflow": "${workflow_id}",
  "rollback_reason": "boot_attempts_exceeded"
}
EOF
                mv "${STATE_FILE}.tmp" "$STATE_FILE"
            fi
        fi

        # Reset boot state
        fw_setenv boot_attempts 0
        fw_setenv rollback_occurred 0
        return 0  # rollback was detected
    fi

    # Normal stable boot
    if [[ "$upgrade_available" == "0" && "$rollback_flag" != "1" ]]; then
        fw_setenv boot_result success
        fw_setenv boot_attempts 0
        return 1  # normal boot, no rollback
    fi

    return 2  # upgrade in progress, skip
}

# ============================================================================
# LIFECYCLE TEST: Full agent-failure → rollback scenario
# ============================================================================

@test "LIFECYCLE: Update applied → agent crashes → watchdog escalates → reboot → rollback → blacklist" {
    # === STEP 1: Initial stable state on rootA ===
    mock_set_env "boot_partition" "rootA"
    mock_set_env "boot_attempts" "0"
    mock_set_env "upgrade_available" "0"
    mock_set_env "boot_result" "success"
    mock_set_env "last_known_good_partition" "rootA"
    mock_set_env "max_boot_attempts" "5"
    mock_set_env "rescue_required" "0"
    mock_set_env "rollback_occurred" "0"
    set_cmdline_partition "rootA"

    # === STEP 2: Apply update to rootB ===
    simulate_apply_update "workflow-agent-crash-001" "rootB" "rootA"

    [[ $(mock_get_env "boot_partition") == "rootB" ]]
    [[ $(mock_get_env "upgrade_available") == "1" ]]
    [[ $(jq -r '.target_partition' "$STATE_FILE") == "rootB" ]]

    # === STEP 3: First boot into rootB ===
    simulate_uboot_boot
    set_cmdline_partition "rootB"
    [[ $(mock_get_env "boot_attempts") == "1" ]]

    # === STEP 4: Agent crashes, watchdog tries to restart 3 times ===
    local watchdog_result
    simulate_watchdog_cycle "false" || watchdog_result=$?  # restart 1
    [[ $watchdog_result -eq 1 ]]
    watchdog_result=0
    simulate_watchdog_cycle "false" || watchdog_result=$?  # restart 2
    [[ $watchdog_result -eq 1 ]]
    watchdog_result=0
    simulate_watchdog_cycle "false" || watchdog_result=$?  # restart 3 → reboot
    [[ $watchdog_result -eq 2 ]]

    # === STEP 5: Reboot cycles (simulating reboots until threshold) ===
    # Boot 2
    simulate_uboot_boot
    [[ $(mock_get_env "boot_attempts") == "2" ]]
    echo "0" > "$RESTART_COUNT_FILE"  # watchdog resets on new boot

    simulate_watchdog_cycle "false" || true
    simulate_watchdog_cycle "false" || true
    simulate_watchdog_cycle "false" || true
    # reboot again

    # Boot 3
    simulate_uboot_boot
    [[ $(mock_get_env "boot_attempts") == "3" ]]
    echo "0" > "$RESTART_COUNT_FILE"

    simulate_watchdog_cycle "false" || true
    simulate_watchdog_cycle "false" || true
    simulate_watchdog_cycle "false" || true

    # Boot 4
    simulate_uboot_boot
    [[ $(mock_get_env "boot_attempts") == "4" ]]
    echo "0" > "$RESTART_COUNT_FILE"

    simulate_watchdog_cycle "false" || true
    simulate_watchdog_cycle "false" || true
    simulate_watchdog_cycle "false" || true

    # Boot 5 — this hits the threshold
    simulate_uboot_boot
    [[ $(mock_get_env "boot_attempts") == "5" ]]

    # === STEP 6: U-Boot rollback check triggers ===
    simulate_uboot_rollback_check
    local rollback_happened=$?
    [[ $rollback_happened -eq 0 ]]

    # Verify rollback state
    [[ $(mock_get_env "boot_partition") == "rootA" ]]
    [[ $(mock_get_env "boot_result") == "rollback" ]]
    [[ $(mock_get_env "rollback_occurred") == "1" ]]
    [[ $(mock_get_env "upgrade_available") == "0" ]]
    [[ $(mock_get_env "boot_attempts") == "0" ]]
    [[ $(mock_get_env "rollback_failed_partition") == "rootB" ]]

    # === STEP 7: Boot into rootA (post-rollback) ===
    simulate_uboot_boot
    set_cmdline_partition "rootA"
    [[ $(mock_get_env "boot_attempts") == "1" ]]

    # === STEP 8: Phase 1 detects rollback ===
    simulate_phase1_rollback_detection "rootA"
    local phase1_result=$?
    [[ $phase1_result -eq 0 ]]

    # === VERIFY FINAL STATE ===
    # Workflow is blacklisted
    grep -q "workflow-agent-crash-001" "$BLACKLIST_FILE"

    # Rollback event recorded
    [[ -f "$ROLLBACK_EVENT_FILE" ]]
    [[ $(jq -r '.failed_workflow' "$ROLLBACK_EVENT_FILE") == "workflow-agent-crash-001" ]]
    [[ $(jq -r '.failed_partition' "$ROLLBACK_EVENT_FILE") == "rootB" ]]
    [[ $(jq -r '.current_partition' "$ROLLBACK_EVENT_FILE") == "rootA" ]]

    # State file is idle
    [[ $(jq -r '.update_phase' "$STATE_FILE") == "idle" ]]
    [[ $(jq -r '.rollback_reason' "$STATE_FILE") == "boot_attempts_exceeded" ]]

    # Boot state is clean
    [[ $(mock_get_env "boot_attempts") == "0" ]]
    [[ $(mock_get_env "rollback_occurred") == "0" ]]
    [[ $(mock_get_env "boot_partition") == "rootA" ]]
}

# ============================================================================
# LIFECYCLE TEST: Agent recovers within watchdog threshold — no rollback
# ============================================================================

@test "LIFECYCLE: Update applied → agent crashes once → recovers → boot confirmed" {
    # Setup: update applied to rootB
    mock_set_env "boot_partition" "rootB"
    mock_set_env "boot_attempts" "1"
    mock_set_env "upgrade_available" "1"
    mock_set_env "boot_result" "unknown"
    mock_set_env "last_known_good_partition" "rootA"
    mock_set_env "max_boot_attempts" "5"
    mock_set_env "rollback_occurred" "0"
    set_cmdline_partition "rootB"

    cat > "$STATE_FILE" <<'EOF'
{
  "update_phase": "applied_pending_validation",
  "workflow_id": "workflow-recover-001",
  "target_partition": "rootB",
  "previous_partition": "rootA"
}
EOF

    # Watchdog: agent fails once, then recovers
    simulate_watchdog_cycle "false" || true   # restart 1
    simulate_watchdog_cycle "false" || true   # restart 2
    simulate_watchdog_cycle "true"            # agent came back!

    # Restart count should be reset
    [[ $(cat "$RESTART_COUNT_FILE") == "0" ]]

    # Simulate Phase 2 success (health checks pass, agent is running)
    fw_setenv boot_result success
    fw_setenv upgrade_available 0
    fw_setenv boot_attempts 0
    fw_setenv last_known_good_partition "rootB"
    fw_setenv update_in_progress_id ""

    # Update state file
    cat > "$STATE_FILE" <<'EOF'
{
  "update_phase": "idle",
  "workflow_id": ""
}
EOF

    # === VERIFY: No rollback, boot confirmed on rootB ===
    [[ $(mock_get_env "boot_partition") == "rootB" ]]
    [[ $(mock_get_env "boot_result") == "success" ]]
    [[ $(mock_get_env "upgrade_available") == "0" ]]
    [[ $(mock_get_env "last_known_good_partition") == "rootB" ]]
    [[ $(mock_get_env "boot_attempts") == "0" ]]
    [[ ! -f "$BLACKLIST_FILE" || ! -s "$BLACKLIST_FILE" ]]
}

# ============================================================================
# LIFECYCLE TEST: Watchdog reboot does NOT rollback before threshold
# ============================================================================

@test "LIFECYCLE: Watchdog reboot increments boot_attempts but no rollback until threshold" {
    mock_set_env "boot_partition" "rootB"
    mock_set_env "boot_attempts" "0"
    mock_set_env "upgrade_available" "1"
    mock_set_env "max_boot_attempts" "5"
    mock_set_env "last_known_good_partition" "rootA"
    mock_set_env "rollback_occurred" "0"

    # Simulate 4 reboots (below threshold of 5)
    for i in 1 2 3 4; do
        simulate_uboot_boot
        simulate_uboot_rollback_check || true  # should NOT rollback
    done

    # Still on rootB, no rollback
    [[ $(mock_get_env "boot_partition") == "rootB" ]]
    [[ $(mock_get_env "rollback_occurred") == "0" ]]
    [[ $(mock_get_env "boot_attempts") == "4" ]]

    # 5th boot triggers rollback
    simulate_uboot_boot
    simulate_uboot_rollback_check

    [[ $(mock_get_env "boot_partition") == "rootA" ]]
    [[ $(mock_get_env "rollback_occurred") == "1" ]]
}

# ============================================================================
# LIFECYCLE TEST: Blacklisted workflow cannot be re-applied
# ============================================================================

@test "LIFECYCLE: Previously blacklisted workflow is rejected on re-apply attempt" {
    # Workflow was previously blacklisted
    echo "workflow-bad-firmware:2026-05-07T00:00:00+00:00:boot_attempts_exceeded" > "$BLACKLIST_FILE"

    # Simulate ADU trying to re-apply the same workflow
    local workflow_id="workflow-bad-firmware"
    local is_blacklisted=false

    if [[ -f "$BLACKLIST_FILE" ]]; then
        while IFS=: read -r failed_id rest; do
            if [[ "$failed_id" == "$workflow_id" ]]; then
                is_blacklisted=true
                break
            fi
        done < "$BLACKLIST_FILE"
    fi

    [[ "$is_blacklisted" == "true" ]]

    # A different workflow should still be allowed
    local new_workflow="workflow-good-firmware"
    local new_is_blacklisted=false

    while IFS=: read -r failed_id rest; do
        if [[ "$failed_id" == "$new_workflow" ]]; then
            new_is_blacklisted=true
            break
        fi
    done < "$BLACKLIST_FILE"

    [[ "$new_is_blacklisted" == "false" ]]
}

# ============================================================================
# LIFECYCLE TEST: Catastrophic failure (LKG also fails)
# ============================================================================

@test "LIFECYCLE: After rollback to LKG, if LKG also fails → rescue_required latch set" {
    # State: already rolled back to rootA (LKG), but rootA is also failing
    mock_set_env "boot_partition" "rootA"
    mock_set_env "last_known_good_partition" "rootA"
    mock_set_env "upgrade_available" "0"
    mock_set_env "rollback_occurred" "0"
    mock_set_env "boot_attempts" "0"
    mock_set_env "max_boot_attempts" "5"
    mock_set_env "rescue_required" "0"

    # Simulate repeated boot failures on LKG partition
    for i in 1 2 3 4 5; do
        simulate_uboot_boot
    done

    [[ $(mock_get_env "boot_attempts") == "5" ]]

    # U-Boot catastrophic check: not an upgrade (upgrade_available=0) but
    # boot_attempts >= max on LKG → set rescue latch
    local boot_attempts max_boot_attempts upgrade_available boot_partition lkg
    boot_attempts=$(fw_printenv -n boot_attempts)
    max_boot_attempts=$(fw_printenv -n max_boot_attempts)
    upgrade_available=$(fw_printenv -n upgrade_available)
    boot_partition=$(fw_printenv -n boot_partition)
    lkg=$(fw_printenv -n last_known_good_partition)

    if [[ "$upgrade_available" == "0" && "$boot_attempts" -ge "$max_boot_attempts" ]]; then
        # LKG itself is failing — catastrophic
        fw_setenv rescue_required 1
        fw_setenv boot_result "catastrophic_failure"
    fi

    # === VERIFY: Rescue latch is set, system should halt ===
    [[ $(mock_get_env "rescue_required") == "1" ]]
    [[ $(mock_get_env "boot_result") == "catastrophic_failure" ]]

    # Next boot should detect rescue_required and NOT proceed
    local rescue
    rescue=$(fw_printenv -n rescue_required)
    [[ "$rescue" == "1" ]]
}

# ============================================================================
# LIFECYCLE TEST: Second boot after rollback doesn't overwrite rollback state
# ============================================================================

@test "LIFECYCLE: Second normal boot after rollback preserves blacklist and resets cleanly" {
    # State: post-rollback, Phase 1 already ran once
    mock_set_env "boot_partition" "rootA"
    mock_set_env "boot_attempts" "0"
    mock_set_env "upgrade_available" "0"
    mock_set_env "rollback_occurred" "0"  # already cleared by Phase 1
    mock_set_env "boot_result" "rollback"
    mock_set_env "last_known_good_partition" "rootA"
    set_cmdline_partition "rootA"

    echo "workflow-failed-123:2026-05-07T00:00:00+00:00:boot_attempts_exceeded" > "$BLACKLIST_FILE"
    cat > "$STATE_FILE" <<'EOF'
{
  "update_phase": "idle",
  "workflow_id": "",
  "previous_workflow": "workflow-failed-123",
  "rollback_reason": "boot_attempts_exceeded"
}
EOF

    # Simulate next normal boot (power cycle or routine reboot)
    simulate_uboot_boot
    [[ $(mock_get_env "boot_attempts") == "1" ]]

    # Phase 1 runs again — should see normal stable boot
    local phase1_result=0
    simulate_phase1_rollback_detection "rootA" || phase1_result=$?
    [[ $phase1_result -eq 1 ]]  # normal boot, no rollback

    # === VERIFY: blacklist preserved, state clean ===
    grep -q "workflow-failed-123" "$BLACKLIST_FILE"
    [[ $(mock_get_env "boot_result") == "success" ]]
    [[ $(mock_get_env "boot_attempts") == "0" ]]
    [[ $(jq -r '.update_phase' "$STATE_FILE") == "idle" ]]
}
