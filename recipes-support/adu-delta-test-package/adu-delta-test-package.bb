SUMMARY = "ADU Delta Update Test Package"
DESCRIPTION = "Comprehensive test package containing images, tools, and scripts for \
round-trip delta update verification on Raspberry Pi devices"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Depends on all images being built first
do_install[depends] = " \
    adu-base-image:do_build \
    adu-update-image-v1:do_build \
    adu-update-image-v2:do_build \
    adu-update-image-v3:do_build \
    adu-delta-image:do_build \
"

# Source files for scripts
SRC_URI = " \
    file://cache_manager.sh \
    file://delta_operations.py \
"

S = "${WORKDIR}"
B = "${WORKDIR}/build"

PACKAGE_NAME = "delta-test-package-${DATETIME}"
PACKAGE_DIR = "${B}/${PACKAGE_NAME}"

# Make DATETIME available
DATETIME = "${@time.strftime('%Y%m%d-%H%M%S',time.gmtime())}"

# Don't create packages
PACKAGES = ""
ALLOW_EMPTY:${PN} = "1"

do_configure[noexec] = "1"
do_compile[noexec] = "1"
do_package[noexec] = "1"
do_packagedata[noexec] = "1"
do_package_write_rpm[noexec] = "1"
do_package_write_ipk[noexec] = "1"
do_package_write_deb[noexec] = "1"

do_install() {
    # Create package directory structure
    install -d ${PACKAGE_DIR}/images
    install -d ${PACKAGE_DIR}/tools
    install -d ${PACKAGE_DIR}/scripts
    install -d ${PACKAGE_DIR}/docs
    
    DEPLOY_DIR="${DEPLOY_DIR_IMAGE}"
    
    bbnote "Creating delta test package from work directories and deploy dir"
    bbnote "DEPLOY_DIR=${DEPLOY_DIR}"
    bbnote "MACHINE=${MACHINE}"
    bbnote "TMPDIR=${TMPDIR}"
    
    # Copy base image - try deploy directory first, then work directory
    BASE_IMAGE_COPIED=0
    
    # 1. Try symlink in deploy directory
    if [ -f "${DEPLOY_DIR}/adu-base-image-${MACHINE}.wic.gz" ]; then
        cp -L "${DEPLOY_DIR}/adu-base-image-${MACHINE}.wic.gz" ${PACKAGE_DIR}/images/adu-base-image.wic.gz
        bbnote "Copied base image (WIC.GZ) from deploy symlink"
        BASE_IMAGE_COPIED=1
    elif [ -f "${DEPLOY_DIR}/adu-base-image-${MACHINE}.wic.bz2" ]; then
        cp -L "${DEPLOY_DIR}/adu-base-image-${MACHINE}.wic.bz2" ${PACKAGE_DIR}/images/adu-base-image.wic.bz2
        bbnote "Copied base image (WIC.BZ2) from deploy symlink"
        BASE_IMAGE_COPIED=1
    fi
    
    # 2. Try timestamped file in deploy directory
    if [ "${BASE_IMAGE_COPIED}" = "0" ]; then
        BASE_IMAGE=$(find ${DEPLOY_DIR} -name "adu-base-image-*-*.wic.gz" -type f 2>/dev/null | head -1)
        if [ -n "${BASE_IMAGE}" ]; then
            cp "${BASE_IMAGE}" ${PACKAGE_DIR}/images/adu-base-image.wic.gz
            bbnote "Copied base image (WIC.GZ) from deploy: $(basename ${BASE_IMAGE})"
            BASE_IMAGE_COPIED=1
        else
            BASE_IMAGE=$(find ${DEPLOY_DIR} -name "adu-base-image-*-*.wic.bz2" -type f 2>/dev/null | head -1)
            if [ -n "${BASE_IMAGE}" ]; then
                cp "${BASE_IMAGE}" ${PACKAGE_DIR}/images/adu-base-image.wic.bz2
                bbnote "Copied base image (WIC.BZ2) from deploy: $(basename ${BASE_IMAGE})"
                BASE_IMAGE_COPIED=1
            fi
        fi
    fi
    
    # 3. Try work directory as final fallback
    if [ "${BASE_IMAGE_COPIED}" = "0" ] && [ -n "${TMPDIR}" ]; then
        BASE_IMAGE=$(find ${TMPDIR}/work -name "adu-base-image*.wic.gz" -type f 2>/dev/null | head -1)
        if [ -n "${BASE_IMAGE}" ]; then
            cp "${BASE_IMAGE}" ${PACKAGE_DIR}/images/adu-base-image.wic.gz
            bbnote "Copied base image (WIC.GZ) from work dir: $(basename ${BASE_IMAGE})"
            BASE_IMAGE_COPIED=1
        else
            BASE_IMAGE=$(find ${TMPDIR}/work -name "adu-base-image*.wic.bz2" -type f 2>/dev/null | head -1)
            if [ -n "${BASE_IMAGE}" ]; then
                cp "${BASE_IMAGE}" ${PACKAGE_DIR}/images/adu-base-image.wic.bz2
                bbnote "Copied base image (WIC.BZ2) from work dir: $(basename ${BASE_IMAGE})"
                BASE_IMAGE_COPIED=1
            fi
        fi
    fi
    
    if [ "${BASE_IMAGE_COPIED}" = "0" ]; then
        bbwarn "Base image not found in deploy or work directories"
        bbwarn "Searched deploy: ${DEPLOY_DIR}/adu-base-image-${MACHINE}.wic.{gz,bz2}"
        bbwarn "Searched work: ${TMPDIR}/work/*/adu-base-image/*.wic.{gz,bz2}"
    fi
    
    # Copy original update images from their work directories
    # Note: PACKAGE_ARCH contains underscores like "raspberrypi4_64"
    for version in v1 v2 v3; do
        # Use find to locate the work directory regardless of arch formatting
        WORKDIR_UPDATE=$(find ${TMPDIR}/work -type d -name "adu-update-image-${version}" 2>/dev/null | head -1)
        if [ -n "${WORKDIR_UPDATE}" ]; then
            SWU_FILE=$(find ${WORKDIR_UPDATE}/1.0/deploy-adu-update-image-${version} -name "adu-update-image-${version}-*.swu" -type f 2>/dev/null | head -1)
            if [ -n "${SWU_FILE}" ]; then
                cp "${SWU_FILE}" ${PACKAGE_DIR}/images/adu-update-image-${version}.swu
                bbnote "Copied original update ${version}: $(basename ${SWU_FILE})"
            else
                bbwarn "Original SWU file for ${version} not found in ${WORKDIR_UPDATE}"
            fi
        else
            bbwarn "Work directory for ${version} not found"
        fi
    done
    
    # Copy recompressed images and delta files from adu-delta-image work directory
    DELTA_WORKDIR="${TMPDIR}/work/${TUNE_PKGARCH}-poky-linux/adu-delta-image/1.0/delta-output"
    
    # Copy recompressed images
    for version in v1 v2 v3; do
        if [ -f "${DELTA_WORKDIR}/adu-update-image-${version}-recompressed.swu" ]; then
            cp "${DELTA_WORKDIR}/adu-update-image-${version}-recompressed.swu" ${PACKAGE_DIR}/images/
            bbnote "Copied update ${version} (recompressed) from delta work directory"
        fi
    done
    
    # Copy delta files
    for delta in adu-delta-v1-to-v2.diff adu-delta-v1-to-v3.diff adu-delta-v2-to-v3.diff; do
        if [ -f "${DELTA_WORKDIR}/${delta}" ]; then
            cp "${DELTA_WORKDIR}/${delta}" ${PACKAGE_DIR}/images/
            bbnote "Copied delta: ${delta}"
        fi
    done
    
    # Copy delta manifests
    if [ -d "${DELTA_WORKDIR}" ]; then
        for manifest in ${DELTA_WORKDIR}/delta-manifest-*.json; do
            if [ -f "${manifest}" ]; then
                cp "${manifest}" ${PACKAGE_DIR}/images/
                bbnote "Copied manifest: $(basename ${manifest})"
            fi
        done
    fi
    
    # Copy tools if available
    # Note: Tools might be in different work directories, we'll search for them
    if [ -n "${TMPDIR}" ]; then
        # Find and copy diffgentool
        DIFFGEN=$(find ${TMPDIR}/work -name "diffgentool" -type f 2>/dev/null | head -1)
        if [ -n "${DIFFGEN}" ]; then
            cp "${DIFFGEN}" ${PACKAGE_DIR}/tools/
            bbnote "Copied diffgentool"
        fi
        
        # Find and copy dumpextfs
        DUMPEXTFS=$(find ${TMPDIR}/work -name "dumpextfs" -type f 2>/dev/null | head -1)
        if [ -n "${DUMPEXTFS}" ]; then
            cp "${DUMPEXTFS}" ${PACKAGE_DIR}/tools/
            bbnote "Copied dumpextfs"
        fi
    fi
    
    # Copy scripts (they're in S which is WORKDIR)
    cp ${S}/cache_manager.sh ${PACKAGE_DIR}/scripts/
    cp ${S}/delta_operations.py ${PACKAGE_DIR}/scripts/
    chmod +x ${PACKAGE_DIR}/scripts/cache_manager.sh
    chmod +x ${PACKAGE_DIR}/scripts/delta_operations.py
    bbnote "Copied scripts"
    
    # Create README
    cat > ${PACKAGE_DIR}/README.md << 'README_EOF'
# ADU Delta Update Test Package

Comprehensive test package for round-trip delta update verification.

## Contents

- **images/**: Base image, update v1/v2/v3, recompressed versions, delta files, manifests
- **tools/**: Delta processing tools (diffgentool, dumpextfs if available)
- **scripts/**: cache_manager.sh, delta_operations.py
- **docs/**: Testing guides

## Quick Start

### 1. Store Source in Cache

```bash
./scripts/cache_manager.sh store \
    images/adu-update-image-v1-recompressed.swu \
    "Contoso" "1.0.0"
```

### 2. List Cached Files

```bash
./scripts/cache_manager.sh list
```

### 3. Lookup Source

```bash
./scripts/cache_manager.sh lookup "Contoso" "1.0.0"
```

### 4. Verify File Integrity

```bash
./scripts/delta_operations.py verify \
    images/adu-update-image-v1-recompressed.swu \
    /var/lib/adu/sdc/Contoso/sha256-<hash>
```

## Cache Structure

```
/var/lib/adu/sdc/
└── <provider>/
    ├── sha256-<hash>       # Cached file
    └── sha256-<hash>.meta  # Metadata (version, timestamp)
```

## Common Operations

**Store all versions:**
```bash
for version in v1 v2 v3; do
    ./scripts/cache_manager.sh store \
        images/adu-update-image-${version}-recompressed.swu \
        "Contoso" "${version:1}.0.0"
done
```

**Show cache info:**
```bash
./scripts/cache_manager.sh info
```

**Calculate file hashes:**
```bash
./scripts/delta_operations.py hash images/*.swu
```

## Delta File Analysis

Check delta efficiency:

```bash
cd images
ls -lh *.diff
# Delta files should be significantly smaller than target images
```

## Integration with ADU Agent

The ADU agent automatically:
1. Stores new versions in cache after successful updates
2. Looks up source from cache for delta updates
3. Reconstructs target from source + delta
4. Verifies integrity with SHA256

## Troubleshooting

**Permission errors:**
```bash
sudo chown -R adu:adu /var/lib/adu/sdc/
sudo chmod -R 755 /var/lib/adu/sdc/
```

**Monitor ADU agent:**
```bash
journalctl -u adu-agent -f
```

---

Package built: ${DATETIME}
Machine: ${MACHINE}
README_EOF

    # Create testing guide
    cat > ${PACKAGE_DIR}/docs/TESTING_GUIDE.md << 'TESTING_EOF'
# Delta Update Testing Guide

## Test Scenarios

### 1. Cache Population
- Store v1, v2, v3 in cache
- Verify ownership (adu:adu)
- Verify permissions (644 files, 755 dirs)

### 2. Cache Lookup
- Lookup each version by provider/version
- Verify metadata is correct

### 3. Round-Trip Verification
- Store source → Apply delta → Verify reconstruction

### 4. Integration Testing
- Store installed version in cache
- Simulate delta update workflow
- Verify end-to-end operation

## Expected Results

- Cache files at: /var/lib/adu/sdc/<provider>/sha256-<hash>
- Metadata files with correct version info
- All operations complete without permission errors
- Delta files < 1% of target size (for test images)

## Monitoring

```bash
# ADU agent logs
journalctl -u adu-agent -f

# Cache operations
./scripts/cache_manager.sh info
./scripts/cache_manager.sh list
```
TESTING_EOF

    # Create tarball
    cd ${B}
    tar -czf ${PACKAGE_NAME}.tar.gz ${PACKAGE_NAME}/
    
    # Install tarball to deploy directory
    install -d ${DEPLOY_DIR_IMAGE}
    install -m 0644 ${B}/${PACKAGE_NAME}.tar.gz ${DEPLOY_DIR_IMAGE}/adu-delta-test-package.tar.gz
    
    # Create a version-specific link
    cd ${DEPLOY_DIR_IMAGE}
    ln -sf adu-delta-test-package.tar.gz ${PACKAGE_NAME}.tar.gz
    
    bbnote "Delta test package created: ${DEPLOY_DIR_IMAGE}/adu-delta-test-package.tar.gz"
}

do_deploy() {
    :
}

addtask do_deploy after do_install before do_build

# This is a special recipe that doesn't produce RPMs
EXCLUDE_FROM_WORLD = "1"
