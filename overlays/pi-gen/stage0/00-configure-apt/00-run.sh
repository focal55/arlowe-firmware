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
# And the raspi.list install and its sed are replaced by a switch on
# ARLOWE_PI_ARCHIVE_MODE (Phase 7.3). `record` keeps upstream's two lines.
# `pinned`, the default, gives the rootfs the flat repo scripts/build-image.sh
# built from third_party/pi-archive/manifest.yml as its only Pi source.
# copy_previous carries it through stage1, stage2 and stage-arlowe, and
# pi_archive_swap_back (scripts/lib/pi-archive-gate.sh) swaps upstream's
# raspi.list back in before the rootfs is measured. files/raspi.list must stay:
# that swap-back reads it.
#
# The flat repo has no Release file, so the apt-get update below prints `Ign:`
# lines for InRelease/Release and `Err: ... Packages.xz  File not found` lines,
# then exits 0 using the plain Packages. That is expected. Do not gate on those
# lines or on update's exit code; build-image.sh gates on the apt list files.
#
# Nothing else is modified.

install -m 644 files/sources.list "${ROOTFS_DIR}/etc/apt/"
install -m 644 files/99arlowe-pinned "${ROOTFS_DIR}/etc/apt/apt.conf.d/"
sed -i "s/RELEASE/${RELEASE}/g" "${ROOTFS_DIR}/etc/apt/sources.list"

PI_REPO_IN_ROOTFS="/var/local/arlowe-pi-archive"
case "${ARLOWE_PI_ARCHIVE_MODE:-pinned}" in
	record)
		install -m 644 files/raspi.list "${ROOTFS_DIR}/etc/apt/sources.list.d/"
		sed -i "s/RELEASE/${RELEASE}/g" "${ROOTFS_DIR}/etc/apt/sources.list.d/raspi.list"
		;;
	pinned)
		if [ -z "${ARLOWE_PI_REPO:-}" ] || [ ! -d "${ARLOWE_PI_REPO}" ]; then
			echo "[FAIL] stage0/00-configure-apt/00-run.sh: ARLOWE_PI_REPO unset or not a directory." >&2
			echo "       value: '${ARLOWE_PI_REPO:-<unset>}'" >&2
			echo "       scripts/build-image.sh builds the flat repo and forwards it across the" >&2
			echo "       sudo boundary. A variable that is exported but NOT named in that sudo" >&2
			echo "       command's explicit list does not cross it." >&2
			echo "       Not falling back to the live Pi archive: that is the unpinned build" >&2
			echo "       this mode exists to prevent." >&2
			exit 1
		fi
		rm -rf "${ROOTFS_DIR}${PI_REPO_IN_ROOTFS}"
		install -d "${ROOTFS_DIR}${PI_REPO_IN_ROOTFS}"
		cp "${ARLOWE_PI_REPO}"/*.deb "${ARLOWE_PI_REPO}/Packages" "${ARLOWE_PI_REPO}/SHA256SUMS" \
			"${ROOTFS_DIR}${PI_REPO_IN_ROOTFS}/"
		# Verify the copy, not the source: these are the bytes apt will install.
		(cd "${ROOTFS_DIR}${PI_REPO_IN_ROOTFS}" && sha256sum --quiet -c SHA256SUMS)
		rm -f "${ROOTFS_DIR}/etc/apt/sources.list.d/raspi.list"
		install -m 644 /dev/null "${ROOTFS_DIR}/etc/apt/sources.list.d/arlowe-pi-archive.list"
		echo "deb [trusted=yes] file:${PI_REPO_IN_ROOTFS} ./" > "${ROOTFS_DIR}/etc/apt/sources.list.d/arlowe-pi-archive.list"
		;;
	*)
		echo "[FAIL] stage0/00-configure-apt/00-run.sh: unknown ARLOWE_PI_ARCHIVE_MODE='${ARLOWE_PI_ARCHIVE_MODE}' (pinned or record)." >&2
		exit 1
		;;
esac

if [ -n "$APT_PROXY" ]; then
	install -m 644 files/51cache "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache"
	sed "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache" -i -e "s|APT_PROXY|${APT_PROXY}|"
else
	rm -f "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache"
fi

if [ -n "$TEMP_REPO" ]; then
	install -m 644 /dev/null "${ROOTFS_DIR}/etc/apt/sources.list.d/00-temp.list"
	# upstream pi-gen uses echo|sed here; kept verbatim so the recorded upstream digest
	# keeps meaning "unchanged from upstream apart from our pin".
	# shellcheck disable=SC2001
	echo "$TEMP_REPO" | sed "s/RELEASE/$RELEASE/g" > "${ROOTFS_DIR}/etc/apt/sources.list.d/00-temp.list"
else
	rm -f "${ROOTFS_DIR}/etc/apt/sources.list.d/00-temp.list"
fi

# upstream pi-gen's line, kept verbatim for the same reason as the SC2001 above:
# every unnecessary edit here erodes what this file's recorded upstream digest
# means. Rewriting it as `gpg --dearmor < file` would be a behaviour-identical
# change whose only effect is to make the overlay diverge from upstream in one
# more place.
#
# Ubuntu's shellcheck 0.9.0 (what CI installs) reports SC2002 at default
# severity; 0.11.0 does not report it at all, having made the check optional. So
# a clean local run on a newer shellcheck is NOT evidence about CI -- the version
# matters as much as the severity flag.
# shellcheck disable=SC2002
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
