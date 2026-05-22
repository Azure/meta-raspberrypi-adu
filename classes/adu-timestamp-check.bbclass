# ADU Timestamp Validation Class
# Ensures that update images and delta images have been rebuilt after base image changes
# This catches cases where sstate cache didn't properly invalidate dependent recipes

# Validate that update image artifacts are newer than base image artifacts
python do_validate_timestamps() {
    import os
    import glob
    
    deploy_dir = d.getVar('DEPLOY_DIR_IMAGE')
    pn = d.getVar('PN')
    
    bb.note("======================================================================")
    bb.note("TASK: do_validate_timestamps for %s" % pn)
    bb.note("======================================================================")
    
    # Find base image rootfs timestamp
    base_pattern = os.path.join(deploy_dir, 'adu-base-image*.rootfs.ext4.gz')
    base_files = glob.glob(base_pattern)
    
    # Determine what artifacts to check based on recipe
    if pn.startswith('adu-update-image'):
        # Check SWU file timestamp
        artifact_pattern = os.path.join(deploy_dir, pn + '*.swu')
        artifact_files = glob.glob(artifact_pattern)
        artifact_type = 'SWU'
    elif pn == 'adu-delta-image':
        # Check delta diff files
        artifact_pattern = os.path.join(deploy_dir, 'adu-delta*.diff')
        artifact_files = glob.glob(artifact_pattern)
        artifact_type = 'Delta'
    else:
        bb.note("No timestamp validation needed for %s" % pn)
        return
    
    # Case 1: Base image doesn't exist yet
    if not base_files:
        if artifact_files:
            # CRITICAL: Artifacts exist but base image doesn't!
            # Auto-cleanup: Remove stale artifacts and let BitBake rebuild them
            bb.warn("Base image doesn't exist but %s artifacts found - auto-cleaning stale artifacts" % artifact_type)
            bb.warn("  This means %s is using cached artifacts from previous build." % pn)
            bb.warn("  Removing stale artifacts (they will be rebuilt automatically):")
            for artifact_file in artifact_files:
                bb.warn("    - Removing: %s" % os.path.basename(artifact_file))
                try:
                    os.remove(artifact_file)
                except OSError as e:
                    bb.warn("      Failed to remove %s: %s" % (artifact_file, e))
            bb.warn("  BitBake will now rebuild fresh artifacts with correct base image.")
            return
        else:
            # Both base image and artifacts don't exist - this is OK (first build)
            bb.note("Base image and %s artifacts not found - will be built fresh (first build)." % artifact_type)
            return
    
    # Case 2: Base image exists
    base_file = max(base_files, key=os.path.getmtime)
    base_mtime = os.path.getmtime(base_file)
    
    bb.note("Base image reference: %s" % os.path.basename(base_file))
    bb.note("Base image timestamp: %s" % base_mtime)
    
    if not artifact_files:
        # Base exists but artifacts don't - will be built fresh (OK)
        bb.note("Base image exists, %s artifacts will be built fresh." % artifact_type)
        return
    
    # Check each artifact - auto-cleanup if stale
    stale_artifacts = []
    for artifact_file in artifact_files:
        artifact_mtime = os.path.getmtime(artifact_file)
        artifact_name = os.path.basename(artifact_file)
        
        if artifact_mtime < base_mtime:
            bb.warn("Stale artifact detected: %s is older than base image" % artifact_name)
            bb.warn("  Artifact: %s (mtime: %s)" % (artifact_name, artifact_mtime))
            bb.warn("  Base:     %s (mtime: %s)" % (os.path.basename(base_file), base_mtime))
            stale_artifacts.append(artifact_file)
        else:
            bb.note("✓ %s is newer than base image (OK)" % artifact_name)
    
    # Auto-cleanup stale artifacts
    if stale_artifacts:
        bb.warn("Auto-cleaning %d stale artifact(s) - they will be rebuilt:" % len(stale_artifacts))
        for artifact_file in stale_artifacts:
            bb.warn("  - Removing: %s" % os.path.basename(artifact_file))
            try:
                os.remove(artifact_file)
            except OSError as e:
                bb.warn("      Failed to remove %s: %s" % (artifact_file, e))
        bb.warn("BitBake will rebuild fresh artifacts with correct timestamps.")
    else:
        bb.note("✓ All artifacts have correct timestamps")
    
    bb.note("======================================================================")
}

# Run validation after image is created but before deploy
addtask validate_timestamps after do_image_complete before do_build
do_validate_timestamps[nostamp] = "1"
do_validate_timestamps[doc] = "Validate that image artifacts are newer than base image"
