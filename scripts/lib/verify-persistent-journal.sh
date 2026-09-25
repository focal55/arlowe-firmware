#!/usr/bin/env bash
# scripts/lib/verify-persistent-journal.sh
#
# Build-time gate: the journal on a provisioned rootfs survives a reboot AND an
# A/B slot switch.
#
#   verify_persistent_journal <rootfs>
#
# pi-gen stage2 (01-sys-tweaks/01-run.sh) seds Storage=volatile into the main
# journald.conf. Every image shipped that way until F7 #27, so an overnight hang
# on the bench left nothing to read. The gate asserts three things:
#
#   1. The EFFECTIVE Storage= is persistent. journald reads the main file, then
#      drop-ins from /etc and /usr/lib merged and sorted by basename, where an
#      /etc file masks a /usr/lib file of the same name; the last assignment
#      wins. A drop-in that merely exists proves nothing if a later one undoes it.
#   2. /var/log/journal is a bind mount of /var/lib/arlowe/journal. Persistent on
#      the slot root is not enough: the root is per-slot, 93% full on a 3.6G
#      partition, and replaced wholesale by an update — which discards the logs
#      from before the update, the ones most worth having.
#   3. The bind source exists in the /var/lib/arlowe skeleton, which
#      partition-image.sh seeds onto owner_state. A missing source fails the
#      mount, and with nofail the journal silently falls back to the slot root.
#
# Slot B's fstab is written separately by recovery-stub.sh and is not seen here.
#
# RETURN CODES: 0 pass, 1 at least one FAIL, 2 the rootfs could not be read.

_vpj_effective_storage() {
    local rootfs="$1"
    local value="" source="journald default (auto)"
    local conf="${rootfs}/etc/systemd/journald.conf"
    local line

    if [[ -f "${conf}" ]]; then
        line="$(grep -E '^[[:space:]]*Storage=' "${conf}" | tail -n 1)"
        if [[ -n "${line}" ]]; then
            value="${line#*=}"
            source="/etc/systemd/journald.conf"
        fi
    fi

    local base path
    while IFS= read -r base; do
        path="${rootfs}/etc/systemd/journald.conf.d/${base}"
        [[ -f "${path}" ]] || path="${rootfs}/usr/lib/systemd/journald.conf.d/${base}"
        line="$(grep -E '^[[:space:]]*Storage=' "${path}" | tail -n 1)"
        if [[ -n "${line}" ]]; then
            value="${line#*=}"
            source="${path#"${rootfs}"}"
        fi
    done < <(
        for d in "${rootfs}/etc/systemd/journald.conf.d" \
                 "${rootfs}/usr/lib/systemd/journald.conf.d"; do
            [[ -d "${d}" ]] && find "${d}" -maxdepth 1 -name '*.conf' -exec basename {} \;
        done | LC_ALL=C sort -u
    )

    printf '%s\t%s\n' "${value// /}" "${source}"
}

verify_persistent_journal() {
    local rootfs="$1"
    local failures=0

    if [[ ! -d "${rootfs}/etc" ]]; then
        echo "[journal] HARD ERROR: ${rootfs}/etc is not readable" >&2
        return 2
    fi
    # /var/lib/arlowe is 0750 arlowe:arlowe. Unprivileged, check 3 would report a
    # present directory as missing; build-image.sh runs this under sudo.
    if [[ -d "${rootfs}/var/lib/arlowe" && ! -x "${rootfs}/var/lib/arlowe" ]]; then
        echo "[journal] HARD ERROR: ${rootfs}/var/lib/arlowe is not searchable; run as root" >&2
        return 2
    fi

    local storage source
    IFS=$'\t' read -r storage source < <(_vpj_effective_storage "${rootfs}")
    if [[ "${storage}" == persistent ]]; then
        echo "[journal] OK   Storage=persistent (last set by ${source})"
    else
        echo "[journal] FAIL Storage=${storage:-auto} (last set by ${source}); the journal will not survive a reboot"
        failures=$((failures + 1))
    fi

    if awk '$1 == "/var/lib/arlowe/journal" && $2 == "/var/log/journal" && $4 ~ /(^|,)bind(,|$)/ { found = 1 }
            END { exit !found }' "${rootfs}/etc/fstab" 2>/dev/null; then
        echo "[journal] OK   /var/log/journal is bind-mounted from owner_state"
    else
        echo "[journal] FAIL /etc/fstab has no bind of /var/lib/arlowe/journal onto /var/log/journal; the journal would live on the slot root"
        failures=$((failures + 1))
    fi

    if [[ -d "${rootfs}/var/lib/arlowe/journal" ]]; then
        echo "[journal] OK   /var/lib/arlowe/journal exists in the owner_state skeleton"
    else
        echo "[journal] FAIL /var/lib/arlowe/journal is missing from the owner_state skeleton; the bind mount has no source"
        failures=$((failures + 1))
    fi

    (( failures == 0 ))
}
