#!/bin/bash -e
#
# arlowe overlay -- replaces upstream pi-gen's stage0/00-configure-apt/00-run.sh.
#
# Applied onto the provisioned pi-gen tree on every build by
# apply_pigen_overlay (scripts/lib/pigen-overlay.sh). Do NOT edit the copy under
# pi-gen/: scripts/build-image.sh runs `sudo rm -rf` on that tree and re-clones
# it at PIGEN_REF, so an edit there is erased, silently, on the next build.
# Edit this file instead and re-record its overlay_sha256 in
# overlays/pi-gen/MANIFEST.
#
# What changed from upstream: one added `install` line, for files/99arlowe-pinned.
# That apt.conf.d fragment must ship with the snapshot pin in the same change --
# a snapshot's Release file is expired by construction, so without it the build
# works today and starts failing about a week out with an error that reads like
# a network fault.
#
# Nothing else is modified.

install -m 644 files/sources.list "${ROOTFS_DIR}/etc/apt/"
install -m 644 files/raspi.list "${ROOTFS_DIR}/etc/apt/sources.list.d/"
install -m 644 files/99arlowe-pinned "${ROOTFS_DIR}/etc/apt/apt.conf.d/"
sed -i "s/RELEASE/${RELEASE}/g" "${ROOTFS_DIR}/etc/apt/sources.list"
sed -i "s/RELEASE/${RELEASE}/g" "${ROOTFS_DIR}/etc/apt/sources.list.d/raspi.list"

if [ -n "$APT_PROXY" ]; then
	install -m 644 files/51cache "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache"
	sed "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache" -i -e "s|APT_PROXY|${APT_PROXY}|"
else
	rm -f "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache"
fi

if [ -n "$TEMP_REPO" ]; then
	install -m 644 /dev/null "${ROOTFS_DIR}/etc/apt/sources.list.d/00-temp.list"
	echo "$TEMP_REPO" | sed "s/RELEASE/$RELEASE/g" > "${ROOTFS_DIR}/etc/apt/sources.list.d/00-temp.list"
else
	rm -f "${ROOTFS_DIR}/etc/apt/sources.list.d/00-temp.list"
fi

cat files/raspberrypi.gpg.key | gpg --dearmor > "${STAGE_WORK_DIR}/raspberrypi-archive-stable.gpg"
install -m 644 "${STAGE_WORK_DIR}/raspberrypi-archive-stable.gpg" "${ROOTFS_DIR}/etc/apt/trusted.gpg.d/"
on_chroot <<- \EOF
	ARCH="$(dpkg --print-architecture)"
	if [ "$ARCH" = "armhf" ]; then
		dpkg --add-architecture arm64
	elif [ "$ARCH" = "arm64" ]; then
		dpkg --add-architecture armhf
	fi
	apt-get update
	apt-get dist-upgrade -y
EOF
