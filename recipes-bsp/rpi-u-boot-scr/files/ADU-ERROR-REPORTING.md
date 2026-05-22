# U-Boot to ADU Agent Error Communication

## Overview

When a system update fails to boot properly (exceeds 3 boot attempts), the U-Boot boot script automatically rolls back to the previous working partition and sets error variables in the persistent U-Boot environment. These variables allow the ADU agent (or other monitoring services) to detect the rollback, understand the failure reason, and report it back to Azure IoT Hub.

## Error Variables Set by U-Boot

When rollback occurs (`have_updated=1` and `boot_attempts=3`), the boot script sets:

| Variable | Type | Description | Example Value |
|----------|------|-------------|---------------|
| `adu_update_failed` | integer | Flag indicating update failed (1=failed, 0=success) | `1` |
| `adu_rc` | integer | ADU result code (1=general failure) | `1` |
| `adu_erc` | integer | Extended result code (806355714=boot attempts exceeded) | `806355714` |
| `adu_error_text` | string | Human-readable error description | `"Update rollback: boot failed 3 times on updated partition"` |
| `adu_workflow_id` | string (GUID) | Workflow ID that failed (set by SWUpdate handler) | `"a1b2c3d4-e5f6-7890-abcd-ef1234567890"` |
| `have_updated` | integer | Cleared to 0 to prevent continuous rollback | `0` |

**Note:** `adu_workflow_id` is **preserved** (not set by U-Boot, but not cleared either). This allows the ADU agent to:
- Identify which specific deployment failed
- Skip re-attempting the same failed deployment
- Prevent infinite update loops

### Result Code Meanings

**adu_rc (Result Code):**
- `0` = Success (not set during rollback)
- `1` = General failure

**adu_erc (Extended Result Code):**
- `806355714` = Boot attempts exceeded (failed to boot 3 times) - **Set by U-Boot on rollback**
- Other codes are defined in the ADU agent SWUpdate handler:
  - Various codes for download failures, installation failures, verification failures, etc.
  - Refer to ADU agent source code for complete error code definitions

**Note:** The error code `806355714` is specifically reserved for U-Boot rollback scenarios and should match the definition in the ADU agent's SWUpdate handler code.

## Workflow ID Tracking (Preventing Infinite Loops)

The `adu_workflow_id` variable is critical for preventing infinite update loops:

1. **SWUpdate Handler Sets ID**: When processing a deployment, the SWUpdate handler (or ADU agent) sets:
   ```bash
   fw_setenv adu_workflow_id "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
   ```

2. **U-Boot Preserves ID**: During rollback, U-Boot **preserves** (does not clear) `adu_workflow_id`

3. **ADU Agent Checks ID**: Before re-attempting an update, the ADU agent checks:
   ```bash
   current_workflow_id=$(get_current_deployment_id_from_iot_hub)
   failed_workflow_id=$(fw_printenv -n adu_workflow_id 2>/dev/null)
   
   if [ "$failed_workflow_id" = "$current_workflow_id" ] && \
      [ "$(fw_printenv -n adu_update_failed)" = "1" ]; then
       echo "This deployment already failed. Skipping re-attempt."
       report_failure_to_iot_hub
       exit 1
   fi
   ```

4. **Clearing After Report**: Only clear after successfully reporting to Azure:
   ```bash
   fw_setenv adu_update_failed 0
   fw_setenv adu_workflow_id ""
   ```

## Integration with ADU Agent

### Method 1: Pre-ADU Service Check (Recommended)

Create a systemd service that runs before the ADU agent to check for rollback:

```ini
# /etc/systemd/system/adu-rollback-check.service
[Unit]
Description=Check for ADU Update Rollback
Before=azure-device-update.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/check-uboot-rollback.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

The ADU agent can then query the service status or read the error variables directly.

### Method 2: Direct Check in ADU Agent

Modify the ADU agent to check U-Boot environment on startup:

```c
// Pseudocode example
bool check_for_rollback() {
    char *failed = fw_getenv("adu_update_failed");
    if (failed && strcmp(failed, "1") == 0) {
        int rc = atoi(fw_getenv("adu_rc"));
        int erc = atoi(fw_getenv("adu_erc"));
        char *error_text = fw_getenv("adu_error_text");
        
        // Report to Azure IoT Hub
        report_update_failure(rc, erc, error_text);
        
        // Clear error flags after reporting
        fw_setenv("adu_update_failed", "0");
        fw_unsetenv("adu_rc");
        fw_unsetenv("adu_erc");
        fw_unsetenv("adu_error_text");
        
        return true;
    }
    return false;
}
```

### Method 3: Custom Monitoring Service

Create a dedicated service that monitors for rollbacks and handles reporting:

```bash
#!/bin/sh
# /usr/sbin/adu-rollback-monitor.sh

while true; do
    if [ "$(fw_printenv -n adu_update_failed 2>/dev/null)" = "1" ]; then
        # Read error details
        rc=$(fw_printenv -n adu_rc 2>/dev/null)
        erc=$(fw_printenv -n adu_erc 2>/dev/null)
        error_text=$(fw_printenv -n adu_error_text 2>/dev/null)
        
        # Report to Azure (using Azure CLI or custom tool)
        az iot hub device-twin update \
            --device-id "$DEVICE_ID" \
            --hub-name "$IOT_HUB" \
            --set properties.reported.adu.updateResult='{"resultCode":'"$rc"',"extendedResultCode":'"$erc"',"errorText":"'"$error_text"'"}'
        
        # Clear flags after successful report
        fw_setenv adu_update_failed 0
        fw_setenv adu_rc ""
        fw_setenv adu_erc ""
        fw_setenv adu_error_text ""
        
        logger -t adu-rollback "Rollback reported to Azure IoT Hub"
    fi
    
    sleep 60  # Check every minute
done
```

## Reading U-Boot Environment Variables

### SWUpdate Handler Integration (Setting Workflow ID)

**Before applying update**, the SWUpdate handler or ADU agent must set the workflow ID:

```bash
#!/bin/bash
# Example: SWUpdate pre-install handler script
# This runs BEFORE applying the update

WORKFLOW_ID="$1"  # Passed from ADU agent or deployment manifest

# Set workflow ID in U-Boot environment
fw_setenv adu_workflow_id "$WORKFLOW_ID"

echo "Set workflow ID: $WORKFLOW_ID"
echo "If update fails to boot, this ID will be preserved for failure reporting"
```

**In ADU Agent**, before starting deployment:

```c
// C/C++ example
void set_workflow_id(const char* workflow_id) {
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "fw_setenv adu_workflow_id %s", workflow_id);
    int ret = system(cmd);
    if (ret != 0) {
        fprintf(stderr, "Failed to set workflow ID in U-Boot environment\n");
    }
}

// Before applying update
set_workflow_id(deployment->workflow_id);
```

**ADU Agent checking for previous failure**:

```bash
#!/bin/bash
# Check if current deployment already failed before

current_workflow_id="$1"  # From Azure IoT Hub deployment
failed_workflow_id=$(fw_printenv -n adu_workflow_id 2>/dev/null)
update_failed=$(fw_printenv -n adu_update_failed 2>/dev/null || echo "0")

if [ "$update_failed" = "1" ] && [ "$failed_workflow_id" = "$current_workflow_id" ]; then
    echo "ERROR: This deployment (workflow $current_workflow_id) already failed!"
    echo "Skipping re-attempt to prevent infinite loop."
    
    # Report failure to Azure if not already reported
    report_failure_to_azure "$current_workflow_id"
    
    # Clear flags after reporting
    fw_setenv adu_update_failed 0
    fw_setenv adu_workflow_id ""
    
    exit 1
fi

echo "Deployment $current_workflow_id not previously failed. Proceeding..."
```

### From Shell Scripts

```bash
# Check if update failed
adu_update_failed=$(fw_printenv -n adu_update_failed 2>/dev/null || echo "0")

if [ "$adu_update_failed" = "1" ]; then
    rc=$(fw_printenv -n adu_rc 2>/dev/null)
    erc=$(fw_printenv -n adu_erc 2>/dev/null)
    error_text=$(fw_printenv -n adu_error_text 2>/dev/null)
    workflow_id=$(fw_printenv -n adu_workflow_id 2>/dev/null)
    
    echo "Update failed: $error_text (rc=$rc, erc=$erc, workflow=$workflow_id)"
fi
```

### From C/C++ Applications

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Simple wrapper for fw_printenv
char* fw_getenv(const char *name) {
    char cmd[256];
    static char value[1024];
    FILE *fp;
    
    snprintf(cmd, sizeof(cmd), "fw_printenv -n %s 2>/dev/null", name);
    fp = popen(cmd, "r");
    if (!fp) return NULL;
    
    if (fgets(value, sizeof(value), fp) == NULL) {
        pclose(fp);
        return NULL;
    }
    
    // Remove trailing newline
    value[strcspn(value, "\n")] = 0;
    pclose(fp);
    return value;
}

void check_rollback() {
    char *failed = fw_getenv("adu_update_failed");
    if (failed && strcmp(failed, "1") == 0) {
        printf("Rollback detected!\n");
        printf("Result Code: %s\n", fw_getenv("adu_rc"));
        printf("Extended Code: %s\n", fw_getenv("adu_erc"));
        printf("Error: %s\n", fw_getenv("adu_error_text"));
        printf("Failed Workflow: %s\n", fw_getenv("adu_workflow_id"));
    }
}

// Check if current deployment should be skipped
bool should_skip_deployment(const char* current_workflow_id) {
    char *failed = fw_getenv("adu_update_failed");
    char *failed_workflow = fw_getenv("adu_workflow_id");
    
    if (failed && strcmp(failed, "1") == 0 &&
        failed_workflow && strcmp(failed_workflow, current_workflow_id) == 0) {
        fprintf(stderr, "Deployment %s already failed. Skipping re-attempt.\n", 
                current_workflow_id);
        return true;
    }
    return false;
    }
}
```

### From Python Applications

```python
import subprocess

def fw_getenv(name):
    """Read U-Boot environment variable"""
    try:
        result = subprocess.run(
            ['fw_printenv', '-n', name],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return None

def fw_setenv(name, value):
    """Set U-Boot environment variable"""
    try:
        subprocess.run(['fw_setenv', name, value], check=True)
        return True
    except subprocess.CalledProcessError:
        return False

def should_skip_deployment(current_workflow_id):
    """Check if deployment should be skipped due to previous failure"""
    failed = fw_getenv('adu_update_failed')
    failed_workflow = fw_getenv('adu_workflow_id')
    
    if failed == '1' and failed_workflow == current_workflow_id:
        print(f"Deployment {current_workflow_id} already failed. Skipping.")
        return True
    return False

def check_rollback():
    """Check if update rollback occurred"""
    if fw_getenv('adu_update_failed') == '1':
        return {
            'failed': True,
            'rc': int(fw_getenv('adu_rc') or 0),
            'erc': int(fw_getenv('adu_erc') or 0),
            'error_text': fw_getenv('adu_error_text') or 'Unknown error',
            'workflow_id': fw_getenv('adu_workflow_id') or 'unknown'
        }
    return {'failed': False}

# Usage in ADU Agent
def process_deployment(deployment_data):
    current_workflow_id = deployment_data['workflow_id']
    
    # Check if this deployment already failed
    if should_skip_deployment(current_workflow_id):
        # Report as failed and return
        report_failure_to_azure(current_workflow_id)
        clear_error_flags()
        return False
    
    # Set workflow ID before applying update
    fw_setenv('adu_workflow_id', current_workflow_id)
    
    # Proceed with update...
    apply_update(deployment_data)
    return True

def clear_error_flags():
    """Clear error flags after reporting"""
    fw_setenv('adu_update_failed', '0')
    fw_setenv('adu_workflow_id', '')

# Example usage
rollback = check_rollback()
if rollback['failed']:
    print(f"Rollback detected: {rollback['error_text']}")
    print(f"Error codes: rc={rollback['rc']}, erc={rollback['erc']}")
    print(f"Failed workflow: {rollback['workflow_id']}")
    
    # Report to Azure IoT Hub here
    # ...
    
    # Clear flags after reporting
    subprocess.run(['fw_setenv', 'adu_update_failed', '0'])
```

## Clearing Error Flags

After successfully reporting the failure to Azure IoT Hub, clear the error flags:

```bash
# Clear failure flag
fw_setenv adu_update_failed 0

# Clear workflow ID (prevents false positives on future deployments)
fw_setenv adu_workflow_id ""

# Remove error details (optional, or set to empty string)
fw_setenv adu_rc ""
fw_setenv adu_erc ""
fw_setenv adu_error_text ""
```

**IMPORTANT:** 
- Always clear `adu_update_failed` AND `adu_workflow_id` after reporting
- If you don't clear `adu_workflow_id`, future deployments with same ID will be skipped
- Clear flags ONLY after successfully reporting to Azure (not before)

## Boot Flow with Error Reporting and Workflow ID Tracking

```
=== PRE-UPDATE: SWUpdate Handler ===
1. ADU agent receives deployment from Azure IoT Hub
   ├─ Deployment contains workflow_id (GUID)
   └─ ADU agent checks: should_skip_deployment(workflow_id)?
      ├─ Read adu_update_failed and adu_workflow_id from U-Boot env
      ├─ If adu_update_failed=1 AND adu_workflow_id == current workflow_id:
      │  ├─ This deployment already failed!
      │  ├─ Report failure to Azure (if not already done)
      │  ├─ Clear error flags
      │  └─ SKIP deployment (exit to prevent infinite loop)
      └─ Else: proceed with deployment

2. SWUpdate handler or ADU agent sets workflow ID BEFORE applying update
   ├─ fw_setenv adu_workflow_id "a1b2c3d4-..."
   └─ This ID will be preserved if rollback occurs

3. Update applied to alternate partition (rootA → rootB or vice versa)

=== BOOT AFTER UPDATE ===
4. U-Boot loads and runs boot script
   ├─ Load uboot.env (contains rpipart, have_updated, boot_attempts, adu_workflow_id)
   ├─ Check if have_updated=1 and boot_attempts=3
   │  └─ YES: ROLLBACK TRIGGERED
   │     ├─ Set adu_update_failed=1
   │     ├─ Set adu_rc=1, adu_erc=806355714
   │     ├─ Set adu_error_text="Update rollback: boot failed 3 times..."
   │     ├─ PRESERVE adu_workflow_id (don't clear, don't set)
   │     ├─ Clear have_updated=0
   │     ├─ Switch rpipart (2↔3)
   │     ├─ Reset boot_attempts=0
   │     └─ Save environment
   └─ Boot kernel on rolled-back partition

=== POST-ROLLBACK ===
5. System boots on old/working partition
   
6. Early boot service checks for rollback
   ├─ Read adu_update_failed flag
   ├─ If 1: Rollback detected
   │  └─ Read adu_workflow_id to identify failed deployment
   └─ Notify ADU agent

7. ADU agent starts (or rollback service notifies it)
   ├─ Read error details (adu_rc, adu_erc, adu_error_text, adu_workflow_id)
   ├─ Compare adu_workflow_id with current deployment (if any)
   │  └─ If match: Don't re-attempt (prevents infinite loop)
   ├─ Report failure to Azure IoT Hub
   └─ Clear error flags after successful report

8. Azure IoT Hub marks deployment as failed
   └─ Administrator can investigate logs and retry (with new workflow_id)

=== RETRY SCENARIO ===
9. Administrator deploys SAME update again (new workflow_id)
   ├─ ADU agent receives deployment with NEW workflow_id
   ├─ Checks: adu_workflow_id (old) != current workflow_id (new)
   ├─ Different IDs → Safe to retry
   └─ Proceeds with update attempt

10. Administrator deploys SAME update (SAME workflow_id - should not happen)
    ├─ ADU agent receives deployment with SAME workflow_id
    ├─ Checks: adu_workflow_id == current workflow_id AND adu_update_failed=1
    ├─ MATCH → This deployment already failed!
    └─ SKIP deployment, report as failed, prevent infinite loop
```

## Testing Rollback Error Reporting

### Simulate Rollback on Device

```bash
# 1. Set variables as if update was just applied
sudo fw_setenv rpipart 3          # Pretend we're on updated partition
sudo fw_setenv have_updated 1     # Update flag set
sudo fw_setenv boot_attempts 2    # Almost at limit
sudo fw_setenv adu_workflow_id "test-workflow-12345"  # Simulate workflow ID

# 2. Make the "new" partition unbootable (CAUTION!)
# Don't actually do this on production! For testing only:
# sudo mount /dev/mmcblk0p3 /mnt
# sudo rm /mnt/sbin/init
# sudo umount /mnt

# 3. Reboot - U-Boot will increment boot_attempts to 3 and trigger rollback
sudo reboot

# 4. After reboot (on rolled-back partition), check error variables
fw_printenv adu_update_failed    # Should be 1
fw_printenv adu_rc               # Should be 1
fw_printenv adu_erc              # Should be 806355714
fw_printenv adu_error_text       # Should show error message
fw_printenv adu_workflow_id      # Should be "test-workflow-12345" (preserved!)
fw_printenv rpipart              # Should be 2 (rolled back)
```

### Test Workflow ID Loop Prevention

```bash
# After simulating rollback above, test that re-deployment is prevented:

# 1. Simulate ADU agent checking before deployment
current_workflow="test-workflow-12345"  # Same as failed deployment
failed_workflow=$(fw_printenv -n adu_workflow_id)
update_failed=$(fw_printenv -n adu_update_failed)

if [ "$update_failed" = "1" ] && [ "$failed_workflow" = "$current_workflow" ]; then
    echo "SUCCESS: Loop prevention working! Deployment would be skipped."
else
    echo "FAIL: Loop prevention not working."
fi

# 2. Test with DIFFERENT workflow ID (should allow retry)
current_workflow="test-workflow-67890"  # Different workflow
if [ "$update_failed" = "1" ] && [ "$failed_workflow" = "$current_workflow" ]; then
    echo "FAIL: Should allow retry with different workflow ID"
else
    echo "SUCCESS: Different workflow ID allows retry."
fi
```

### Verify Error Reporting Script

```bash
# Run the helper script
/usr/bin/check-uboot-rollback.sh

# Expected output if rollback occurred:
# ==========================================
# ADU UPDATE ROLLBACK DETECTED
# ==========================================
# 
# Error Details:
#   Result Code (adu_rc): 1
#   Extended Code (adu_erc): 806355714
#   Error Text: Update rollback: boot failed 3 times on updated partition
#   Current Partition: 2
# ...
```

## Azure IoT Hub Reporting Format

When reporting to Azure IoT Hub, use the device twin reported properties:

```json
{
  "properties": {
    "reported": {
      "adu": {
        "lastUpdateResult": {
          "resultCode": 1,
          "extendedResultCode": 3,
          "resultDetails": "Update rollback: boot failed 3 times on updated partition",
          "stepResults": {
            "step_0": {
              "resultCode": 1,
              "extendedResultCode": 3,
              "resultDetails": "Boot validation failed after 3 attempts"
            }
          }
        },
        "state": 0  // Idle
      }
    }
  }
}
```

This allows the Azure IoT Hub to:
- Track failed deployments
- Show failure reasons in the portal
- Generate alerts for repeated failures
- Provide data for troubleshooting

## Best Practices

1. **Check early in boot**: Run rollback check before starting ADU agent
2. **Report promptly**: Send failure report to Azure as soon as detected
3. **Clear flags**: Always clear error flags after successful reporting
4. **Log locally**: Write to syslog/journal for local troubleshooting
5. **Retry logic**: If Azure report fails, retry with backoff
6. **Don't block boot**: Error reporting should be async, not block system startup

## Troubleshooting

**Q: Error flags not set after rollback?**
- Check if uboot.env exists: `ls -l /boot/uboot.env`
- Check if boot script has write permissions to boot partition
- Verify boot script is updated version with error reporting code

**Q: fw_printenv not found?**
- Install package: `apt-get install u-boot-tools` or `libubootenv-bin`
- Check if `/etc/fw_env.config` is properly configured

**Q: Error flags persist after clearing?**
- Verify saveenv is working: `fw_setenv test_var 123; fw_printenv test_var`
- Check boot partition is not read-only: `mount | grep /boot`
- Ensure sufficient permissions: running as root?

**Q: Azure report not working?**
- Check device connectivity: `ping google.com`
- Verify IoT Hub connection: check ADU agent logs
- Test with Azure CLI: `az iot hub device-twin show`

## Related Files

- [boot.cmd.in](./boot.cmd.in) - Normal boot script with error reporting
- [boot.cmd.in.debug](./boot.cmd.in.debug) - Debug version with verbose output
- [check-uboot-rollback.sh](./check-uboot-rollback.sh) - Helper script to check for rollback
- [README-PARTITION-COMPATIBILITY.md](../../../README-PARTITION-COMPATIBILITY.md) - Partition layout documentation
- [DEBUG-UBOOT-SCRIPT.md](../../../DEBUG-UBOOT-SCRIPT.md) - U-Boot debugging guide
