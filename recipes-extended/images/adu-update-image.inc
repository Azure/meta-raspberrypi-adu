# Common deployment logic for adu-update-image recipes
# This file is included by adu-update-image-v*.bbappend files
# to provide explicit .swu file deployment to DEPLOY_DIR_IMAGE

# Deploy the generated .swu file with version-specific naming and stable symlink
#
# Why we need both versioned file and symlink:
# 1. IMAGE_NAME contains timestamp/version (e.g., adu-update-image-v1-raspberrypi4-64-20231218120000.swu)
#    - Provides unique identification for each build
#    - Enables tracking of specific build artifacts
#    - Prevents accidental overwrites between builds
#
# 2. IMAGE_LINK_NAME is stable (e.g., adu-update-image-v1.swu)
#    - Delta generation scripts search for stable names (adu-update-image-v1-*.swu)
#    - Simplifies referencing "latest" version in automation
#    - Consumers don't need to know exact timestamp
#    - Standard Yocto pattern for deploy directories

inherit deploy

do_deploy() {
    bbnote "======================================================================"
    bbnote "TASK: do_deploy"
    bbnote "RECIPE: ${PN}"
    bbnote "======================================================================"
    bbnote "Starting deployment of SWU file for ${PN}"
    bbnote "  SWUDEPLOYDIR: ${SWUDEPLOYDIR}"
    bbnote "  DEPLOYDIR: ${DEPLOYDIR}"
    bbnote "  IMAGE_NAME: ${IMAGE_NAME}"
    bbnote "  IMAGE_LINK_NAME: ${IMAGE_LINK_NAME}"
    
    bbnote "BEFORE DEPLOYMENT - Existing .swu files in DEPLOYDIR:"
    ls -lh ${DEPLOYDIR}/*.swu 2>/dev/null | while read line; do bbnote "  $line"; done || bbnote "  No .swu files in DEPLOYDIR yet"
    
    # The swupdate class creates both timestamped file and symlink in SWUDEPLOYDIR
    # Check for both to diagnose deployment issues
    TIMESTAMPED_FILE="${SWUDEPLOYDIR}/${IMAGE_NAME}.swu"
    SYMLINK_FILE="${SWUDEPLOYDIR}/${IMAGE_LINK_NAME}.swu"
    
    bbnote "SWUDEPLOYDIR contents (source for deployment):"
    ls -lh ${SWUDEPLOYDIR}/ 2>/dev/null | while read line; do bbnote "  $line"; done || bbnote "  Directory empty or doesn't exist"
    
    # Prefer the timestamped file (IMAGE_NAME) as it's the actual file
    if [ -f "$TIMESTAMPED_FILE" ]; then
        bbnote "Found timestamped SWU file: $TIMESTAMPED_FILE"
        bbnote "Installing to: ${DEPLOYDIR}/${IMAGE_NAME}.swu"
        install -m 0644 "$TIMESTAMPED_FILE" ${DEPLOYDIR}/
        
        bbnote "Creating symlink: ${IMAGE_LINK_NAME}.swu -> ${IMAGE_NAME}.swu"
        ln -sf ${IMAGE_NAME}.swu ${DEPLOYDIR}/${IMAGE_LINK_NAME}.swu
        
        bbnote "Successfully deployed SWU file for ${PN}"
        ls -lh ${DEPLOYDIR}/${IMAGE_NAME}.swu ${DEPLOYDIR}/${IMAGE_LINK_NAME}.swu | while read line; do bbnote "  $line"; done
        
        bbnote "AFTER DEPLOYMENT - All .swu files now in DEPLOYDIR:"
        ls -lh ${DEPLOYDIR}/*.swu 2>/dev/null | while read line; do bbnote "  $line"; done
        bbnote "======================================================================"
    elif [ -L "$SYMLINK_FILE" ] || [ -f "$SYMLINK_FILE" ]; then
        # Fallback: if only symlink exists, deploy it
        bbwarn "Timestamped file not found, but symlink exists: $SYMLINK_FILE"
        bbnote "Installing symlink target to: ${DEPLOYDIR}/"
        cp -a "$SYMLINK_FILE" ${DEPLOYDIR}/${IMAGE_LINK_NAME}.swu
        # Try to get the actual file it points to
        if [ -f "$SYMLINK_FILE" ]; then
            REAL_FILE=$(readlink -f "$SYMLINK_FILE")
            REAL_NAME=$(basename "$REAL_FILE")
            if [ -f "$REAL_FILE" ] && [ "$REAL_NAME" != "${IMAGE_LINK_NAME}.swu" ]; then
                install -m 0644 "$REAL_FILE" ${DEPLOYDIR}/
                bbnote "Also deployed real file: $REAL_NAME"
            fi
        fi
    else
        bberror "ERROR: No SWU file found in SWUDEPLOYDIR for ${PN}"
        bberror "  Expected timestamped: $TIMESTAMPED_FILE"
        bberror "  Expected symlink: $SYMLINK_FILE"
        bberror "This usually means do_swuimage task did not complete successfully"
        bberror "Full SWUDEPLOYDIR listing:"
        ls -la ${SWUDEPLOYDIR}/ 2>/dev/null | while read line; do bberror "  $line"; done || bberror "  Directory does not exist"
        bbfatal "SWU deployment failed for ${PN}"
    fi
}

addtask deploy after do_swuimage before do_build
