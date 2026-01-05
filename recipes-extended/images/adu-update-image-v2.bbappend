# Deploy the .swu file to DEPLOY_DIR_IMAGE for adu-update-image-v2
# The swupdate class creates .swu files but they may not always get deployed properly
# after cleanall operations. This bbappend ensures explicit deployment.

# Include common deployment logic
require adu-update-image.inc
