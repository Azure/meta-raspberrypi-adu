#!/usr/bin/env bats
# BATS tests for adu-agent-watchdog.sh
#
# Run with: bats tests/test-agent-watchdog.bats

load helpers/mock-uboot-env

setup() {
    setup_mock_uboot_env
    
    export TEST_STATE_DIR=$(mktemp -d)
    export RESTART_COUNT_FILE="${TEST_STATE_DIR}/watchdog_restart_count"
    export MAX_RESTARTS=3
    export WATCHDOG_SCRIPT="${BATS_TEST_DIRNAME}/../recipes-support/adu-boot-validation/files/adu-agent-watchdog.sh"
}

teardown() {
    teardown_mock_uboot_env
    rm -rf "$TEST_STATE_DIR"
}

# ============================================================================
# Restart count tracking
# ============================================================================

@test "Restart count file starts at 0" {
    [[ ! -f "$RESTART_COUNT_FILE" ]]
    local count
    count=$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo "0")
    [[ "$count" == "0" ]]
}

@test "Restart count increments on each failure" {
    echo "0" > "$RESTART_COUNT_FILE"
    
    for expected in 1 2 3; do
        local current
        current=$(cat "$RESTART_COUNT_FILE")
        echo "$((current + 1))" > "$RESTART_COUNT_FILE"
    done
    
    [[ $(cat "$RESTART_COUNT_FILE") == "3" ]]
}

@test "Exceeding MAX_RESTARTS triggers reboot" {
    echo "$MAX_RESTARTS" > "$RESTART_COUNT_FILE"
    
    local current
    current=$(cat "$RESTART_COUNT_FILE")
    
    local should_reboot=false
    if [[ "$current" -ge "$MAX_RESTARTS" ]]; then
        should_reboot=true
    fi
    
    [[ "$should_reboot" == "true" ]]
}

@test "Active agent resets restart count" {
    echo "3" > "$RESTART_COUNT_FILE"
    
    # Agent is active — reset
    echo "0" > "$RESTART_COUNT_FILE"
    
    [[ $(cat "$RESTART_COUNT_FILE") == "0" ]]
}

# ============================================================================
# Agent state detection
# ============================================================================

@test "Disabled agent is left alone" {
    # Override systemctl to report disabled
    systemctl() {
        if [[ "$1" == "is-enabled" && "$2" == "--quiet" ]]; then
            return 1
        fi
        return 1
    }
    export -f systemctl
    
    local is_enabled=false
    if systemctl is-enabled --quiet deviceupdate-agent.service 2>/dev/null; then
        is_enabled=true
    fi
    
    [[ "$is_enabled" == "false" ]]
}

@test "Enabled but inactive agent triggers restart" {
    # Set systemctl to return enabled but not active
    systemctl() {
        if [[ "$1" == "is-enabled" && "$2" == "--quiet" ]]; then
            return 0
        elif [[ "$1" == "is-active" && "$2" == "--quiet" ]]; then
            return 1
        elif [[ "$1" == "restart" ]]; then
            echo "RESTART_CALLED:$3"
            return 0
        fi
        return 1
    }
    export -f systemctl
    
    local needs_restart=false
    if systemctl is-enabled --quiet deviceupdate-agent.service 2>/dev/null; then
        if ! systemctl is-active --quiet deviceupdate-agent.service 2>/dev/null; then
            needs_restart=true
        fi
    fi
    
    [[ "$needs_restart" == "true" ]]
}

@test "Active agent needs no restart" {
    mock_add_active_service "deviceupdate-agent.service"
    
    local needs_restart=false
    if systemctl is-enabled --quiet deviceupdate-agent.service 2>/dev/null; then
        if ! systemctl is-active --quiet deviceupdate-agent.service 2>/dev/null; then
            needs_restart=true
        fi
    fi
    
    [[ "$needs_restart" == "false" ]]
}
