#!/bin/bash
# ADU Agent Health Watchdog
# Checks if the deviceupdate-agent service is running and healthy.
# Triggered by adu-agent-watchdog.timer periodically after boot.

set -u

LOG_TAG="adu-agent-watchdog"
AGENT_SERVICE="deviceupdate-agent.service"
MAX_RESTART_ATTEMPTS=3
RESTART_COUNTER_FILE="/var/lib/adu/states/agent_restart_count"

log_info() {
    logger -t "$LOG_TAG" -p user.info "$*"
}

log_warn() {
    logger -t "$LOG_TAG" -p user.warning "$*"
}

log_error() {
    logger -t "$LOG_TAG" -p user.err "$*"
}

# Get current restart count (resets on successful check)
get_restart_count() {
    if [[ -f "$RESTART_COUNTER_FILE" ]]; then
        cat "$RESTART_COUNTER_FILE" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

set_restart_count() {
    echo "$1" > "$RESTART_COUNTER_FILE" 2>/dev/null || true
}

# Check if agent service is active
if systemctl is-active --quiet "$AGENT_SERVICE" 2>/dev/null; then
    log_info "Agent service is active and running"
    # Reset restart counter on healthy check
    set_restart_count 0
    exit 0
fi

# Agent is not running — check if it's enabled
if ! systemctl is-enabled --quiet "$AGENT_SERVICE" 2>/dev/null; then
    log_warn "Agent service is not enabled — skipping watchdog action"
    exit 0
fi

# Agent is enabled but not running
local_count=$(get_restart_count)
log_error "Agent service is NOT running (restart attempts: $local_count/$MAX_RESTART_ATTEMPTS)"

if [[ "$local_count" -ge "$MAX_RESTART_ATTEMPTS" ]]; then
    log_error "Max restart attempts ($MAX_RESTART_ATTEMPTS) exceeded — not restarting"
    log_error "Manual intervention required: systemctl status $AGENT_SERVICE"
    exit 1
fi

# Attempt restart
log_warn "Attempting to restart $AGENT_SERVICE (attempt $((local_count + 1))/$MAX_RESTART_ATTEMPTS)"
set_restart_count "$((local_count + 1))"

if systemctl restart "$AGENT_SERVICE" 2>/dev/null; then
    # Wait briefly and verify
    sleep 5
    if systemctl is-active --quiet "$AGENT_SERVICE" 2>/dev/null; then
        log_info "Agent service restarted successfully"
        exit 0
    else
        log_error "Agent service failed to start after restart"
        exit 1
    fi
else
    log_error "Failed to restart agent service"
    exit 1
fi
