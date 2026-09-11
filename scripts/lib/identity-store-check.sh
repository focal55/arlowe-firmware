#!/usr/bin/env bash
# scripts/lib/identity-store-check.sh
#
# SC3 / IDENT-03 enforcement. Device identity material lives only in
# /var/lib/arlowe/identity/ at 0600, and never under /opt/arlowe, /etc/arlowe
# or the boot partitions.
#
#   check_identity_store <root> [--factory]
#
# <root> is a filesystem prefix: "/" on a running device, or a mountpoint when
# scanning an assembled image. --factory additionally requires the identity
# store to be EMPTY: one image is flashed to every unit, so any material
# present in the image would be identical on every unit.
#
# Returns 0 clean, 1 violation. Emits GitHub-Actions ::error annotations on
# stdout and a human line on stderr, matching scripts/sanitize/check.sh.
#
# Sourced by scripts/build-image.sh (step 5, over the read-only slot-A mount).
# Self-tested by tests/phase-7/test-identity-store-check.sh.

# Names that constitute identity material. runtime/cli/boot-check inlines this
# same list; scripts/lib/ is a build-host library and is not installed into the
# image, so the two cannot share code. This file is the authority.
IDENTITY_MATERIAL_GLOBS=(
  '*.key' '*.pem' '*.crt' '*.csr' '*.p12' '*.pfx'
  'device-entropy' 'device-id' 'identity.json'
)

_identity_err() {
  printf '::error title=Identity store violation::%s\n' "$1"
  printf '[identity-store] FAIL: %s\n' "$1" >&2
}

# GNU coreutils on the build host and the device; the BSD fallback keeps the
# self-test runnable on a macOS dev machine.
_identity_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# Symlinks are matched by name and reported, never dereferenced — a link out of
# the tree is itself the violation.
_identity_find_material() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  local args=() glob
  for glob in "${IDENTITY_MATERIAL_GLOBS[@]}"; do
    [[ ${#args[@]} -gt 0 ]] && args+=( -o )
    args+=( -name "$glob" )
  done
  find "$dir" \( -type f -o -type l \) \( "${args[@]}" \) -print 2>/dev/null
}

check_identity_store() {
  local root="${1:?check_identity_store: <root> required}"
  local factory=0
  case "${2:-}" in
    --factory) factory=1 ;;
    '') ;;
    *) _identity_err "unknown flag: $2"; return 1 ;;
  esac

  root="${root%/}"
  local violations=0 hit scan

  # 1. No key material under /opt/arlowe — the literal SC3 requirement.
  # 2. Same for /etc/arlowe and /boot. /boot/firmware is FAT with no permission
  #    bits at all, so material there is world-readable by construction.
  for scan in "${root}/opt/arlowe" "${root}/etc/arlowe" "${root}/boot"; do
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      _identity_err "identity material outside the identity store: ${hit#"$root"}"
      violations=$((violations + 1))
    done < <(_identity_find_material "$scan")
  done

  # 3. Shape of the identity store itself.
  local idir="${root}/var/lib/arlowe/identity"
  if [[ ! -e "$idir" ]]; then
    # Absent means install-arlowe-fs.sh did not run. Never correct on either
    # surface; an informational pass here would hide a silent provisioning skip.
    _identity_err "identity store missing: /var/lib/arlowe/identity"
    violations=$((violations + 1))
  elif [[ ! -d "$idir" ]]; then
    _identity_err "identity store is not a directory: /var/lib/arlowe/identity"
    violations=$((violations + 1))
  else
    local dmode
    dmode="$(_identity_mode "$idir")"
    if [[ "$dmode" != "700" ]]; then
      _identity_err "identity store mode is 0${dmode}, expected 0700: /var/lib/arlowe/identity"
      violations=$((violations + 1))
    fi

    local f fmode
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      fmode="$(_identity_mode "$f")"
      if [[ "$fmode" != "600" ]]; then
        _identity_err "identity file mode is 0${fmode}, expected 0600: ${f#"$root"}"
        violations=$((violations + 1))
      fi
    done < <(find "$idir" -type f -print 2>/dev/null)

    # 4. A factory image must ship an empty store. install-arlowe-fs.sh creates
    #    this directory in the slot-A rootfs, so this assertion fires for real
    #    at build time against a present, empty, 0700 directory.
    if [[ "$factory" -eq 1 ]]; then
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        _identity_err "factory image ships identity material: ${f#"$root"} — every unit would receive the same secret"
        violations=$((violations + 1))
      done < <(find "$idir" -mindepth 1 -print 2>/dev/null)
    fi
  fi

  if [[ "$violations" -gt 0 ]]; then
    printf '[identity-store] %s violation(s) found under %s\n' "$violations" "${root:-/}" >&2
    return 1
  fi
  printf '[identity-store] clean: %s\n' "${root:-/}"
  return 0
}
