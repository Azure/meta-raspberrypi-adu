# Common configuration for all ADU SWUpdate images
# This file contains shared settings used by adu-update-image-v1, v2, v3
# Each versioned recipe includes this file and only needs to set:
#   - IMAGE_LINK_NAME (e.g., "adu-update-image-v1")
#   - ADU_SOFTWARE_VERSION (e.g., "1.0.0", "2.0.0", "3.0.0")

DESCRIPTION ?= "ADU swupdate image"
SECTION = ""
LICENSE = "CLOSED"

# Dependencies
DEPENDS += "adu-base-image swupdate"

# Source files - sw-description template
SRC_URI = "file://sw-description"

# Image dependencies - what needs to be built before this
IMAGE_DEPENDS = "adu-base-image"

# Images and files to include in the .swu package
SWUPDATE_IMAGES = "adu-base-image"
SWUPDATE_IMAGES_FSTYPES[adu-base-image] = ".ext4.gz"

# RSA signing configuration
# ADUC_PRIVATE_KEY - private key (.pem) file
# ADUC_PRIVATE_KEY_PASSWORD - private key password (.pass) file
# Generated RSA key with password using:
#   openssl genrsa -aes256 -passout file:priv.pass -out priv.pem
SWUPDATE_SIGNING = "RSA"
SWUPDATE_PRIVATE_KEY = "${ADUC_PRIVATE_KEY}"
SWUPDATE_PASSWORD_FILE = "${ADUC_PRIVATE_KEY_PASSWORD}"

# Inherit swupdate class to get SWUpdate packaging functionality
# The swupdate class automatically deploys .swu files to DEPLOY_DIR_IMAGE
inherit swupdate

# Inherit timestamp validation to ensure this image is rebuilt when base image changes
# Only enabled when delta update feature is turned on (WITH_FEATURE_DELTA_UPDATE='1')
# This prevents accidentally deploying update packages with stale base images
inherit ${@bb.utils.contains('WITH_FEATURE_DELTA_UPDATE', '1', 'adu-timestamp-check', '', d)}

# The swupdate class's do_deploy conflicts with old files from previous builds
# because cleansstate doesn't clean the deploy directory.
# Solution: Remove old deployed files in a separate task before deploy
python do_clean_old_deploys() {
    import glob
    import os
    
    deploy_dir = d.getVar('DEPLOY_DIR_IMAGE')
    pn = d.getVar('PN')
    
    # Remove old SWU files and manifests for this recipe
    old_swu_pattern = os.path.join(deploy_dir, pn + '*.swu')
    old_manifest_pattern = os.path.join(deploy_dir, 'manifest-*-' + pn + '.swuimage')
    
    for pattern in [old_swu_pattern, old_manifest_pattern]:
        for old_file in glob.glob(pattern):
            bb.note("Removing old deployed file: %s" % old_file)
            try:
                os.remove(old_file)
            except OSError as e:
                bb.warn("Could not remove %s: %s" % (old_file, e))
}

addtask clean_old_deploys before do_deploy after do_swuimage

# Inherit timestamp validation to ensure this image is rebuilt when base image changes
inherit adu-timestamp-check

# Add dependency on adu-base-image completion
do_swuimage[depends] += "adu-base-image:do_image_complete"

# Python task to log version being built with comprehensive tracing
python do_set_version() {
    import os
    pn = d.getVar('PN')
    version = d.getVar('ADU_SOFTWARE_VERSION')
    image_name = d.getVar('IMAGE_LINK_NAME')
    image_basename = d.getVar('IMAGE_BASENAME') or 'N/A'
    
    bb.note("======================================================================")
    bb.note("TASK: do_set_version")
    bb.note("RECIPE: %s" % pn)
    bb.note("======================================================================")
    bb.note("Building ADU Update Image:")
    bb.note("  Recipe Name (PN): %s" % pn)
    bb.note("  Image Link Name: %s" % image_name)
    bb.note("  Software Version: %s" % version)
    bb.note("  Image Basename: %s" % image_basename)
    bb.note("======================================================================")
}

addtask set_version before do_swuimage after do_unpack
