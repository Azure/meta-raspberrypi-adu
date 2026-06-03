FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://enable-overlayfs.cfg"

KERNEL_FEATURES:append = " features/overlayfs/overlayfs.scc"

# Mirror yocto-kernel-cache (and other yoctoproject.org repos) via GitHub.
# git.yoctoproject.org has had repeated outages in 2025 (cgit/DDoS) that
# fail-stop kernel do_fetch with:
#   "No up to date source found: clone directory not available or not up
#    to date; shallow clone not enabled"
# The official mirror at github.com/yoctoproject/<repo> tracks upstream
# and is reachable from hosted ADO agents.
PREMIRRORS:prepend = "\
    git://git\\.yoctoproject\\.org/(.+) git://github.com/yoctoproject/\\1;protocol=https \n\
"
