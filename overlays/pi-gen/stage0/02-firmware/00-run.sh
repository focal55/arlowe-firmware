#!/bin/bash -e
#
# stage0/02-firmware/00-run.sh -- arlowe overlay entry. NEW: upstream pi-gen
# ships no file at this path (its 02-firmware holds only 01-packages and
# 02-run.sh).
#
# Installs the kernel pinned in third_party/kernel/manifest.yml instead of
# letting apt resolve one. 01-packages in this same sub-stage has had the four
# kernel meta packages removed; this script is what puts a kernel in the rootfs
# in their place.
#
# WHY INDEX 00. pi-gen's run_sub_stage loops `for i in {00..99}` and completes
# every handler at one index before moving to the next, so this runs before
# 01-packages. That ordering is the entire design: the kernel is PREVENTED from
# resolving rather than installed and then downgraded.
#
# Why prevention and not a downgrade. Installing 6.12.109 and rolling back
# leaves linux-headers-6.12.109+rpt-common-rpi in /usr/src -- precisely the
# header the axcl postinst finds and compiles against. Worse, stage-arlowe's
# 01-runtime/00-run-chroot.sh picks the kernel to build against with
#   find /lib/modules -maxdepth 1 -name '*-rpi-2712' | sort -V | tail -1
# which selects the HIGHEST version present. A rootfs carrying both kernels
# re-breaks the axcl compile at ax_pcie_dev_host.c:220, which is the failure
# this whole phase exists to prevent.
#
# MODE 755 IS LOAD-BEARING. run_sub_stage guards with `[ -x ${i}-run.sh ]` and
# skips a non-executable run script with no log line at all -- pi-gen prints
# nothing. The overlay applier (scripts/lib/pigen-overlay.sh) asserts the mode
# from MANIFEST for exactly this reason.
#
# apt-get, not dpkg -i. The pinned set is not dependency-self-closing:
# linux-image-* needs kmod, linux-base and initramfs-tools; linux-headers-*
# needs gcc-12; linux-kbuild needs libc6, libelf1 and libssl3. dpkg -i cannot
# resolve those and would leave the chroot half-configured. apt resolves them
# from the snapshot-pinned Debian archive that stage0/00-configure-apt set up.

CHROOT_KDIR="/tmp/arlowe-kernel"

if [ -z "${ARLOWE_KERNEL_CACHE:-}" ] || [ ! -d "${ARLOWE_KERNEL_CACHE}" ]; then
	echo "[FAIL] stage0/02-firmware/00-run.sh: ARLOWE_KERNEL_CACHE unset or not a directory." >&2
	echo "       value: '${ARLOWE_KERNEL_CACHE:-<unset>}'" >&2
	echo "       scripts/verify-third-party.sh writes the resolved cache directory to" >&2
	echo "       build/.arlowe-kernel-cache; scripts/build-image.sh reads it and forwards" >&2
	echo "       it across the sudo boundary. A variable that is exported but NOT named" >&2
	echo "       in that sudo command's explicit list does not cross it." >&2
	echo "       Not skipping: 01-packages no longer requests a kernel, so carrying on" >&2
	echo "       would build a rootfs with no kernel at all and fail 25 minutes later" >&2
	echo "       somewhere far less obvious." >&2
	exit 1
fi

if [ -z "${ARLOWE_KERNEL_MANIFEST:-}" ] || [ ! -f "${ARLOWE_KERNEL_MANIFEST}" ]; then
	echo "[FAIL] stage0/02-firmware/00-run.sh: ARLOWE_KERNEL_MANIFEST unset or not a file." >&2
	echo "       value: '${ARLOWE_KERNEL_MANIFEST:-<unset>}'" >&2
	echo "       This script derives the deb filenames and every expected version string" >&2
	echo "       from third_party/kernel/manifest.yml rather than repeating them. Two" >&2
	echo "       copies of a version number is how a pin half-applies." >&2
	exit 1
fi

_kernel_manifest() {
	python3 -c "
import sys, yaml
with open(sys.argv[1]) as f:
    k = yaml.safe_load(f)['kernel']
q = sys.argv[2]
if q == 'debs':
    print('\n'.join(d['filename'] for d in k['debs']))
elif q == 'module_dirs':
    print(' '.join(k['expected_module_dirs']))
else:
    print(k[q])
" "${ARLOWE_KERNEL_MANIFEST}" "$1"
}

KERNEL_VERSION="$(_kernel_manifest version)"
KERNEL_DEBS="$(_kernel_manifest debs)"
KERNEL_MODULE_DIRS="$(_kernel_manifest module_dirs)"
KERNEL_HEADERS_DIR="$(_kernel_manifest expected_headers_dir)"

echo "[arlowe] installing pinned kernel ${KERNEL_VERSION} from ${ARLOWE_KERNEL_CACHE}"

# Assert the whole set is present BEFORE copying anything. A partial copy
# followed by an apt failure is far harder to read than a missing-file list.
missing=""
while IFS= read -r deb; do
	[ -z "${deb}" ] && continue
	[ -f "${ARLOWE_KERNEL_CACHE}/${deb}" ] || missing="${missing}
  ${deb}"
done <<EOF
${KERNEL_DEBS}
EOF

if [ -n "${missing}" ]; then
	echo "[FAIL] stage0/02-firmware/00-run.sh: pinned kernel debs missing from ${ARLOWE_KERNEL_CACHE}:${missing}" >&2
	echo "       scripts/verify-third-party.sh check 7 should have caught this before" >&2
	echo "       the build started. If it passed and these are gone, something emptied" >&2
	echo "       the cache between the gate and here." >&2
	exit 1
fi

rm -rf "${ROOTFS_DIR}${CHROOT_KDIR}"
while IFS= read -r deb; do
	[ -z "${deb}" ] && continue
	install -m 644 -D "${ARLOWE_KERNEL_CACHE}/${deb}" "${ROOTFS_DIR}${CHROOT_KDIR}/${deb}"
done <<EOF
${KERNEL_DEBS}
EOF

# The ./ prefix is required: apt treats a bare `foo.deb` argument as a PACKAGE
# NAMED "foo.deb" and fails with "unable to locate package". cd + ./*.deb gives
# every argument a path form.
on_chroot <<CHEOF
set -e
cd ${CHROOT_KDIR}
apt-get -o Acquire::Retries=3 install -y --no-install-recommends ./*.deb
CHEOF

# Assert the result inside the chroot. The set must be EXACTLY the pinned
# flavours: an extra module directory means some other kernel got in, and
# stage-arlowe would then build the axcl module against the highest one.
on_chroot <<CHEOF
set -e
expected="\$(printf '%s\n' ${KERNEL_MODULE_DIRS} | LC_ALL=C sort)"
actual="\$(ls -1 /lib/modules 2>/dev/null | LC_ALL=C sort)"
if [ "\${expected}" != "\${actual}" ]; then
	echo "[FAIL] /lib/modules does not hold exactly the pinned kernel(s)." >&2
	echo "       expected:" >&2
	printf '         %s\n' \${expected} >&2
	echo "       actual:" >&2
	printf '         %s\n' \${actual:-<empty>} >&2
	echo "       An EXTRA entry means a second kernel resolved despite the pin;" >&2
	echo "       stage-arlowe picks the highest present and the axcl compile breaks." >&2
	echo "       A MISSING entry means the pinned debs did not all install." >&2
	exit 1
fi
if [ ! -d "/usr/src/${KERNEL_HEADERS_DIR}" ]; then
	echo "[FAIL] /usr/src/${KERNEL_HEADERS_DIR} is missing." >&2
	echo "       This is the header tree the axcl postinst compiles against." >&2
	ls -1 /usr/src >&2 || true
	exit 1
fi
echo "[arlowe] kernel ${KERNEL_VERSION} installed; /lib/modules holds exactly: ${KERNEL_MODULE_DIRS}"
CHEOF

# ~75 MiB of debs must not ship in the image.
rm -rf "${ROOTFS_DIR}${CHROOT_KDIR}"
if [ -e "${ROOTFS_DIR}${CHROOT_KDIR}" ]; then
	echo "[FAIL] failed to remove ${CHROOT_KDIR} from the rootfs -- the debs would ship." >&2
	exit 1
fi
