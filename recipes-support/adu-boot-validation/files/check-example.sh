#!/bin/bash
#
# Example Custom Boot Validation Check
#
# This is an example of a custom validation check that can be placed in
# /etc/adu/validation-checks.d/
#
# Exit codes:
#   0 - Check passed
#   1 - Check failed with warning (logged but doesn't block boot)
#   2 - Check failed critically (will cause boot validation failure)
#
# Output (stdout/stderr) will be captured and logged
#

# Example: Check if a custom application is running
check_custom_app() {
    local app_name="my-custom-app"
    
    if pgrep -x "$app_name" > /dev/null; then
        echo "Custom application '$app_name' is running"
        return 0
    else
        echo "Custom application '$app_name' is not running"
        return 1  # Warning only
    fi
}

# Example: Check if a custom configuration file exists
check_custom_config() {
    local config_file="/etc/my-app/config.ini"
    
    if [[ -f "$config_file" ]]; then
        echo "Custom configuration file exists"
        return 0
    else
        echo "Custom configuration file missing: $config_file"
        return 2  # Critical failure
    fi
}

# Example: Check if a hardware device is accessible
check_custom_hardware() {
    local device="/dev/spidev0.0"
    
    if [[ -e "$device" ]]; then
        echo "Hardware device $device is accessible"
        return 0
    else
        echo "Hardware device $device is not accessible"
        return 1  # Warning only
    fi
}

# Main function - run your checks here
main() {
    # Uncomment the checks you want to enable
    # check_custom_app || exit $?
    # check_custom_config || exit $?
    # check_custom_hardware || exit $?
    
    # By default, this example check passes
    echo "Example custom check passed (no checks enabled)"
    return 0
}

main "$@"
