#!/bin/sh
# Helper script to check for U-Boot rollback and report to ADU agent
# This should be called early in boot (before ADU agent starts) or by ADU agent itself
#
# Usage: check-uboot-rollback.sh
# Returns: 0 if no rollback, 1 if rollback occurred

set -e

# Check if fw_printenv is available
if ! command -v fw_printenv >/dev/null 2>&1; then
    echo "ERROR: fw_printenv not found. Install u-boot-fw-utils package."
    exit 2
fi

# Check if update failed flag is set
adu_update_failed=$(fw_printenv -n adu_update_failed 2>/dev/null || echo "0")

if [ "$adu_update_failed" = "1" ]; then
    echo "=========================================="
    echo "ADU UPDATE ROLLBACK DETECTED"
    echo "=========================================="
    echo ""
    
    # Read error details
    adu_rc=$(fw_printenv -n adu_rc 2>/dev/null || echo "unknown")
    adu_erc=$(fw_printenv -n adu_erc 2>/dev/null || echo "unknown")
    adu_error_text=$(fw_printenv -n adu_error_text 2>/dev/null || echo "No error text available")
    adu_workflow_id=$(fw_printenv -n adu_workflow_id 2>/dev/null || echo "unknown")
    rpipart=$(fw_printenv -n rpipart 2>/dev/null || echo "unknown")
    
    echo "Error Details:"
    echo "  Result Code (adu_rc): $adu_rc"
    echo "  Extended Code (adu_erc): $adu_erc"
    echo "  Error Text: $adu_error_text"
    echo "  Failed Workflow ID: $adu_workflow_id"
    echo "  Current Partition: $rpipart"
    echo ""
    echo "Action Required:"
    echo "  1. ADU agent should report this failure to Azure IoT Hub"
    echo "  2. Update deployment should be marked as failed"
    echo "  3. IMPORTANT: Check if current deployment ID matches failed workflow ID"
    echo "     If match: Skip re-attempting this deployment (prevents infinite loop)"
    echo "  4. After reporting, clear the error flags:"
    echo "     fw_setenv adu_update_failed 0"
    echo "     fw_setenv adu_workflow_id \"\""
    echo "     fw_setenv adu_rc \"\""
    echo "     fw_setenv adu_erc \"\""
    echo "     fw_setenv adu_error_text \"\""
    echo ""
    echo "=========================================="
    
    # Log to syslog if available
    if command -v logger >/dev/null 2>&1; then
        logger -t adu-rollback -p user.err "ADU update rollback: $adu_error_text (rc=$adu_rc, erc=$adu_erc, workflow=$adu_workflow_id)"
    fi
    
    exit 1
else
    echo "No ADU rollback detected. System boot successful."
    exit 0
fi
