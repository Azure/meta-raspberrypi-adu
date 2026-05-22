# Raspberry Pi Configuration for ADU Persistence Strategy
# Use overlayfs strategy for comprehensive persistence across A/B updates

# Select overlayfs strategy (advanced, with network config persistence)
PREFERRED_PROVIDER_adu-persistence-strategy = "adu-persistent-overlay"

# Ensure the persistence strategy is included in the image
# The specific recipe (adu-persistent-overlay) will be selected based on PREFERRED_PROVIDER
IMAGE_INSTALL:append = " adu-persistence-strategy"

# Note: This will automatically pull in:
#   - adu-filesystem-layout (via RDEPENDS)
#   - azure-device-update (via RDEPENDS)
