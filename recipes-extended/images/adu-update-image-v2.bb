# ADU SWUpdate Image - Version 2 (target)
# This is the target update image for delta generation testing
# Version is automatically incremented from v1 (patch version +1)

# Include common configuration shared by all versioned update images
require adu-update-image-common.inc

DESCRIPTION = "ADU swupdate image v2 (target for delta)"

# Auto-increment build version from BASE_ADU_SOFTWARE_VERSION
# If v1 is 1.0.0.1, v2 becomes 1.0.0.2
# If v1 is 2.3.4.5, v2 becomes 2.3.4.6
BASE_ADU_SOFTWARE_VERSION ??= "1.0.0.1"

python () {
    base_version = d.getVar('BASE_ADU_SOFTWARE_VERSION')
    try:
        parts = base_version.split('.')
        if len(parts) == 4:
            major, minor, patch, build = parts
            new_build = str(int(build) + 1)
            v2_version = f"{major}.{minor}.{patch}.{new_build}"
        elif len(parts) == 3:
            # Fallback for 3-part versions (legacy)
            major, minor, patch = parts
            new_patch = str(int(patch) + 1)
            v2_version = f"{major}.{minor}.{new_patch}"
        else:
            bb.warn(f"BASE_ADU_SOFTWARE_VERSION '{base_version}' not in x.y.z.w or x.y.z format, using as-is")
            v2_version = base_version
    except Exception as e:
        bb.warn(f"Failed to increment version from '{base_version}': {e}")
        v2_version = base_version
    
    d.setVar('ADU_SOFTWARE_VERSION', v2_version)
    bb.note(f"v1 version: {base_version}, v2 version: {v2_version}")
}

# Image link name - used for stable filename references
export IMAGE_LINK_NAME = "adu-update-image-v2"

# Add a dummy file to the image to create a difference from v1
# This ensures there's actual content difference for delta generation
ROOTFS_POSTPROCESS_COMMAND += "add_version_marker; "

add_version_marker() {
    echo "ADU Update Image v2.0.0 - $(date)" > ${IMAGE_ROOTFS}/etc/adu-image-version
    echo "Build timestamp: $(date +%s)" >> ${IMAGE_ROOTFS}/etc/adu-image-version
}

do_swuimage[depends] += "adu-base-image:do_image_complete"

python do_set_version() {
    import os
    version = d.getVar('ADU_SOFTWARE_VERSION')
    bb.note("Building ADU Update Image Version: %s" % version)
}

addtask set_version before do_swuimage after do_unpack

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
