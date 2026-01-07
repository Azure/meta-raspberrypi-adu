# Generates delta/diff files between ADU update images
# This recipe creates binary diffs for testing delta updates
# Uses Azure IoT Hub Device Update DiffGenTool for delta generation
# Supports: v1->v2, v2->v3, and v1->v3 delta generation

DESCRIPTION = "ADU Delta Update File Generator (v1->v2, v2->v3, v1->v3)"
LICENSE = "CLOSED"

# Inherit timestamp validation to ensure deltas are rebuilt when base image changes
# Only enabled when delta update feature is turned on (WITH_FEATURE_DELTA_UPDATE='1')
# This prevents accidentally deploying delta files created from stale update packages
inherit ${@bb.utils.contains('WITH_FEATURE_DELTA_UPDATE', '1', 'adu-timestamp-check', '', d)}

# Remove old deployed delta files in a separate task before deploy
# This is necessary because cleansstate doesn't clean the deploy directory
python do_clean_old_deploys() {
    import glob
    import os
    
    deploy_dir = d.getVar('DEPLOY_DIR_IMAGE')
    
    # Remove old delta files and manifests
    old_diff_pattern = os.path.join(deploy_dir, 'adu-delta*.diff')
    old_manifest_pattern = os.path.join(deploy_dir, 'manifest-*-adu-delta-image*.deploy')
    
    for pattern in [old_diff_pattern, old_manifest_pattern]:
        for old_file in glob.glob(pattern):
            bb.note("Removing old deployed delta file: %s" % old_file)
            try:
                os.remove(old_file)
            except OSError as e:
                bb.warn("Could not remove %s: %s" % (old_file, e))
}

addtask clean_old_deploys before do_deploy after do_generate_all_deltas

# Depend on all versioned images
# Using simplified Python delta generator instead of DiffGenTool to avoid cross-arch issues
DEPENDS = "adu-update-image-v1 adu-update-image-v2 adu-update-image-v3"

# Task-level dependencies for all delta generation tasks
do_generate_delta_v1_v2[depends] = "\
    adu-update-image-v1:do_swuimage \
    adu-update-image-v2:do_swuimage \
"

do_generate_delta_v2_v3[depends] = "\
    adu-update-image-v2:do_swuimage \
    adu-update-image-v3:do_swuimage \
"

do_generate_delta_v1_v3[depends] = "\
    adu-update-image-v1:do_swuimage \
    adu-update-image-v3:do_swuimage \
"

# Include our simplified Python delta generator
SRC_URI = "file://simple-delta-gen.py"

# Native tools needed during build (host machine)
# bsdiff-native provides bsdiff/bspatch binaries for delta generation during build
DEPENDS += "bsdiff-native zstd-native cpio-native"

# Runtime dependencies for target image
RDEPENDS:${PN} += "python3-core cpio bsdiff zstd gzip"

# Install the Python script
do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/simple-delta-gen.py ${D}${bindir}/
}

DELTA_OUTPUT_DIR = "${WORKDIR}/delta-output"
DELTA_FILE_NAME_V1_V2 = "adu-delta-v1-to-v2.diff"
DELTA_FILE_NAME_V2_V3 = "adu-delta-v2-to-v3.diff"
DELTA_FILE_NAME_V1_V3 = "adu-delta-v1-to-v3.diff"
RECOMPRESSED_FILE_V1 = "adu-update-image-v1-recompressed.swu"
RECOMPRESSED_FILE_V2 = "adu-update-image-v2-recompressed.swu"
RECOMPRESSED_FILE_V3 = "adu-update-image-v3-recompressed.swu"
DEPLOYDIR = "${DEPLOY_DIR_IMAGE}"

# Helper shell function to generate delta using DiffGenTool with all 6 required arguments
generate_delta_shell() {
    local source_file="$1"
    local target_file="$2"
    local delta_file="$3"
    local source_ver="$4"
    local target_ver="$5"
    
    if [ ! -f "$source_file" ]; then
        bbfatal "Source file not found: $source_file"
    fi
    
    if [ ! -f "$target_file" ]; then
        bbfatal "Target file not found: $target_file"
    fi
    
    mkdir -p ${DELTA_OUTPUT_DIR}
    
    # Create subdirectories for logs and working files
    local logs_dir="${DELTA_OUTPUT_DIR}/logs-v${source_ver}-v${target_ver}"
    local work_dir="${DELTA_OUTPUT_DIR}/working-v${source_ver}-v${target_ver}"
    mkdir -p "$logs_dir" "$work_dir"
    
    bbnote "====================================="
    bbnote "Generating delta from v$source_ver to v$target_ver"
    bbnote "====================================="
    bbnote "  Source: $source_file"
    bbnote "  Target: $target_file"
    bbnote "  Delta:  ${DELTA_OUTPUT_DIR}/$delta_file"
    bbnote "  Recompressed: ${DELTA_OUTPUT_DIR}/$recompressed_file"
    bbnote "  Logs: $logs_dir"
    bbnote "  Working: $work_dir"
    bbnote "  Tool: simple-delta-gen.py (Python)"
    bbnote "====================================="
    
    # Generate delta using our simplified Python script
    # This avoids cross-architecture issues with .NET and native binaries
    # Uses host-native tools: cpio, bsdiff, zstd/gzip
    # Add /usr/bin to PATH so system bsdiff is available
    export PATH="/usr/bin:${PATH}"
    python3 ${WORKDIR}/simple-delta-gen.py \
        "$source_file" \
        "$target_file" \
        "${DELTA_OUTPUT_DIR}/$delta_file" \
        "$logs_dir" \
        "$work_dir" \
        "${DELTA_OUTPUT_DIR}/$recompressed_file"
    
    if [ $? -ne 0 ]; then
        bbfatal "Delta generation failed for v$source_ver to v$target_ver"
    fi
    
    # Verify delta file was created
    if [ ! -f "${DELTA_OUTPUT_DIR}/$delta_file" ]; then
        bbfatal "Delta file was not created: ${DELTA_OUTPUT_DIR}/$delta_file"
    fi
    
    # Get file sizes and hashes
    SOURCE_SIZE=$(stat -c%s "$source_file")
    TARGET_SIZE=$(stat -c%s "$target_file")
    DELTA_SIZE=$(stat -c%s "${DELTA_OUTPUT_DIR}/$delta_file")
    SOURCE_HASH=$(sha256sum "$source_file" | awk '{print $1}')
    TARGET_HASH=$(sha256sum "$target_file" | awk '{print $1}')
    DELTA_HASH=$(sha256sum "${DELTA_OUTPUT_DIR}/$delta_file" | awk '{print $1}')
    
    # Get recompressed file info (if it exists)
    RECOMPRESSED_SIZE=0
    RECOMPRESSED_HASH=""
    if [ -f "${DELTA_OUTPUT_DIR}/$recompressed_file" ]; then
        RECOMPRESSED_SIZE=$(stat -c%s "${DELTA_OUTPUT_DIR}/$recompressed_file")
        RECOMPRESSED_HASH=$(sha256sum "${DELTA_OUTPUT_DIR}/$recompressed_file" | awk '{print $1}')
        bbnote "Recompressed file created: $recompressed_file ($RECOMPRESSED_SIZE bytes)"
    else
        bbwarn "Recompressed file not found: $recompressed_file"
    fi
    
    COMPRESSION=$(awk "BEGIN {printf \"%.2f\", ($DELTA_SIZE / $TARGET_SIZE) * 100}")
    
    # Create metadata file
    cat > "${DELTA_OUTPUT_DIR}/delta-info-v${source_ver}-to-v${target_ver}.txt" << EOF
Delta Information: v$source_ver → v$target_ver
Generated: $(date)
Source Version: $source_ver
Target Version: $target_ver
Source File: $(basename $source_file)
Target File: $(basename $target_file)
Delta Algorithm: Azure DiffGenTool (optimized for ADU)

File Sizes:
  Source: $SOURCE_SIZE bytes
  Target: $TARGET_SIZE bytes
  Delta: $DELTA_SIZE bytes
  Recompressed Target: $RECOMPRESSED_SIZE bytes
  Compression Ratio: $COMPRESSION%

File Hashes (SHA256):
  Source: $SOURCE_HASH
  Target: $TARGET_HASH
  Delta: $DELTA_HASH
  Recompressed Target: $RECOMPRESSED_HASH

ADU Service Import:
  - Import file: delta-manifest-v${source_ver}-to-v${target_ver}.importmanifest.json
  - Target SWU: $(basename ${DELTA_OUTPUT_DIR}/$recompressed_file)
  - Delta file: $(basename ${DELTA_OUTPUT_DIR}/$delta_file)

Device-side Application:
  - Delta processor applies: delta-diffgen <source> <target> <delta>
EOF
    
    bbnote "Delta generation completed successfully!"
    bbnote "  Delta size: $DELTA_SIZE bytes ($COMPRESSION% of target)"
    bbnote "  Source hash: $SOURCE_HASH"
    bbnote "  Recompressed target hash: $RECOMPRESSED_HASH"
}

# Task 1: Generate v1 -> v2 delta
do_generate_delta_v1_v2() {
    # Add native tools to PATH
    export PATH="${STAGING_BINDIR_NATIVE}:${PATH}"
    
    bbnote "======================================================================"
    bbnote "TASK: do_generate_delta_v1_v2"
    bbnote "RECIPE: ${PN}"
    bbnote "Searching for SWU files in DEPLOY_DIR_IMAGE: ${DEPLOY_DIR_IMAGE}"
    bbnote "======================================================================"
    
    # List ALL .swu files in DEPLOY_DIR_IMAGE for debugging
    bbnote "All .swu files in DEPLOY_DIR_IMAGE:"
    ls -lh ${DEPLOY_DIR_IMAGE}/*.swu 2>/dev/null | while read line; do bbnote "  $line"; done || bbnote "  No .swu files found!"
    
    bbnote "Searching for adu-update-image-v* files specifically:"
    find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v*.swu' 2>/dev/null | while read file; do bbnote "  Found: $file"; done || bbnote "  No versioned update image files found!"
    
    # Find SWU files at task execution time
    SWU_V1_FILE=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v1-*.swu' -type f | head -n1)
    SWU_V2_FILE=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v2-*.swu' -type f | head -n1)
    
    bbnote "Search results:"
    bbnote "  SWU_V1_FILE: $SWU_V1_FILE"
    bbnote "  SWU_V2_FILE: $SWU_V2_FILE"
    
    if [ -z "$SWU_V1_FILE" ] || [ -z "$SWU_V2_FILE" ]; then
        bberror "======================================================================"
        bberror "ERROR: SWU files not found for v1->v2 delta generation"
        bberror "  v1: $SWU_V1_FILE"
        bberror "  v2: $SWU_V2_FILE"
        bberror "This means the SWU files were not deployed to DEPLOY_DIR_IMAGE"
        bberror "Possible causes:"
        bberror "  1. do_swuimage tasks did not complete successfully"
        bberror "  2. do_deploy tasks in bbappend did not run or failed"
        bberror "  3. Files were cleaned by another task"
        bberror "  4. sstate mechanism did not restore deployed files"
        bberror "======================================================================"
        bbfatal "SWU files not found: v1=$SWU_V1_FILE v2=$SWU_V2_FILE"
    fi
    
    bbnote "Proceeding with delta generation: v1 -> v2"
    # CRITICAL: For consistent delta chaining, ALL deltas must use recompressed sources!
    # v1→v2: recompressed-v1 + diff → recompressed-v2
    # v2→v3: recompressed-v2 + diff → recompressed-v3
    # This ensures the device always has recompressed versions after each update.
    
    recompressed_file="${RECOMPRESSED_FILE_V2}"
    delta_file="${DELTA_FILE_NAME_V1_V2}"
    
    # First, create recompressed v1 (this becomes the delta source)
    RECOMPRESSED_V1_PATH="${DELTA_OUTPUT_DIR}/${RECOMPRESSED_FILE_V1}"
    bbnote "Creating recompressed v1 (source for delta)..."
    python3 ${WORKDIR}/simple-delta-gen.py \
        "$SWU_V1_FILE" \
        "$SWU_V1_FILE" \
        "${DELTA_OUTPUT_DIR}/dummy-v1-to-v1.diff" \
        "${DELTA_OUTPUT_DIR}/logs-v1-recompress" \
        "${DELTA_OUTPUT_DIR}/working-v1-recompress" \
        "$RECOMPRESSED_V1_PATH" || bbfatal "Failed to create v1-recompressed"
    
    bbnote "Recompressed v1 created: $RECOMPRESSED_V1_PATH"
    
    # Generate v1→v2 delta using recompressed-v1 as source
    bbnote "Generating delta from recompressed-v1 to recompressed-v2..."
    generate_delta_shell "$RECOMPRESSED_V1_PATH" "$SWU_V2_FILE" \
        "$delta_file" "1.0.0" "2.0.0"
}

addtask generate_delta_v1_v2 after do_unpack before do_test_delta_v1_v2

# Task 2: Generate v2 -> v3 delta
do_generate_delta_v2_v3() {
    # Add native tools to PATH
    export PATH="${STAGING_BINDIR_NATIVE}:${PATH}"
    
    bbnote "======================================================================"
    bbnote "TASK: do_generate_delta_v2_v3"
    bbnote "RECIPE: ${PN}"
    bbnote "Searching for SWU files in DEPLOY_DIR_IMAGE: ${DEPLOY_DIR_IMAGE}"
    bbnote "====================================================================="
    
    # List ALL .swu files in DEPLOY_DIR_IMAGE for debugging
    bbnote "All .swu files in DEPLOY_DIR_IMAGE:"
    ls -lh ${DEPLOY_DIR_IMAGE}/*.swu 2>/dev/null | while read line; do bbnote "  $line"; done || bbnote "  No .swu files found!"
    
    # Find SWU files at task execution time
    SWU_V2_FILE=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v2-*.swu' -type f | head -n1)
    SWU_V3_FILE=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v3-*.swu' -type f | head -n1)
    
    bbnote "Search results:"
    bbnote "  SWU_V2_FILE: $SWU_V2_FILE"
    bbnote "  SWU_V3_FILE: $SWU_V3_FILE"
    
    if [ -z "$SWU_V2_FILE" ] || [ -z "$SWU_V3_FILE" ]; then
        bberror "======================================================================"
        bberror "ERROR: SWU files not found for v2->v3 delta generation"
        bberror "  v2: $SWU_V2_FILE"
        bberror "  v3: $SWU_V3_FILE"
        bberror "======================================================================"
        bbfatal "SWU files not found: v2=$SWU_V2_FILE v3=$SWU_V3_FILE"
    fi
    
    bbnote "Proceeding with delta generation: v2 -> v3"
    # CRITICAL: Use recompressed-v2 as source since device has recompressed v2 after v1->v2 update!
    # Check if recompressed v2 exists from previous delta generation
    RECOMPRESSED_V2_PATH="${DELTA_OUTPUT_DIR}/${RECOMPRESSED_FILE_V2}"
    
    if [ ! -f "$RECOMPRESSED_V2_PATH" ]; then
        bbwarn "Recompressed v2 not found, creating it now for proper delta chain..."
        python3 ${WORKDIR}/simple-delta-gen.py \
            "$SWU_V2_FILE" \
            "$SWU_V2_FILE" \
            "${DELTA_OUTPUT_DIR}/dummy-v2-to-v2.diff" \
            "${DELTA_OUTPUT_DIR}/logs-v2-recompress" \
            "${DELTA_OUTPUT_DIR}/working-v2-recompress" \
            "$RECOMPRESSED_V2_PATH" || bbfatal "Failed to create v2-recompressed"
    fi
    
    recompressed_file="${RECOMPRESSED_FILE_V3}"
    delta_file="${DELTA_FILE_NAME_V2_V3}"
    
    # Use recompressed-v2 as source (not original v2!)
    generate_delta_shell "$RECOMPRESSED_V2_PATH" "$SWU_V3_FILE" \
        "$delta_file" "2.0.0" "3.0.0"
}

addtask generate_delta_v2_v3 after do_unpack before do_test_delta_v2_v3

# Task 3: Generate v1 -> v3 delta (skip v2 path)
do_generate_delta_v1_v3() {
    # Add native tools to PATH
    export PATH="${STAGING_BINDIR_NATIVE}:${PATH}"
    
    bbnote "======================================================================"
    bbnote "TASK: do_generate_delta_v1_v3"
    bbnote "RECIPE: ${PN}"
    bbnote "Searching for SWU files in DEPLOY_DIR_IMAGE: ${DEPLOY_DIR_IMAGE}"
    bbnote "====================================================================="
    
    # List ALL .swu files in DEPLOY_DIR_IMAGE for debugging
    bbnote "All .swu files in DEPLOY_DIR_IMAGE:"
    ls -lh ${DEPLOY_DIR_IMAGE}/*.swu 2>/dev/null | while read line; do bbnote "  $line"; done || bbnote "  No .swu files found!"
    
    # Find SWU files at task execution time
    SWU_V1_FILE=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v1-*.swu' -type f | head -n1)
    SWU_V3_FILE=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v3-*.swu' -type f | head -n1)
    
    bbnote "Search results:"
    bbnote "  SWU_V1_FILE: $SWU_V1_FILE"
    bbnote "  SWU_V3_FILE: $SWU_V3_FILE"
    
    if [ -z "$SWU_V1_FILE" ] || [ -z "$SWU_V3_FILE" ]; then
        bberror "======================================================================"
        bberror "ERROR: SWU files not found for v1->v3 delta generation"
        bberror "  v1: $SWU_V1_FILE"
        bberror "  v3: $SWU_V3_FILE"
        bberror "======================================================================"
        bbfatal "SWU files not found: v1=$SWU_V1_FILE v3=$SWU_V3_FILE"
    fi
    
    bbnote "Proceeding with delta generation: v1 -> v3"
    recompressed_file="${RECOMPRESSED_FILE_V3}"
    delta_file="${DELTA_FILE_NAME_V1_V3}"
    generate_delta_shell "$SWU_V1_FILE" "$SWU_V3_FILE" \
        "$delta_file" "1.0.0" "3.0.0"
}

addtask generate_delta_v1_v3 after do_unpack before do_test_delta_v1_v3

# Helper function to generate ADU import manifest (JSON v5)
generate_import_manifest() {
    source_swu="$1"
    recompressed_swu="$2"
    delta_file="$3"
    source_ver="$4"
    target_ver="$5"
    manifest_file="$6"
    
    source_hash=$(sha256sum "$source_swu" | awk '{print $1}')
    target_hash=$(sha256sum "$recompressed_swu" | awk '{print $1}')
    delta_hash=$(sha256sum "$delta_file" | awk '{print $1}')
    recompressed_size=$(stat -c%s "$recompressed_swu")
    delta_size=$(stat -c%s "$delta_file")
    
    # Extract installedCriteria from adu-version file inside the target SWU
    # This ensures the manifest uses the actual version from the update package
    bbnote "Extracting installedCriteria from target SWU..."
    temp_extract="${WORKDIR}/temp_extract_manifest"
    rm -rf "$temp_extract"
    mkdir -p "$temp_extract"
    
    # Extract SWU to get adu-version file
    if cpio -i -F "$recompressed_swu" -D "$temp_extract" 2>/dev/null; then
        # Look for sw-description which contains adu-version reference
        if [ -f "$temp_extract/sw-description" ]; then
            # Extract version from first image's properties or fallback to target_ver
            installed_criteria=$(grep -oP 'version\s*=\s*"\K[^"]+' "$temp_extract/sw-description" | head -1)
            if [ -z "$installed_criteria" ]; then
                installed_criteria="$target_ver"
                bbwarn "Could not extract version from sw-description, using target version: $installed_criteria"
            else
                bbnote "Extracted installedCriteria from sw-description: $installed_criteria"
            fi
        else
            installed_criteria="$target_ver"
            bbwarn "sw-description not found, using target version: $installed_criteria"
        fi
    else
        installed_criteria="$target_ver"
        bbwarn "Could not extract SWU, using target version: $installed_criteria"
    fi
    rm -rf "$temp_extract"
    
    # Script file name for A/B updates
    SCRIPT_FILE="yocto-a-b-update.sh"
    SWU_FILE_NAME="adu-update-image-v${target_ver}-recompressed.swu"
    SCRIPT_ARGUMENTS="--software-version-file /etc/adu-version --swupdate-log-file /var/log/adu/swupdate.log"
    
    # Generate JSON import manifest
    printf '{\n' > "$manifest_file"
    printf '  "updateId": {\n' >> "$manifest_file"
    printf '    "provider": "microsoft",\n' >> "$manifest_file"
    printf '    "name": "adu-delta-update",\n' >> "$manifest_file"
    printf '    "version": "%s"\n' "$target_ver" >> "$manifest_file"
    printf '  },\n' >> "$manifest_file"
    printf '  "updateType": "microsoft/swupdate:2",\n' >> "$manifest_file"
    printf '  "compatibility": [\n' >> "$manifest_file"
    printf '    {\n' >> "$manifest_file"
    printf '      "manufacturer": "raspberrypi",\n' >> "$manifest_file"
    printf '      "model": "raspberrypi4-64"\n' >> "$manifest_file"
    printf '    }\n' >> "$manifest_file"
    printf '  ],\n' >> "$manifest_file"
    printf '  "instructions": {\n' >> "$manifest_file"
    printf '    "steps": [\n' >> "$manifest_file"
    printf '      {\n' >> "$manifest_file"
    printf '        "handler": "microsoft/swupdate:2",\n' >> "$manifest_file"
    printf '        "files": ["%s", "%s"],\n' "$SWU_FILE_NAME" "$SCRIPT_FILE" >> "$manifest_file"
    printf '        "handlerProperties": {\n' >> "$manifest_file"
    printf '          "installedCriteria": "%s",\n' "$installed_criteria" >> "$manifest_file"
    printf '          "swuFileName": "%s",\n' "$SWU_FILE_NAME" >> "$manifest_file"
    printf '          "scriptFileName": "%s",\n' "$SCRIPT_FILE" >> "$manifest_file"
    printf '          "arguments": "%s"\n' "$SCRIPT_ARGUMENTS" >> "$manifest_file"
    printf '        }\n' >> "$manifest_file"
    printf '      }\n' >> "$manifest_file"
    printf '    ]\n' >> "$manifest_file"
    printf '  },\n' >> "$manifest_file"
    printf '  "relatedFiles": [\n' >> "$manifest_file"
    printf '    {\n' >> "$manifest_file"
    printf '      "filename": "adu-delta-v%s-to-v%s.diff",\n' "$source_ver" "$target_ver" >> "$manifest_file"
    printf '      "sizeInBytes": %s,\n' "$delta_size" >> "$manifest_file"
    printf '      "hashes": {\n' >> "$manifest_file"
    printf '        "sha256": "%s"\n' "$delta_hash" >> "$manifest_file"
    printf '      },\n' >> "$manifest_file"
    printf '      "properties": {\n' >> "$manifest_file"
    printf '        "microsoft.sourceFileHashAlgorithm": "sha256",\n' >> "$manifest_file"
    printf '        "microsoft.sourceFileHash": "%s"\n' "$source_hash" >> "$manifest_file"
    printf '      }\n' >> "$manifest_file"
    printf '    }\n' >> "$manifest_file"
    printf '  ],\n' >> "$manifest_file"
    printf '  "downloadHandler": {\n' >> "$manifest_file"
    printf '    "id": "microsoft/delta:1"\n' >> "$manifest_file"
    printf '  }\n' >> "$manifest_file"
    printf '}\n' >> "$manifest_file"
    
    bbnote "Import manifest generated: $(basename $manifest_file)"
}

# Test task for v1 -> v2
do_test_delta_v1_v2() {
    # Add /usr/bin to PATH so bspatch is available
    export PATH="/usr/bin:${PATH}"
    
    # Find SWU files at task execution time
    SWU_V1=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v1-*.swu' -type f | head -n1)
    SWU_V2=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v2-*.swu' -type f | head -n1)
    
    if [ -z "$SWU_V1" ] || [ -z "$SWU_V2" ]; then
        bbfatal "SWU files not found for testing: v1=$SWU_V1 v2=$SWU_V2"
    fi
    
    bbnote "====================================="
    bbnote "Testing Delta: v1 -> v2"
    bbnote "====================================="
    
    DELTA_FILE="${DELTA_OUTPUT_DIR}/${DELTA_FILE_NAME_V1_V2}"
    DELTA_FILE_DECOMPRESSED="${DELTA_OUTPUT_DIR}/delta-v1-v2.bsdiff"
    RECONSTRUCTED="${DELTA_OUTPUT_DIR}/reconstructed-v2.swu"
    RECOMPRESSED_V1="${DELTA_OUTPUT_DIR}/${RECOMPRESSED_FILE_V1}"
    RECOMPRESSED_V2="${DELTA_OUTPUT_DIR}/${RECOMPRESSED_FILE_V2}"
    
    # CRITICAL: Delta was generated from recompressed-v1, so test must use it too
    if [ ! -f "$RECOMPRESSED_V1" ]; then
        bbfatal "Recompressed v1 not found! Cannot test v1->v2 delta. Path: $RECOMPRESSED_V1"
    fi
    
    # Decompress zstd-compressed delta
    bbnote "Decompressing delta file..."
    zstd -d "$DELTA_FILE" -o "$DELTA_FILE_DECOMPRESSED"
    
    bbnote "Applying delta patch from recompressed-v1..."
    bspatch "$RECOMPRESSED_V1" "$RECONSTRUCTED" "$DELTA_FILE_DECOMPRESSED"
    if [ $? -ne 0 ]; then
        bbfatal "Delta patch failed to apply!"
    fi
    
    # Compare against recompressed version (delta was generated from recompressed target)
    if [ -f "$RECOMPRESSED_V2" ]; then
        if cmp -s "$RECOMPRESSED_V2" "$RECONSTRUCTED"; then
            bbnote "✓ SUCCESS: v1->v2 delta verified!"
            V2_SHA256=$(sha256sum "$RECOMPRESSED_V2" | awk '{print $1}')
            RECON_SHA256=$(sha256sum "$RECONSTRUCTED" | awk '{print $1}')
            bbnote "  v2 recompressed SHA256: $V2_SHA256"
            bbnote "  Reconstructed SHA256:   $RECON_SHA256"
        else
            bbfatal "FAILED: v1->v2 reconstructed image does NOT match recompressed!"
        fi
    else
        bbwarn "Recompressed file not found, comparing against original"
        if cmp -s "$SWU_V2" "$RECONSTRUCTED"; then
            bbnote "✓ SUCCESS: v1->v2 delta verified (original)!"
        else
            bbfatal "FAILED: v1->v2 reconstructed image does NOT match!"
        fi
    fi
    
    bbnote "====================================="
    rm -f "$RECONSTRUCTED" "$DELTA_FILE_DECOMPRESSED"
    
    # Generate import manifest for this delta
    generate_import_manifest "$SWU_V1" "$SWU_V2" \
        "${DELTA_OUTPUT_DIR}/${DELTA_FILE_NAME_V1_V2}" "1.0.0" "2.0.0" \
        "${DELTA_OUTPUT_DIR}/delta-manifest-v1.0.0-to-v2.0.0.importmanifest.json"
}

addtask test_delta_v1_v2 after do_generate_delta_v1_v2 before do_deploy

# Test task for v2 -> v3
do_test_delta_v2_v3() {
    # Add /usr/bin to PATH so bspatch is available
    export PATH="/usr/bin:${PATH}"
    
    # Find SWU files at task execution time
    SWU_V2=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v2-*.swu' -type f | head -n1)
    SWU_V3=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v3-*.swu' -type f | head -n1)
    
    if [ -z "$SWU_V2" ] || [ -z "$SWU_V3" ]; then
        bbfatal "SWU files not found for testing: v2=$SWU_V2 v3=$SWU_V3"
    fi
    
    bbnote "====================================="
    bbnote "Testing Delta: v2 -> v3"
    bbnote "====================================="
    
    DELTA_FILE="${DELTA_OUTPUT_DIR}/${DELTA_FILE_NAME_V2_V3}"
    DELTA_FILE_DECOMPRESSED="${DELTA_OUTPUT_DIR}/delta-v2-v3.bsdiff"
    RECONSTRUCTED="${DELTA_OUTPUT_DIR}/reconstructed-v3.swu"
    RECOMPRESSED_V2="${DELTA_OUTPUT_DIR}/${RECOMPRESSED_FILE_V2}"
    RECOMPRESSED_V3="${DELTA_OUTPUT_DIR}/${RECOMPRESSED_FILE_V3}"
    
    # CRITICAL: Use recompressed-v2 as source (not original v2!)
    # The delta was generated from recompressed-v2 to recompressed-v3
    if [ ! -f "$RECOMPRESSED_V2" ]; then
        bbfatal "Recompressed v2 not found! Cannot test v2->v3 delta. Path: $RECOMPRESSED_V2"
    fi
    
    # Decompress zstd-compressed delta
    bbnote "Decompressing delta file..."
    zstd -d "$DELTA_FILE" -o "$DELTA_FILE_DECOMPRESSED"
    
    bbnote "Applying delta patch from recompressed-v2..."
    bspatch "$RECOMPRESSED_V2" "$RECONSTRUCTED" "$DELTA_FILE_DECOMPRESSED"
    if [ $? -ne 0 ]; then
        bbfatal "Delta patch failed to apply!"
    fi
    
    # Compare against recompressed version (delta was generated from recompressed target)
    if [ -f "$RECOMPRESSED_V3" ]; then
        if cmp -s "$RECOMPRESSED_V3" "$RECONSTRUCTED"; then
            bbnote "✓ SUCCESS: v2->v3 delta verified!"
            V3_SHA256=$(sha256sum "$RECOMPRESSED_V3" | awk '{print $1}')
            RECON_SHA256=$(sha256sum "$RECONSTRUCTED" | awk '{print $1}')
            bbnote "  v3 recompressed SHA256: $V3_SHA256"
            bbnote "  Reconstructed SHA256:   $RECON_SHA256"
        else
            bbfatal "FAILED: v2->v3 reconstructed image does NOT match recompressed!"
        fi
    else
        bbwarn "Recompressed file not found, comparing against original"
        if cmp -s "$SWU_V3" "$RECONSTRUCTED"; then
            bbnote "✓ SUCCESS: v2->v3 delta verified (original)!"
        else
            bbfatal "FAILED: v2->v3 reconstructed image does NOT match!"
        fi
    fi
    
    bbnote "====================================="
    rm -f "$RECONSTRUCTED" "$DELTA_FILE_DECOMPRESSED"
    
    # Generate import manifest for this delta
    generate_import_manifest "$SWU_V2" "$SWU_V3" \
        "${DELTA_OUTPUT_DIR}/${DELTA_FILE_NAME_V2_V3}" "2.0.0" "3.0.0" \
        "${DELTA_OUTPUT_DIR}/delta-manifest-v2.0.0-to-v3.0.0.importmanifest.json"
}

addtask test_delta_v2_v3 after do_generate_delta_v2_v3 before do_deploy

# Test task for v1 -> v3
do_test_delta_v1_v3() {
    # Add /usr/bin to PATH so bspatch is available
    export PATH="/usr/bin:${PATH}"
    
    # Find SWU files at task execution time
    SWU_V1=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v1-*.swu' -type f | head -n1)
    SWU_V3=$(find ${DEPLOY_DIR_IMAGE} -maxdepth 1 -name 'adu-update-image-v3-*.swu' -type f | head -n1)
    
    if [ -z "$SWU_V1" ] || [ -z "$SWU_V3" ]; then
        bbfatal "SWU files not found for testing: v1=$SWU_V1 v3=$SWU_V3"
    fi
    
    bbnote "====================================="
    bbnote "Testing Delta: v1 -> v3 (skip v2)"
    bbnote "====================================="
    
    DELTA_FILE="${DELTA_OUTPUT_DIR}/${DELTA_FILE_NAME_V1_V3}"
    DELTA_FILE_DECOMPRESSED="${DELTA_OUTPUT_DIR}/delta-v1-v3.bsdiff"
    RECONSTRUCTED="${DELTA_OUTPUT_DIR}/reconstructed-v3-from-v1.swu"
    RECOMPRESSED_V3="${DELTA_OUTPUT_DIR}/${RECOMPRESSED_FILE_V3}"
    
    # Decompress zstd-compressed delta
    bbnote "Decompressing delta file..."
    zstd -d "$DELTA_FILE" -o "$DELTA_FILE_DECOMPRESSED"
    
    bbnote "Applying delta patch..."
    bspatch "$SWU_V1" "$RECONSTRUCTED" "$DELTA_FILE_DECOMPRESSED"
    if [ $? -ne 0 ]; then
        bbfatal "Delta patch failed to apply!"
    fi
    
    # Compare against recompressed version (delta was generated from recompressed target)
    if [ -f "$RECOMPRESSED_V3" ]; then
        if cmp -s "$RECOMPRESSED_V3" "$RECONSTRUCTED"; then
            bbnote "✓ SUCCESS: v1->v3 delta verified!"
            V3_SHA256=$(sha256sum "$RECOMPRESSED_V3" | awk '{print $1}')
            RECON_SHA256=$(sha256sum "$RECONSTRUCTED" | awk '{print $1}')
            bbnote "  v3 recompressed SHA256: $V3_SHA256"
            bbnote "  Reconstructed SHA256:   $RECON_SHA256"
        else
            bbfatal "FAILED: v1->v3 reconstructed image does NOT match recompressed!"
        fi
    else
        bbwarn "Recompressed file not found, comparing against original"
        if cmp -s "$SWU_V3" "$RECONSTRUCTED"; then
            bbnote "✓ SUCCESS: v1->v3 delta verified (original)!"
        else
            bbfatal "FAILED: v1->v3 reconstructed image does NOT match!"
        fi
    fi
    
    bbnote "====================================="
    rm -f "$RECONSTRUCTED" "$DELTA_FILE_DECOMPRESSED"
    
    # Generate import manifest for this delta (skip v2 path)
    generate_import_manifest "$SWU_V1" "$SWU_V3" \
        "${DELTA_OUTPUT_DIR}/${DELTA_FILE_NAME_V1_V3}" "1.0.0" "3.0.0" \
        "${DELTA_OUTPUT_DIR}/delta-manifest-v1.0.0-to-v3.0.0.importmanifest.json"
}

addtask test_delta_v1_v3 after do_generate_delta_v1_v3 before do_deploy

do_deploy() {
    install -d ${DEPLOYDIR}
    
    bbnote "====================================="
    bbnote "do_deploy: Starting deployment for adu-delta-image"
    bbnote "====================================="
    bbnote "Recipe: ${PN}-${PV}-${PR}"
    bbnote "Source directory: ${DELTA_OUTPUT_DIR}"
    bbnote "Target directory: ${DEPLOYDIR}"
    bbnote ""
    
    # Check for existing files before cleanup
    bbnote "Checking for existing delta artifacts in deploy directory..."
    if ls ${DEPLOYDIR}/adu-delta-*.diff 1> /dev/null 2>&1; then
        bbnote "WARNING: Found existing .diff files (will be removed):"
        ls -lh ${DEPLOYDIR}/adu-delta-*.diff || true
    fi
    if ls ${DEPLOYDIR}/delta-manifest-*.importmanifest.json 1> /dev/null 2>&1; then
        bbnote "WARNING: Found existing .importmanifest.json files (will be removed):"
        ls -lh ${DEPLOYDIR}/delta-manifest-*.importmanifest.json || true
    fi
    if ls ${DEPLOYDIR}/statistics-*.txt 1> /dev/null 2>&1; then
        bbnote "WARNING: Found existing statistics-*.txt files (will be removed):"
        ls -lh ${DEPLOYDIR}/statistics-*.txt || true
    fi
    
    # Clean up any existing delta artifacts to avoid "file already exists" errors
    # This can happen if files were manually deployed or from previous runs
    bbnote "Cleaning up existing delta artifacts..."
    rm -f ${DEPLOYDIR}/adu-delta-*.diff
    rm -f ${DEPLOYDIR}/*-recompressed.swu
    rm -f ${DEPLOYDIR}/*-recompressed.swu.sha256
    rm -f ${DEPLOYDIR}/delta-manifest-*.importmanifest.json
    rm -f ${DEPLOYDIR}/statistics-*.txt
    bbnote "Cleanup complete."
    bbnote ""
    
    # Deploy delta files
    bbnote "Deploying delta files (.diff)..."
    if ls ${DELTA_OUTPUT_DIR}/*.diff 1> /dev/null 2>&1; then
        for diff_file in ${DELTA_OUTPUT_DIR}/*.diff; do
            bbnote "  Installing: $(basename $diff_file)"
            install -m 0644 "$diff_file" ${DEPLOYDIR}/
        done
    else
        bbnote "  No .diff files found in ${DELTA_OUTPUT_DIR}"
    fi
    
    # Deploy recompressed SWU files (for delta fallback)
    bbnote "Deploying recompressed SWU files..."
    if ls ${DELTA_OUTPUT_DIR}/*-recompressed.swu 1> /dev/null 2>&1; then
        for recomp_file in ${DELTA_OUTPUT_DIR}/*-recompressed.swu; do
            bbnote "  Installing: $(basename $recomp_file)"
            install -m 0644 "$recomp_file" ${DEPLOYDIR}/
            
            # Generate and deploy SHA256 hash file for verification
            sha256sum "$recomp_file" | awk '{print $1}' > "${DEPLOYDIR}/$(basename $recomp_file).sha256"
            bbnote "  Installing: $(basename $recomp_file).sha256"
        done
    else
        bbwarn "  No recompressed .swu files found in ${DELTA_OUTPUT_DIR}"
    fi
    
    # Deploy import manifests (JSON v5 for ADU service import)
    bbnote "Deploying import manifests (.importmanifest.json)..."
    if ls ${DELTA_OUTPUT_DIR}/*.importmanifest.json 1> /dev/null 2>&1; then
        for manifest_file in ${DELTA_OUTPUT_DIR}/*.importmanifest.json; do
            bbnote "  Installing: $(basename $manifest_file)"
            install -m 0644 "$manifest_file" ${DEPLOYDIR}/
        done
    else
        bbnote "  No .importmanifest.json files found in ${DELTA_OUTPUT_DIR}"
    fi
    
    # Deploy statistics files with unique names
    bbnote "Deploying statistics files..."
    for stats_file in ${DELTA_OUTPUT_DIR}/logs-v*/statistics.txt; do
        if [ -f "$stats_file" ]; then
            version_dir=$(basename $(dirname "$stats_file"))
            target_file="statistics-${version_dir}.txt"
            bbnote "  Installing: $target_file (from $version_dir/statistics.txt)"
            install -m 0644 "$stats_file" "${DEPLOYDIR}/$target_file"
        fi
    done
    
    bbnote ""
    bbnote "====================================="
    bbnote "Delta Update Artifacts Deployment Summary:"
    bbnote "====================================="
    bbnote "Location: ${DEPLOYDIR}/"
    bbnote "Deployed files:"
    ls -lh ${DEPLOYDIR}/ | grep -E "\\.diff|\\.json|statistics-.*\\.txt|-recompressed\\.swu" || true
    bbnote "====================================="
    bbnote "do_deploy: Completed successfully"
    bbnote "====================================="
}

do_deploy[depends] = ""
do_deploy[dirs] = "${DEPLOYDIR}"
do_deploy[umask] = "022"
addtask deploy after do_test_delta_v1_v2 do_test_delta_v2_v3 do_test_delta_v1_v3 before do_build

# No packages to create - this is a deploy-only recipe
PACKAGES = ""
EXCLUDE_FROM_WORLD = "1"

# Automatically clean delta artifacts when recipe is cleaned/rebuilt
clean_delta_artifacts () {
    # Find and remove delta .diff files from deploy directory
    for diff_file in ${DEPLOY_DIR_IMAGE}/adu-delta-v*.diff; do
        if [ -f "$diff_file" ]; then
            bbwarn "Cleaning stale delta artifact: $diff_file"
            rm -f "$diff_file"
        fi
    done
    
    # Also clean recompressed SWU files if they exist
    for swu_file in ${DEPLOY_DIR_IMAGE}/adu-update-image-v*-recompressed.swu; do
        if [ -f "$swu_file" ]; then
            bbwarn "Cleaning stale recompressed SWU: $swu_file"
            rm -f "$swu_file"
        fi
    done
    
    # Clean delta statistics and JSON files
    for stats_file in ${DEPLOY_DIR_IMAGE}/statistics-delta-*.txt ${DEPLOY_DIR_IMAGE}/delta-manifest-*.json; do
        if [ -f "$stats_file" ]; then
            bbwarn "Cleaning stale delta metadata: $stats_file"
            rm -f "$stats_file"
        fi
    done
}

CLEANFUNCS += "clean_delta_artifacts"
