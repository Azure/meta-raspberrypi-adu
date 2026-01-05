# ADU SWUpdate Image - Version 3 (target)
# This is the target update image for delta generation testing
# Version is automatically incremented from v1 (patch version +2)

# Include common configuration shared by all versioned update images
require adu-update-image-common.inc

DESCRIPTION = "ADU swupdate image v3 (target for delta)"

# Auto-increment patch version from BASE_ADU_SOFTWARE_VERSION
# If v1 is 1.0.0, v2 becomes 1.0.2
# If v1 is 2.3.4, v2 becomes 2.3.6
BASE_ADU_SOFTWARE_VERSION ??= "1.0.0"

python () {
    base_version = d.getVar('BASE_ADU_SOFTWARE_VERSION')
    try:
        parts = base_version.split('.')
        if len(parts) == 3:
            major, minor, patch = parts
            new_patch = str(int(patch) + 2)
            v3_version = f"{major}.{minor}.{new_patch}"
        else:
            bb.warn(f"BASE_ADU_SOFTWARE_VERSION '{base_version}' not in x.y.z format, using as-is")
            v3_version = base_version
    except Exception as e:
        bb.warn(f"Failed to increment version from '{base_version}': {e}")
        v3_version = base_version
    
    d.setVar('ADU_SOFTWARE_VERSION', v3_version)
    bb.note(f"v1 version: {base_version}, v3 version: {v3_version}")
}

# Image link name - used for stable filename references
export IMAGE_LINK_NAME = "adu-update-image-v3"

# Add a dummy file to the image to create a difference from v1
# This ensures there's actual content difference for delta generation
ROOTFS_POSTPROCESS_COMMAND += "add_version_marker; "

add_version_marker() {
    echo "ADU Update Image v3.0.0 - $(date)" > ${IMAGE_ROOTFS}/etc/adu-image-version
    echo "Build timestamp: $(date +%s)" >> ${IMAGE_ROOTFS}/etc/adu-image-version
}

do_swuimage[depends] += "adu-base-image:do_image_complete"

python do_set_version() {
    import os
    version = d.getVar('ADU_SOFTWARE_VERSION')
    bb.note("Building ADU Update Image Version: %s" % version)
}

addtask set_version before do_swuimage after do_unpack
