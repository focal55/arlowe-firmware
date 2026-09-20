#!/bin/bash -e
#
# arlowe overlay -- replaces upstream pi-gen's stage0/prerun.sh.
#
# Applied onto the provisioned pi-gen tree on every build by
# apply_pigen_overlay (scripts/lib/pigen-overlay.sh). Do NOT edit the copy under
# pi-gen/: scripts/build-image.sh runs `sudo rm -rf` on that tree and re-clones
# it at PIGEN_REF, so an edit there is erased, silently, on the next build.
# Edit this file instead and re-record its overlay_sha256 in
# overlays/pi-gen/MANIFEST.
#
# What changed from upstream: the debootstrap mirror argument only.
# deb.debian.org is a rolling mirror -- what it serves on any two days differs,
# so the base rootfs was never reproducible. It now points at one fixed
# snapshot.debian.org timestamp, the same one stage0/00-configure-apt's
# sources.list uses, so bootstrap and every later apt resolution draw from the
# same frozen archive.
#
# http:// rather than https:// is deliberate and load-bearing. Content
# authenticity comes from the gpg signature on Release/InRelease, not from the
# transport; https is the silent-green hazard here, because a stock bookworm
# environment without ca-certificates fails every TLS index fetch and
# `apt-get update` still exits 0. See docs/architecture/0009-build-input-pinning.md.
#
# Nothing else is modified. The warning block below is upstream's, verbatim.

if [ "$RELEASE" != "bookworm" ]; then
	echo "WARNING: RELEASE does not match the intended option for this branch."
	echo "         Please check the relevant README.md section."
fi

if [ ! -d "${ROOTFS_DIR}" ]; then
	bootstrap ${RELEASE} "${ROOTFS_DIR}" http://snapshot.debian.org/archive/debian/20260915T000000Z/
fi
