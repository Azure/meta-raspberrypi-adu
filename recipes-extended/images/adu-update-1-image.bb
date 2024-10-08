# Builds the swupdate update image (.swu)
# This recipe and related files were taken from
# https://github.com/sbabic/meta-swupdate-boards
# and modifed for our purposes.

DESCRIPTION = "ADU swupdate image 1"
SECTION = ""
LICENSE="CLOSED"

DEPENDS += "adu-base-1-image swupdate"

SRC_URI = " \
    file://sw-description \
"

# images to build before building adu update image
IMAGE_DEPENDS = "adu-base-1-image"

# images and files that will be included in the .swu image
SWUPDATE_IMAGES = " \
        adu-base-1-image \
        "

SWUPDATE_IMAGES_FSTYPES[adu-base-1-image] = ".ext4.gz"

# Configure signing of the image with private key and password files.
# ADUC_PRIVATE_KEY - private key (.pem) file.
# ADUC_PRIVATE_KEY_PASSWORD - private key password (.pass) file.
# Generated RSA key with password using command:
# openssl genrsa -aes256 -passout file:priv.pass -out priv.pem
SWUPDATE_SIGNING = "RSA"
SWUPDATE_PRIVATE_KEY = "${ADUC_PRIVATE_KEY}"
SWUPDATE_PASSWORD_FILE = "${ADUC_PRIVATE_KEY_PASSWORD}"

export IMAGE_LINK_NAME="adu-update-image-1"
inherit swupdate
