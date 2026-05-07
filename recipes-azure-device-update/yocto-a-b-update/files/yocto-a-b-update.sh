#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Ensure that getopt starts from first option if ". <script.sh>" was used.
OPTIND=1

ret_val=1

# Ensure we dont end the user's terminal session if invoked from source (".").
if [[ $0 != "${BASH_SOURCE[0]}" ]]; then
    ret='return'
else
    ret='exit'
fi

# Output formatting.

# Log level: 0=debug, 1=info, 2=warning, 3=error, 4=none
log_level=0

warn() { echo -e "\033[1;33mWarning:\033[0m $*" >&2; }

error() { echo -e "\033[1;31mError:\033[0m $*" >&2; }

header() { echo -e "\e[4m\e[1m\e[1;32m$*\e[0m"; }

bullet() { echo -e "\e[1;34m*\e[0m $*"; }

warn "*************************************************"
warn "*                    WARNING                    *"
warn "*                                               *"
warn "* THIS FILE IS FOR DEMONSTRATION PURPOSES ONLY. *"
warn "* DO NOT USE THIS FOR YOUR REAL PRODUCT UPDATE! *"
warn "*                                               *"
warn "*************************************************"

# Log debug prefix - blue
log_debug_pref="\033[1;30m[D]\033[0m"

# Log info prefix - blue
log_info_pref="\033[1;34m[I]\033[0m"

# Log warning prefix - yellow
log_warn_pref="\033[1;33m[W]\033[0m"

# Log error prefix - red
log_error_pref="\033[1;31m[E]\033[0m"

#
# Files and Folders information
#
workfolder=
output_file=/adu/logs/swupdate.output
log_file=/adu/logs/swupdate.log
swupdate_log_file=/adu/logs/swupdate_log_file
result_file=/adu/logs/swupdate.result.json
blacklist_file=/var/lib/adu/states/failed_workflows.txt

#
# Following files are based on the how the Yocto Refererence Image was built.
# This value can be replaced in this script, or specify in import manifest (handlerProperties) as needed.
#
software_version_file="/etc/adu-version"
public_key_file="/adukey/public.pem"

#
# For install task, the --image-file <image_file_name> option must be specified.
#
image_file=""

#
# Device Update specific arguments
#
check_is_installed=
installed_criteria=
do_download_action=
do_install_action=
do_apply_action=
do_cancel_action=

restart_to_apply=
restart_agent_to_apply=

# Workflow ID for tracking and blacklist prevention
workflow_id=
custom_workflow_id=

#
# Remaining aguments and parameters
#
PARAMS=

#
# Output, Logs, and Result helper functions.
#
_timestamp=

# Partition variables - will be initialized after argument parsing
current_partition=""
update_partition=""
selection=""
current_dev_partition=0
update_dev_partition=0

# Shared lock file for U-Boot environment access
UBOOT_LOCK_FILE="/var/lock/adu-uboot-env.lock"
# State directory for update tracking
STATE_DIR="/var/lib/adu/states"
STATE_FILE="${STATE_DIR}/swupdate_state.json"

update_timestamp() {
    # See https://man7.org/linux/man-pages/man1/date.1.html
    _timestamp="$(date +'%Y/%m/%d:%H%M%S')"
}

log_debug() {
    if [ $log_level -gt 0 ]; then
        return
    fi
    log "$log_debug_pref" "$@"
}

log_info() {
    if [ $log_level -gt 1 ]; then
        return
    fi
    log "$log_info_pref" "$@"
}

log_warn() {
    if [ $log_level -gt 2 ]; then
        return
    fi
    log "$log_warn_pref" "$@"
}

log_error() {
    if [ $log_level -gt 3 ]; then
        return
    fi
    log "$log_error_pref" "$@"
}

log() {
    update_timestamp
    if [ -z "$log_file" ]; then
        echo -e "[$_timestamp]" "$@" >&1
    else
        echo "[$_timestamp]" "$@" >> "$log_file"
    fi
}

output() {
    update_timestamp
    if [ -z "$output_file" ]; then
        echo "[$_timestamp]" "$@" >&1
    else
        echo "[$_timestamp]" "$@" >> "$output_file"
    fi
}

result() {
    # NOTE: don't insert timestamp in result file.
    if [ -z "$result_file" ]; then
        echo "$@" >&1
    else
        echo "$@" > "$result_file"
    fi
}

#
# Helper function for creating extended result code that indicates
# errors from this script.
# Note: these error range (0x30101000 - 0x30101fff) a free to use.
#
# Usage: make_swupdate_handler_erc error_value result_variable result_details
#
# e.g.
#         error_value=20
#         erc=0
#         make_swupdate_handler_erc $error_value erc "$resultDetails"
#         echo $erc
#
#  (erc is 0x30101014)
#
make_swupdate_handler_erc() {
    local base_erc=0x30101000
    local -n res=$2 # name reference
    rd=$3
    res=$((base_erc + $1))
    log_debug "Generated SWUpdate handler extended result code: $res for error value: $1 with details: $rd"

}

# usage: make_aduc_result_json $resultCode $extendedResultCode $resultDetails <out param>
# shellcheck disable=SC2034
make_aduc_result_json() {
    local -n res=$4 # name reference
    res="{\"resultCode\":$1, \"extendedResultCode\":$2,\"resultDetails\":\"$3\"}"
}

# ============================================================================
# INFINITE UPDATE LOOP PREVENTION - Workflow Blacklist Check
# ============================================================================
# This mechanism prevents the same failed update from being retried infinitely:
#
# 1. When U-Boot detects boot failure (after max_boot_attempts, default 5),
#    it automatically rolls back to the previous partition
#
# 2. adu-boot-validation.sh (runs before ADU agent) detects the rollback by
#    comparing expected partition (from state file) to actual partition
#
# 3. The validator adds failed workflow_id to persistent file:
#    /var/lib/adu/states/failed_workflows.txt (on /adu overlay partition)
#    Format: workflow_id:timestamp:reason
#
# 4. This function checks the blacklist before download/install/apply actions
#    to reject known-bad updates early and save bandwidth/time
#
# 5. Additionally, partition flapping detection prevents rapid switching
#    between partitions (>3 switches in 10 minutes) by blacklisting the
#    workflow and forcing boot to last known good partition
#
# Result: Failed updates are permanently blacklisted and won't be retried,
# preventing infinite update loops even if ADU service keeps trying.
# ============================================================================
#
# Check if workflow is blacklisted (file-based on persistent /adu partition)
# Usage: CheckWorkflowBlacklist <workflow_id> <action_name>
# Returns: 0 if blacklisted (exits script), 1 if not blacklisted
#
CheckWorkflowBlacklist() {
    local check_workflow_id="$1"
    local action_name="$2"
    
    if [[ -z "$check_workflow_id" ]]; then
        log_warn "Cannot check blacklist: workflow_id is empty"
        return 1
    fi
    
    if [[ ! -f "$blacklist_file" ]]; then
        log_debug "Blacklist file does not exist, workflow not blacklisted"
        return 1
    fi
    
    # Read blacklist file and check for workflow_id
    # File format: workflow_id:timestamp:reason
    while IFS=: read -r failed_id timestamp reason; do
        if [[ "$failed_id" == "$check_workflow_id" ]]; then
            local resultCode=0
            local resultDetails="Workflow $check_workflow_id is blacklisted (reason: $reason at $timestamp). Update rejected to prevent infinite loop."
            local extendedResultCode=0
            make_swupdate_handler_erc $SWU_WORKFLOW_BLACKLISTED extendedResultCode "$resultDetails"
            
            log_error "$action_name BLOCKED: $resultDetails"
            
            local aduc_result=""
            make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
            output "Result:" "$aduc_result"
            result "$aduc_result"
            
            $ret 1
        fi
    done < "$blacklist_file"
    
    log_debug "Workflow $check_workflow_id not in blacklist"
    return 1
}

#
# Helper function to set U-Boot environment variables with logging and error handling.
# Usage: SetUBootEnv <varname> <value> <out ret_val>
#
# shellcheck disable=SC2034
SetUBootEnv() {
    local varname="$1"
    local value="$2"
    local -n retval=$3  # name reference for return value

    log_debug "Setting U-Boot env: $varname=$value"
    (
        flock -x 200
        fw_setenv "$varname" "$value"
    ) 200>"$UBOOT_LOCK_FILE"
    retval=$?

    if [[ $retval -ne 0 ]]; then
        log_error "Failed to set U-Boot env variable '$varname' to '$value' (exit code: $retval)"
    fi

    return $retval
}

#
# Initialize partition detection by reading from U-Boot environment.
# This must be called after argument parsing so result_file is available.
# Returns 0 on success, 1 on failure (with ADUC result written if possible)
#
initialize_partitions() {
    # SWUpdate doesn't support everything necessary for the dual-copy or A/B update strategy.
    # Read the current boot partition from U-Boot environment (set by boot.cmd.in) to determine
    # which partition to update. This avoids hardcoded partition paths and ensures consistency
    # with the bootloader's view of the system.
    # CRITICAL: Fail fast if boot_partition is not set - do not assume a default partition.
    current_partition=$(fw_printenv -n boot_partition 2>/dev/null)

    if [[ -z "$current_partition" ]]; then
        local resultCode=0
        local extendedResultCode=0
        local resultDetails="CRITICAL: boot_partition not found in U-Boot environment. Cannot determine current partition. This is required for safe A/B updates. Check U-Boot configuration."
        local aduc_result=""

        make_swupdate_handler_erc $SWU_FAILED_READ_BOOT_PARTITION extendedResultCode "$resultDetails"
        make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result

        # Write error to output and result files
        output "Result:" "$aduc_result"
        result "$aduc_result"

        error "$resultDetails"
        return 1
    fi

    if [[ $current_partition == "rootA" ]]; then
        selection="stable,copy2"
        update_partition="rootB"
        current_dev_partition=2
        update_dev_partition=3
    else
        selection="stable,copy1"
        update_partition="rootA"
        current_dev_partition=3
        update_dev_partition=2
    fi

    log_info "Partition detection: current=$current_partition, update=$update_partition"
    
    # Safety check: verify U-Boot boot_partition matches actual root partition
    local actual_root=""
    if grep -q "root=/dev/mmcblk0p2" /proc/cmdline 2>/dev/null; then
        actual_root="rootA"
    elif grep -q "root=/dev/mmcblk0p3" /proc/cmdline 2>/dev/null; then
        actual_root="rootB"
    fi
    
    if [[ -n "$actual_root" && "$actual_root" != "$current_partition" ]]; then
        log_warn "WARNING: U-Boot boot_partition ($current_partition) does not match actual root ($actual_root)"
        log_warn "Using actual root partition to prevent overwriting active rootfs"
        current_partition="$actual_root"
        if [[ $current_partition == "rootA" ]]; then
            selection="stable,copy2"
            update_partition="rootB"
            current_dev_partition=2
            update_dev_partition=3
        else
            selection="stable,copy1"
            update_partition="rootA"
            current_dev_partition=3
            update_dev_partition=2
        fi
    fi
    
    return 0
}

#
# Usage
#
print_help() {
    echo ""
    echo "Usage: <script-file-name>.sh [options...]"
    echo ""
    echo ""
    echo "Device Update reserved argument"
    echo "==============================="
    echo ""
    echo "--action <ACTION>                         Perform specified 'ACTION'."
    echo "                                          Where ACTION is one of the following:"
    echo "                                              is-installed, download, install, apply,"
    echo "                                              cancel, backup, restore."
    echo ""
    echo "--action-is-installed                     Perform 'is-installed' check."
    echo "                                          Check whether the selected component [or primary device] current states"
    echo "                                          satisfies specified 'installedCriteria' data."
    echo "--installed-criteria                      Specify the Installed-Criteria string."
    echo "--workflow-id                             Specify the workflow ID for tracking and blacklist prevention."
    echo "--custom-workflow-id                      Specify a custom workflow ID to use if the primary workflow ID is empty."
    echo ""
    echo "--action-download                         Perform 'download' action."
    echo "--action-install                          Perform 'install' action."
    echo "--action-apply                            Perform 'apply' action."
    echo "--action-cancel                           Perform 'cancel' action."
    echo ""
    echo "--restart-to-apply                        Request the host device to restart when applying update to this component."
    echo "--restart-agent-to-apply                  Request the DU Agent to restart when applying update to this component."
    echo ""
    echo "File and Folder information"
    echo "==========================="
    echo ""
    echo "--work-folder             A work-folder (or sandbox folder)."
    echo "--swu-file, --image-file  An image file (.swu) file to install."
    echo "--output-file             An output file."
    echo "--log-file                A log file."
    echo "--swupdate-log-file       A file contains output from swupdate tool."
    echo "--result-file             A file contain ADUC_Result data (in JSON format)."
    echo "--software-version-file   A file contain image version number."
    echo "--public-key-file         A public key file for signature validateion."
    echo "                          See InstallUpdate() function for more details."
    echo ""
    echo "--log-level <0-4>         A minimum log level. 0=debug, 1=info, 2=warning, 3=error, 4=none."
    echo "-h, --help                Show this help message."
    echo ""
    echo "Example:"
    echo ""
    echo "Scenario: is-installed check"
    echo "========================================"
    echo "    <script> --log-level 0 --action-is-installed --intalled-criteria 1.0"
    echo ""
    echo "Scenario: perform install action"
    echo "================================"
    echo "    <script> --log-level 0 --action-install --intalled-criteria 1.0 --swu-file example-device-update.swu --work-folder <sandbox-folder>"
    echo ""
}

log "Log begin:"
output "Output begin:"

#
# Custom error codes for this script. See make_swupdate_handler_erc() function.
#
SWU_INTERNAL_ERROR=500
SWU_SWUPDATE_COMMAND_FAILED=502

SWU_FAILED_READ_BOOT_PARTITION=10

SWU_FAILED_SET_UPGRADE_AVAILABLE=20
SWU_FAILED_SET_BOOT_ATTEMPTS=21
SWU_FAILED_SET_BOOT_RESULT=22
SWU_FAILED_SET_BOOT_PARTITION=23
SWU_FAILED_SET_WORKFLOW_ID=24
SWU_FAILED_SET_UPDATE_ID=25

SWU_INSTALLED_CRITERIA_EMPTY=101
SWU_WORKFLOW_BLACKLISTED=106

SWU_IMAGE_VERSION_FILE_EMPTY=100
SWU_IMAGE_VERSION_FILE_NOT_FOUND=102
SWU_IMAGE_VERSION_FILE_NOT_READABLE=103
SWU_IMAGE_VERSION_FILE_READ_ERROR=104

SWU_ARGUMENT_PARSE_ERROR=200
SWU_MISSING_REQUIRED_ARGUMENT=201
SWU_CRITICAL_NO_RESULT_FILE=202

#
# Array to accumulate argument parsing errors
# We can't exit immediately during parsing because we need result_file location
#
declare -a PARSE_ERRORS=()

#
# Helper function to add parsing error (deferred until we have result_file)
#
add_parse_error() {
    PARSE_ERRORS+=("$1")
}

#
# Trap handler to ensure result file is written on unexpected exit
# This catches signals (SIGTERM, SIGINT, etc.) and unexpected errors
#
trap_exit_handler() {
    local exit_code=$?
    
    # Only write trap result if:
    # 1. We have a result_file
    # 2. Exit code is non-zero (indicates error)
    # 3. Result file is empty or contains only the "in progress" message
    if [[ -n "$result_file" && $exit_code -ne 0 && -f "$result_file" ]]; then
        # Check if result file still has "in progress" message
        if grep -q '"Script execution in progress' "$result_file" 2>/dev/null; then
            local resultCode=0
            local extendedResultCode=0
            local resultDetails="Script terminated unexpectedly (exit code: $exit_code)"
            local aduc_result=""
            
            make_swupdate_handler_erc $SWU_INTERNAL_ERROR extendedResultCode "$resultDetails"
            make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
            
            result "$aduc_result"
            log_error "$resultDetails"
        fi
    fi
}

# Register trap handler for EXIT signal (catches all exits including errors and signals)
trap trap_exit_handler EXIT

#
# Finalize argument parsing and handle any accumulated errors
# This runs AFTER parsing completes so we know if result_file was provided
#
finalize_argument_parsing() {
    local has_errors=0
    local error_details=""

    # Check for accumulated parsing errors
    if [[ ${#PARSE_ERRORS[@]} -gt 0 ]]; then
        has_errors=1
        error_details="Argument parsing errors:\n"
        for err in "${PARSE_ERRORS[@]}"; do
            error_details+="  - $err\n"
        done
    fi

    # Check for missing required arguments
    # Note: result_file should always be provided by the handler
    if [[ -z "$result_file" ]]; then
        has_errors=1
        error_details+="CRITICAL: --result-file is required but was not provided.\n"
    fi

    # If no errors, return success
    if [[ $has_errors -eq 0 ]]; then
        return 0
    fi

    # We have errors - determine how to report them
    if [[ -n "$result_file" ]]; then
        # We have result_file - write error there and exit 1
        local resultCode=0
        local extendedResultCode=0
        local aduc_result=""

        # Strip trailing newline for JSON
        error_details="${error_details%\\n}"
        make_swupdate_handler_erc $SWU_ARGUMENT_PARSE_ERROR extendedResultCode "$error_details"
        make_aduc_result_json "$resultCode" "$extendedResultCode" "$error_details" aduc_result

        result "$aduc_result"

        if [[ -n "$output_file" ]]; then
            output "Result:" "$aduc_result"
        fi

        error "$error_details"
        $ret 1
    else
        # CRITICAL: No result_file - log to special location for diagnostics
        local critical_log_dir="/var/log/adu"
        local critical_log_file="${critical_log_dir}/CRITICAL_SCRIPT_FAILURE_$(date +%Y%m%d_%H%M%S).log"

        # Try to create log directory
        mkdir -p "$critical_log_dir" 2>/dev/null || true

        # Write to critical log file
        if [[ -w "$critical_log_dir" ]] || mkdir -p "$critical_log_dir" 2>/dev/null; then
            {
                echo "========================================"
                echo "CRITICAL SCRIPT FAILURE"
                echo "Timestamp: $(date +'%Y-%m-%d %H:%M:%S')"
                echo "Script: $0"
                echo "========================================"
                echo ""
                echo -e "$error_details"
                echo ""
                echo "This failure occurred because result_file was not provided."
                echo "The SWUpdate Handler should always provide --result-file argument."
                echo "========================================"
            } > "$critical_log_file" 2>/dev/null

            error "CRITICAL: Argument parsing failed and no result_file available."
            error "Error details logged to: $critical_log_file"
        else
            error "CRITICAL: Argument parsing failed and cannot write to $critical_log_dir"
        fi

        # Write errors to stderr for immediate visibility
        echo -e "\n$error_details" >&2

        # Exit with special code 2 for critical configuration failure
        $ret 2
    fi
}

#
# Parsing arguments
#
while [[ $1 != "" ]]; do
    case $1 in

    #
    # Device Update specific arguments.
    #
    --action)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--action requires an action parameter."
            continue
        fi
        action=$1
        shift
        case $action in
        is-installed)
            check_is_installed=yes
            ;;
        download)
            do_download_action=yes
            ;;
        install)
            do_install_action=yes
            ;;
        apply)
            do_apply_action=yes
            ;;
        cancel)
            do_cancel_action=yes
            ;;
        *)
            add_parse_error "Unknown action: $action"
            ;;
        esac
        ;;
    --action-download)
        shift
        do_download_action=yes
        ;;

    --action-install)
        shift
        log_info "Will runscript as 'installer' script."
        do_install_action=yes
        ;;

    --action-apply)
        shift
        do_apply_action=yes
        ;;

    --restart-to-apply)
        shift
        restart_to_apply=yes
        ;;

    --restart-agent-to-apply)
        shift
        restart_agent_to_apply=yes
        ;;

    --action-cancel)
        shift
        do_cancel_action=yes
        ;;

    --action-is-installed)
        shift
        check_is_installed=yes
        ;;

    --installed-criteria)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--installed-criteria requires an installedCriteria parameter."
            continue
        fi
        installed_criteria="$1"
        shift
        ;;

    --workflow-id)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--workflow-id requires a workflow ID parameter."
            continue
        fi
        workflow_id="$1"
        shift
        ;;

    --custom-workflow-id)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--custom-workflow-id requires a custom workflow ID parameter."
            continue
        fi
        custom_workflow_id="$1"
        shift
        ;;

    #
    # Update artifacts
    #
    --swu-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--swu-file parameter is mandatory."
            continue
        fi
        image_file="$1"
        echo "swu file (image_file): $image_file"
        shift
        ;;

    --work-folder)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--work-folder parameter is mandatory."
            continue
        fi
        workfolder="$1"
        echo "work folder: $workfolder"
        shift
        ;;

    #
    # Output-related arguments.
    #
    # --out-file <file_path>, --result-file <file_path>, --log-file <file_path>
    #
    --output-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--output-file parameter is mandatory."
            continue
        fi
        output_file="$1"

        #
        #Create output file path.
        #
        # Delete existing log.
        rm -f -r "$output_file"
        # Create dir(s) recursively (include filename, well remove it in the following line...).
        mkdir -p "$output_file"
        # Delete leaf-dir (w)
        rm -f -r "$output_file"

        shift
        ;;

    --result-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--result-file parameter is mandatory."
            continue
        fi
        result_file="$1"
        #
        #Create result file path.
        #
        # Delete existing log.
        rm -f -r "$result_file"
        # Create dir(s) recursively (include filename, well remove it in the following line...).
        mkdir -p "$result_file"
        # Delete leaf-dir (w)
        rm -f -r "$result_file"
        shift
        ;;

    --software-version-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--software-version-file parameter is mandatory."
            continue
        fi
        software_version_file="$1"
        shift
        ;;

    --image-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--image-file parameter is mandatory."
            continue
        fi
        image_file="$1"
        shift
        ;;

    --public-key-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--public-key-file parameter is mandatory."
            continue
        fi
        public_key_file="$1"
        shift
        ;;

    --log-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--log-file parameter is mandatory."
            continue
        fi
        log_file="$1"
        shift
        ;;

    --swupdate-log-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--swupdate-log-file parameter is mandatory."
            continue
        fi
        swupdate_log_file="$1"
        shift
        ;;

    --log-level)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            add_parse_error "--log-level parameter is mandatory."
            continue
        fi
        log_level=$1
        shift
        ;;

    -h | --help)
        print_help
        $ret 0
        ;;

    *) # preserve positional arguments
        PARAMS="$PARAMS $1"
        shift
        ;;
    esac
done

#
# Finalize argument parsing - check for errors and required arguments
# This must run AFTER parsing completes so we know if result_file was provided
#
finalize_argument_parsing

#
# Device Update related functions.
#

#
# A helper function that evaluates whether an update is currently installed on the target,
# based on 'installedCriteria'.
#
# Usage: is_installed $installedCriteria $imageVersionFile <out resultCode> <out extendedResultCode> <out resultDetails>
#
# shellcheck disable=SC2034
function is_installed() {
    local -n rc=$3  # name reference for resultCode
    local -n erc=$4 # name reference for extendedResultCode
    local -n rd=$5  # name reference for resultDetails

    # Validate inputs
    if [[ -z "$1" ]]; then
        rc=0
        rd="Installed criteria is empty."
        make_swupdate_handler_erc $SWU_INSTALLED_CRITERIA_EMPTY erc "$rd"
        return 0
    fi

    if [[ -z "$2" ]]; then
        rc=0
        rd="Image version file path is empty."
        make_swupdate_handler_erc $SWU_IMAGE_VERSION_FILE_EMPTY erc "$rd"
        return 0
    fi

    if ! [[ -f "$2" ]]; then
        rc=0
        rd="Image version file not found: $2"
        make_swupdate_handler_erc $SWU_IMAGE_VERSION_FILE_NOT_FOUND erc "$rd"
        return 0
    fi

    # Check if file is readable
    if ! [[ -r "$2" ]]; then
        rc=0
        rd="Image version file not readable: $2"
        make_swupdate_handler_erc $SWU_IMAGE_VERSION_FILE_NOT_READABLE erc "$rd"
        return 0
    fi

    # Attempt to read and match the version
    # Redirect stderr to suppress grep error messages
    if grep -q "^$1$" "$2" 2>/dev/null; then
        # Version matches - installed
        rc=900
        erc=0
        rd=""
    else
        # Check grep exit code to distinguish between "not found" vs "error"
        grep_exit=$?
        if [[ $grep_exit -eq 1 ]]; then
            # Exit code 1 = no match found (not installed)
            rc=901
            erc=0
            rd=""
        else
            # Exit code 2+ = error occurred (file I/O error, invalid regex, etc.)
            rc=0
            rd="Error reading version file: $2 (grep exit code: $grep_exit)"
            make_swupdate_handler_erc $SWU_IMAGE_VERSION_FILE_READ_ERROR erc "$rd"
        fi
    fi
}

#
# Example implementation of 'IsInstalled' function, for the reference Yocto Image.
#
# Design Goal:
#   Determine whether the specified 'installedCriteria' (parameter $1) is met.
#
#   'installedCriteria' is a version number of the image (generated by DU Yocto internal build pipeline).
#   This version is saved in $software_version_file.
#
# Expected resultCode:
#     ADUC_Result_Failure = 0,
#     ADUC_Result_IsInstalled_Installed = 900,     /**< Succeeded and content is installed. */
#     ADUC_Result_IsInstalled_NotInstalled = 901,  /**< Succeeded and content is not installed */
#
CheckIsInstalledState() {
    log_info "IsInstalledTask(\"$1\"), adu-version path:\"$software_version_file\""

    local local_rc=2
    local local_erc=3
    local local_rd="4"
    local aduc_result=""

    # Evaluates installedCriteria string.
    is_installed "$1" "$software_version_file" local_rc local_erc local_rd

    make_aduc_result_json "$local_rc" "$local_erc" "$local_rd" aduc_result

    # Show output.
    output "Result:" "$aduc_result"

    # Write ADUC_Result to result file.
    result "$aduc_result"
}

#
# Example implementation of 'DownloadUpdateArtifacts' function, for the reference Yocto Image.
#
# This fuction is no-op since no additional files are required for this update.
#
DownloadUpdateArtifacts() {
    log_info "DownloadUpdateArtifacts called"

    # Check blacklist early to save bandwidth
    if [[ -n "$workflow_id" ]]; then
        CheckWorkflowBlacklist "$workflow_id" "Download"
    fi

    local aduc_result=""

    # Return ADUC_Result_Download_Success (500), no extended result code, no result details.
    make_aduc_result_json 500 0 "" aduc_result

    # Show output.
    output "Result:" "$aduc_result"

    # Write ADUC_Result to result file.
    result "$aduc_result"

    $ret $ret_val
}

#
# InstallUpdate:
# Copies a 'firmware.json' to component's folder (properties.path).
#
InstallUpdate() {
    log_info "InstallUpdate called"

    # Validate workflow_id for tracking (optional for install, required for apply)
    if [[ -z "$workflow_id" && -n "$custom_workflow_id" ]]; then
        workflow_id="$custom_workflow_id"
        log_info "Using custom workflow_id for Install: $workflow_id"
    fi

    # Check blacklist early to avoid unnecessary work
    if [[ -n "$workflow_id" ]]; then
        CheckWorkflowBlacklist "$workflow_id" "Install"
    else
        log_warn "workflow_id not provided for Install action - blacklist check skipped"
    fi

    resultCode=0
    extendedResultCode=0
    resultDetails=""
    ret_val=1

    #
    # Note: we could simulate 'component off-line' scenario here.
    #

    # Check whether the component is already installed the specified update...
    log_info "Checking whether the update is already installed..."
    is_installed "$installed_criteria" "$software_version_file" resultCode extendedResultCode resultDetails

    is_installed_ret=$?

    if [[ $is_installed_ret -ne 0 ]]; then
        # is_installed function failed to execute.
        resultCode=0
        resultDetails="Internal error in 'is_installed' function (rv=$is_installed_ret)."
        make_swupdate_handler_erc $SWU_INTERNAL_ERROR extendedResultCode "$resultDetails"
    elif [[ $resultCode == 0 ]]; then
        # Failed to determine whether the update has been installed or not.
        # Return current ADUC_Result
        echo "Failed to determine whether the update has been installed or not." >> "${log_file}"
    elif [[ $resultCode -eq 901 ]]; then
        # Not installed.

        # install an update.
        echo "Installing update..." >> "${log_file}"
        if [[ -f $image_file ]]; then

            # Note: Swupdate can use a public key to validate the signature of an image.
            #
            # Here is how we generated the private key for signing the image
            # and how we generated that public key file used to validate the image signature.
            #
            # Generated RSA private key with password using command:
            # openssl genrsa -aes256 -passout file:priv.pass -out priv.pem
            #
            # Generated RSA public key from private key using command:
            # openssl rsa -in ${WORKDIR}/priv.pem -out ${WORKDIR}/public.pem -outform PEM -pubout

            ret_val=1
            if [[ -z "${public_key_file}" ]]; then
                # Call swupdate with the image file and no signature validations
                swupdate -v -i "${image_file}" -e ${selection} &>> "${swupdate_log_file}"
                ret_val=$?
            else
                # Call swupdate with the image file and the public key for signature validation
                swupdate -v -i "${image_file}" -k "${public_key_file}" -e ${selection} &>> "${swupdate_log_file}"
                ret_val=$?
            fi

            if [[ $ret_val -eq 0 ]]; then
                resultCode=600
                extendedResultCode=0
                resultDetails=""
            else
                resultCode=0
                resultDetails="SWUpdate command failed. (rv=$ret_val)"
                make_swupdate_handler_erc $SWU_SWUPDATE_COMMAND_FAILED extendedResultCode "$resultDetails"
            fi
        else
            echo "Image file ${image_file} was not found." >> "${log_file}"
            resultCode=0
            # ADUC_ERC_SWUPDATE_HANDLER_INSTALL_FAILURE_IMAGE_FILE_NOT_FOUND (0x202)
            extendedResultCode=0x30100202
            resultDetails="Image file ${image_file} was not found."
        fi
        ret_val=0
    else
        # Installed.
        log_info "It appears that this component already installed the specified update."
        resultCode=603
        extendedResultCode=0
        resultDetails="Already installed. No action taken."
        ret_val=0
    fi

    # Prepare ADUC_Result json.
    make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result

    # Show output.
    output "Result:" "$aduc_result"

    # Write ADUC_Result to result file.
    result "$aduc_result"

    $ret $ret_val
}

#
# Performs steps to finalize the update.
#
ApplyUpdate() {
    log_info "Applying update..."

    ret_val=0
    resultCode=0
    extendedResultCode=0
    resultDetails=""

    echo "Applying." >> "${log_file}"

    # Validate workflow_id is provided

    # Fall back to custom workflow_id if workflow_id is empty
    if [[ -z "$workflow_id" && -n "$custom_workflow_id" ]]; then
        workflow_id="$custom_workflow_id"
        log_warn "Warning: workflow_id is empty. Using custom workflow_id: $workflow_id"
    fi

    if [[ -z "$workflow_id" ]]; then
        resultCode=0
        resultDetails="workflow_id is required for apply action"
        make_swupdate_handler_erc $SWU_ARGUMENT_PARSE_ERROR extendedResultCode "$resultDetails"
        log_error "$resultDetails"
        make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
        output "Result:" "$aduc_result"
        result "$aduc_result"
        $ret 1
    fi

    # Check if workflow is blacklisted (see CheckWorkflowBlacklist function for details)
    CheckWorkflowBlacklist "$workflow_id" "Apply"

    # Write update state file BEFORE switching boot partition
    # This is critical for rollback detection: adu-boot-validation.sh reads this file
    # to determine if a rollback occurred (expected partition != actual partition)
    log_info "Writing update state file: $STATE_FILE"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    
    # Atomic write: write to temp file, sync, rename
    local state_content="{
  \"update_phase\": \"applied_pending_validation\",
  \"workflow_id\": \"$workflow_id\",
  \"target_partition\": \"$update_partition\",
  \"previous_partition\": \"$current_partition\",
  \"installed_criteria\": \"${installed_criteria:-}\",
  \"timestamp\": \"$(date -Iseconds)\"
}"
    
    if echo "$state_content" > "${STATE_FILE}.tmp" 2>/dev/null; then
        sync "${STATE_FILE}.tmp" 2>/dev/null || true
        mv "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null || true
        sync "$STATE_FILE" 2>/dev/null || true
        sync "$STATE_DIR" 2>/dev/null || true
        log_info "State file written successfully"
    else
        log_warn "Failed to write state file (non-fatal, rollback detection may not work)"
    fi

    # Set the bootloader environment variables
    # to tell the bootloader to boot into the new partition.
    #
    # boot_partition, upgrade_available, boot_attempts, and boot_result are used by boot.cmd.in
    # Note: last_known_good_partition is managed by boot verification service, not by this script
    SetUBootEnv upgrade_available 1 ret_val
    if [[ $ret_val -ne 0 ]]; then
        resultCode=0
        resultDetails="Failed to set upgrade_available (rv=$ret_val)"
        make_swupdate_handler_erc $SWU_FAILED_SET_UPGRADE_AVAILABLE extendedResultCode "$resultDetails"
        log_error "$resultDetails"
        make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
        output "Result:" "$aduc_result"
        result "$aduc_result"
        $ret $ret_val
    fi

    SetUBootEnv boot_attempts 0 ret_val
    if [[ $ret_val -ne 0 ]]; then
        resultCode=0
        resultDetails="Failed to set boot_attempts (rv=$ret_val)"
        make_swupdate_handler_erc $SWU_FAILED_SET_BOOT_ATTEMPTS extendedResultCode "$resultDetails"
        log_error "$resultDetails"
        make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
        output "Result:" "$aduc_result"
        result "$aduc_result"
        $ret $ret_val
    fi

    SetUBootEnv boot_result "unknown" ret_val
    if [[ $ret_val -ne 0 ]]; then
        resultCode=0
        resultDetails="Failed to set boot_result (rv=$ret_val)"
        make_swupdate_handler_erc $SWU_FAILED_SET_BOOT_RESULT extendedResultCode "$resultDetails"
        log_error "$resultDetails"
        make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
        output "Result:" "$aduc_result"
        result "$aduc_result"
        $ret $ret_val
    fi

    # Track workflow ID for the partition being updated
    SetUBootEnv "partition_${update_partition}_workflow_id" "$workflow_id" ret_val
    if [[ $ret_val -ne 0 ]]; then
        resultCode=0
        resultDetails="Failed to set partition workflow_id (rv=$ret_val)"
        make_swupdate_handler_erc $SWU_FAILED_SET_WORKFLOW_ID extendedResultCode "$resultDetails"
        log_error "$resultDetails"
        make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
        output "Result:" "$aduc_result"
        result "$aduc_result"
        $ret $ret_val
    fi

    # Track current update in progress
    SetUBootEnv "update_in_progress_id" "$workflow_id" ret_val
    if [[ $ret_val -ne 0 ]]; then
        resultCode=0
        resultDetails="Failed to set update_in_progress_id (rv=$ret_val)"
        make_swupdate_handler_erc $SWU_FAILED_SET_UPDATE_ID extendedResultCode "$resultDetails"
        log_error "$resultDetails"
        make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
        output "Result:" "$aduc_result"
        result "$aduc_result"
        $ret $ret_val
    fi

    # Track version on partition (optional, non-fatal)
    if [[ -n "$installed_criteria" ]]; then
        SetUBootEnv "partition_${update_partition}_version" "$installed_criteria" ret_val
        if [[ $ret_val -ne 0 ]]; then
            log_warn "Failed to set partition version (non-fatal)"
        fi
    fi

    # Switch boot partition last
    SetUBootEnv boot_partition "$update_partition" ret_val

    if [[ $ret_val -eq 0 ]]; then

        log_info "restart_to_apply=$restart_to_apply"
        log_info "restart_agent_to_apply=$restart_agent_to_apply"

        if [[ ${restart_to_apply} == "yes" ]]; then
            log_info "Returning ADUC_Result_Apply_RequiredImmediateReboot(705)"
            resultCode=705
        elif [[ ${restart_agent_to_apply} == "yes" ]]; then
            log_info "Returning ADUC_Result_Apply_RequiredImmediateAgentRestart(707)"
            resultCode=707
        else
            log_info "Returning ADUC_Result_Apply_Success(700)"
            resultCode=700
        fi
        extendedResultCode=0
        resultDetails=""
    else
        resultCode=0
        resultDetails="Cannot set boot_partition value to $update_partition"
        make_swupdate_handler_erc $SWU_FAILED_SET_BOOT_PARTITION extendedResultCode "$resultDetails"
        log_error "$resultDetails"
    fi

    # Prepare ADUC_Result json.
    aduc_result=""
    make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result

    # Show output.
    output "Result:" "$aduc_result"

    # Write ADUC_Result to result file.
    result "$aduc_result"

    # Return success if resultCode indicates success (700, 705, 707), otherwise failure
    if [[ $resultCode -ge 700 && $resultCode -le 799 ]]; then
        $ret 0
    else
        $ret 1
    fi
}

#
# Cancel current update.
#
# Set the bootloader environment variable to tell the bootloader to boot into the current partition
# instead of the one that was updated. Note: rpipart variable is specific to our boot.scr script.
#
CancelUpdate() {
    log_info "CancelUpdate called"

    # Set the bootloader environment variables
    # to tell the bootloader to boot into the last known good partition.
    # boot_partition, upgrade_available, and boot_attempts are used by boot.cmd.in
    echo "Cancelling update." >> "${log_file}"
    resultCode=0
    extendedResultCode=0
    resultDetails=""
    ret_val=

    # Read last_known_good_partition from U-Boot environment
    # This variable is managed by the boot verification service (adu-boot-validation.sh)
    # which sets it after successful boot validation
    local lkg_partition
    lkg_partition=$(fw_printenv -n last_known_good_partition 2>/dev/null)
    if [[ -z "$lkg_partition" ]]; then
        log_error "============================================================"
        log_error "WARNING: last_known_good_partition NOT SET in U-Boot env!"
        log_error "Boot verification service should have set this variable."
        log_error "Falling back to 'rootA' (default first partition)."
        log_error "============================================================"
        warn "CRITICAL: last_known_good_partition missing from U-Boot environment!"
        warn "Defaulting to rootA for cancel operation."
        lkg_partition="rootA"
    fi

    log_info "Reverting to last known good partition: $lkg_partition"

    echo "Revert update." >> "${log_file}"
    SetUBootEnv boot_partition "$lkg_partition" ret_val
    if [[ $ret_val -ne 0 ]]; then
        resultCode=801
        resultDetails="Failed to set boot_partition to ${lkg_partition} (rv=$ret_val)"
        make_swupdate_handler_erc "$ret_val" extendedResultCode "$resultDetails"
        make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
        output "Result:" "$aduc_result"
        result "$aduc_result"
        $ret $ret_val
    fi

    SetUBootEnv upgrade_available 0 ret_val
    if [[ $ret_val -ne 0 ]]; then
        resultCode=801
        resultDetails="Failed to set upgrade_available to 0 (rv=$ret_val)"
        make_swupdate_handler_erc "$ret_val" extendedResultCode "$resultDetails"
        make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
        output "Result:" "$aduc_result"
        result "$aduc_result"
        $ret $ret_val
    fi

    SetUBootEnv boot_attempts 0 ret_val
    if [[ $ret_val -ne 0 ]]; then
        resultCode=801
        resultDetails="Failed to set boot_attempts to 0 (rv=$ret_val)"
        make_swupdate_handler_erc "$ret_val" extendedResultCode "$resultDetails"
        make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
        output "Result:" "$aduc_result"
        result "$aduc_result"
        $ret $ret_val
    fi

    # Clear update in progress (non-fatal)
    SetUBootEnv update_in_progress_id "" ret_val
    if [[ $ret_val -ne 0 ]]; then
        log_warn "Failed to clear update_in_progress_id (non-fatal)"
        # Don't fail cancel if this doesn't work
    fi

    # If we reached here, all critical operations succeeded
    resultCode=800
    extendedResultCode=0
    resultDetails=""

    make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result

    # Show output.
    output "Result:" "$aduc_result"

    # Write ADUC_Result to result file.
    result "$aduc_result"

    $ret 0
}

#
# Main Entry Point
#
# This section executes a SINGLE action based on the --action argument passed by the SWUpdate Handler.
# Once the action completes, the script will exit immediately.
#
# CRITICAL: Each action MUST write its final result to the designated result file ($result_file).
# This result is read by the SWUpdate Handler to determine success/failure.
#
# To handle cases where the script may terminate unexpectedly (crash, kill signal, etc.),
# we write an initial "in progress" result before executing any action. If the script
# completes normally, this will be overwritten with the actual result.
#

# Write initial "in progress" state to result file
# This ensures the handler knows the script started, even if it crashes before completing
initial_result=""
make_aduc_result_json 0 0 "Script execution in progress..." initial_result
result "$initial_result"
log_info "Initialized result file with in-progress state"


if [ -n "$check_is_installed" ]; then
    CheckIsInstalledState "$installed_criteria"
    exit $ret_val
fi

if [ -n "$do_download_action" ]; then
    DownloadUpdateArtifacts
    exit $ret_val
fi

# Initialize partition detection before any operation that needs it
if [ -n "$do_install_action" ] || [ -n "$do_apply_action" ] || [ -n "$do_cancel_action" ]; then
    if ! initialize_partitions; then
        exit 1
    fi
fi

if [ -n "$do_install_action" ]; then
    InstallUpdate
    exit $ret_val
fi

if [ -n "$do_apply_action" ]; then
    ApplyUpdate
    exit $ret_val
fi

if [ -n "$do_cancel_action" ]; then
    CancelUpdate
    exit $ret_val
fi

# Fallthrough case: no valid action was specified
# This should not happen if the handler invokes the script correctly
log_error "No valid action specified. Use --action or --action-<name> argument."
resultCode=0
extendedResultCode=0
resultDetails="No action specified. Expected one of: is-installed, download, install, apply, cancel"
make_swupdate_handler_erc $SWU_MISSING_REQUIRED_ARGUMENT extendedResultCode "$resultDetails"
make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result
output "Result:" "$aduc_result"
result "$aduc_result"

$ret 1
