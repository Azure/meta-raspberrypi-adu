FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://enable-overlayfs.cfg"

KERNEL_FEATURES:append = " features/overlayfs/overlayfs.scc"
