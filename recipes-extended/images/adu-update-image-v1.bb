# ADU SWUpdate Image - Version 1 (baseline)
# This is the baseline update image for delta generation testing
# Version can be overridden via BASE_ADU_SOFTWARE_VERSION variable (e.g., from CI/CD)

# Include common configuration shared by all versioned update images
require adu-update-image-common.inc

# Override description for this version
DESCRIPTION = "ADU swupdate image v1 (baseline for delta)"

# Version configuration
# Use BASE_ADU_SOFTWARE_VERSION if set, otherwise default to 1.0.0.1
# In CI/CD, set BASE_ADU_SOFTWARE_VERSION to your desired version (e.g., 2.3.4.5)
BASE_ADU_SOFTWARE_VERSION ??= "1.0.0.1"
ADU_SOFTWARE_VERSION = "${BASE_ADU_SOFTWARE_VERSION}"

# Image link name - used for stable filename references
export IMAGE_LINK_NAME = "adu-update-image-v1"

# Automatically clean SWU artifacts when recipe is cleaned/rebuilt
clean_swu_artifacts () {
    # Find and remove SWU artifacts from deploy directory
    for swu_file in ${DEPLOY_DIR_IMAGE}/${IMAGE_NAME}*.swu ${DEPLOY_DIR_IMAGE}/${IMAGE_LINK_NAME}*.swu; do
        if [ -f "$swu_file" ]; then
            bbwarn "Cleaning stale SWU artifact: $swu_file"
            rm -f "$swu_file"
        fi
    done
}

CLEANFUNCS += "clean_swu_artifacts"
