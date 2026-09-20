#!/bin/bash
# Build the Next.js dashboard into a standalone bundle, inside the pi-gen chroot.
#
# Runs as root, INSIDE the rootfs chroot, from 00-run-chroot.sh, against
# /opt/arlowe/runtime/dashboard which the runtime rsync has already populated
# with the source tree. On exit, that same directory holds the RUNNABLE bundle:
# server.js at the top, .next/static and public beside it, a pruned node_modules,
# and none of the source tree's build or test surfaces.
#
# units/arlowe-dashboard.service names /opt/arlowe/runtime/dashboard/server.js.
# Before Phase 7.1 nothing in the image pipeline ran a Next build anywhere, and
# next.config.ts had no `output` key, so that file could not exist under any
# build. Both halves are fixed: `output: "standalone"` in the config, and this.
#
# NODE. Not apt's. ADR-0008: bookworm's nodejs is 18.20.4, next@16.1.6 declares
# engines.node ">= 20.9.0", and bookworm-backports carries no nodejs at all, so
# apt cannot satisfy the floor at any pinning. `nodejs` and `npm` are dropped
# from 00-packages-nr and the interpreter is the SHA-256-pinned tarball in
# third_party/node/manifest.yml, unpacked to the prefix that manifest declares.
# The manifest pins Node 24 (Active LTS) rather than the 20 the phase brief
# suggested, because Node 20 reached end-of-life on 2026-04-30; 24 satisfies the
# same >= 20.9.0 floor. Do not "correct" it back.
#
# THE SHA IS VERIFIED HERE even though scripts/verify-third-party.sh also checks
# it on the host. Fetch-time and build-time are different moments, and the
# host-side gate does not protect a chroot that fetches its own copy.
#
# PACKAGE MANAGER. pnpm, not npm: runtime/dashboard has pnpm-lock.yaml and
# pnpm-workspace.yaml and no package-lock.json, so `npm ci` fails outright. The
# version is NOT written in this file. It is read from the `packageManager` field
# of the dashboard's own package.json, which is the single pin that
# .github/workflows/ci.yml also derives from. A second copy of a version string
# is a second thing to forget.
set -euo pipefail

DASH="${ARLOWE_DASHBOARD_DIR:-/opt/arlowe/runtime/dashboard}"
MANIFEST="${ARLOWE_NODE_MANIFEST:-/root/arlowe-build/repo/third_party/node/manifest.yml}"

log()  { printf '[build-dashboard] %s\n' "$*"; }
fail() { printf '[build-dashboard] ERROR: %s\n' "$*" >&2; exit 1; }

# Read a scalar from the manifest by EXACT key. An unanchored match would make
# `install_to` also select `install_to_image: true`, which would send the unpack
# to a directory named "true".
manifest_field() {
    awk -v key="$1:" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "${MANIFEST}"
}

# Compare dotted versions: version_ge A B is true when A >= B.
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

[[ -d "${DASH}" ]] || fail "dashboard source not found at ${DASH} (the runtime rsync in 00-run-chroot.sh must run first)"
[[ -f "${DASH}/package.json" ]] || fail "${DASH}/package.json missing"
[[ -f "${MANIFEST}" ]] || fail "node manifest not found at ${MANIFEST} (host-side 00-run.sh stages third_party/node)"

NODE_URL="$(manifest_field url)"
NODE_SHA="$(manifest_field sha256)"
NODE_PREFIX="$(manifest_field install_to)"
NODE_BIN="$(manifest_field node_bin)"
NODE_VERSION="$(manifest_field version)"
NODE_FLOOR="$(manifest_field version_floor)"

for f in NODE_URL NODE_SHA NODE_PREFIX NODE_BIN NODE_VERSION NODE_FLOOR; do
    [[ -n "${!f}" ]] || fail "manifest ${MANIFEST} is missing the field behind ${f}"
done

log "dashboard:    ${DASH}"
log "node manifest: ${MANIFEST} (v${NODE_VERSION}, floor >= ${NODE_FLOOR})"

# ---------------------------------------------------------------------------
# 1. Vendored Node: fetch, verify, unpack.
# ---------------------------------------------------------------------------
if [[ -x "${NODE_BIN}" ]]; then
    log "node already present at ${NODE_BIN} — skipping fetch"
else
    log "=== fetching node ${NODE_VERSION} ==="
    # A directory, not `mktemp -t node.XXXX.tar.xz`: GNU mktemp requires the X's
    # to terminate the template and rejects a trailing suffix outright.
    NODE_TMPDIR="$(mktemp -d)"
    TARBALL="${NODE_TMPDIR}/node.tar.xz"
    trap 'rm -rf "${NODE_TMPDIR}"' EXIT
    curl -fsSL "${NODE_URL}" -o "${TARBALL}" || fail "failed to fetch ${NODE_URL}"

    log "=== verifying sha256 against ${MANIFEST} ==="
    printf '%s  %s\n' "${NODE_SHA}" "${TARBALL}" | sha256sum -c - \
        || fail "sha256 mismatch for ${NODE_URL} — expected ${NODE_SHA}. Refusing to unpack."

    install -d -m 0755 "${NODE_PREFIX}"
    tar -xJf "${TARBALL}" -C "${NODE_PREFIX}" --strip-components=1 \
        || fail "failed to unpack node into ${NODE_PREFIX}"
    rm -rf "${NODE_TMPDIR}"
    trap - EXIT
fi

# ASSERTION (i). The ABSOLUTE path just unpacked, never `node` off PATH. A
# correct Node 24 sitting on PATH while the prefix holds something else is
# exactly the failure this line exists to catch, and PATH would hide it.
[[ -x "${NODE_BIN}" ]] || fail "${NODE_BIN} is missing or not executable after unpack"
NODE_ACTUAL="$("${NODE_BIN}" --version)"   # e.g. v24.21.0
NODE_ACTUAL="${NODE_ACTUAL#v}"
log "node at ${NODE_BIN}: v${NODE_ACTUAL}"
version_ge "${NODE_ACTUAL}" "${NODE_FLOOR}" \
    || fail "${NODE_BIN} is v${NODE_ACTUAL}, below the >= ${NODE_FLOOR} floor next@16 requires"

export PATH="${NODE_PREFIX}/bin:${PATH}"

# ---------------------------------------------------------------------------
# 2. pnpm, at exactly the pinned version.
#
# corepack is what Node ships for this and it resolves the `packageManager`
# field itself. Node 24 still bundles it (it is removed from the Node 25 line);
# if it is absent we fall back to a version-pinned global install via the npm in
# the same tarball. Either way the version comes from package.json, never from
# this file.
# ---------------------------------------------------------------------------
PM_SPEC="$("${NODE_BIN}" -p "require('${DASH}/package.json').packageManager || ''")"
[[ -n "${PM_SPEC}" ]] || fail "${DASH}/package.json has no packageManager field — the pnpm version is unpinned"
[[ "${PM_SPEC}" == pnpm@* ]] || fail "packageManager is '${PM_SPEC}', expected a pnpm@ spec"
PNPM_VERSION="${PM_SPEC#pnpm@}"
PNPM_VERSION="${PNPM_VERSION%%+*}"   # tolerate a corepack integrity suffix
log "=== activating ${PM_SPEC} ==="

if [[ -x "${NODE_PREFIX}/bin/corepack" ]]; then
    "${NODE_PREFIX}/bin/corepack" enable --install-directory "${NODE_PREFIX}/bin" \
        || fail "corepack enable failed"
    "${NODE_PREFIX}/bin/corepack" prepare "pnpm@${PNPM_VERSION}" --activate \
        || fail "corepack could not prepare pnpm@${PNPM_VERSION}"
else
    log "corepack absent in this Node build — falling back to a pinned global npm install"
    "${NODE_PREFIX}/bin/npm" install -g --no-fund --no-audit "pnpm@${PNPM_VERSION}" \
        || fail "npm install -g pnpm@${PNPM_VERSION} failed"
fi

PNPM_ACTUAL="$(pnpm --version)"
[[ "${PNPM_ACTUAL}" == "${PNPM_VERSION}" ]] \
    || fail "pnpm is ${PNPM_ACTUAL} but package.json pins ${PNPM_VERSION}; the lockfile is resolved by the pinned version or not at all"
log "pnpm ${PNPM_ACTUAL} matches the pin"

# ---------------------------------------------------------------------------
# 3. Install and build.
#
# devDependencies are REQUIRED here — `next build` needs typescript and the
# tailwind postcss plugin — so NODE_ENV is deliberately not set to production
# during the install. They do not survive into the bundle: the standalone output
# carries its own pruned node_modules and step 5 deletes this one.
# ---------------------------------------------------------------------------
cd "${DASH}"
SIZE_BEFORE="$(du -sh "${DASH}" | cut -f1)"

log "=== pnpm install --frozen-lockfile ==="
pnpm install --frozen-lockfile || fail "pnpm install failed"

log "=== next build (standalone) ==="
NEXT_TELEMETRY_DISABLED=1 pnpm build || fail "next build failed"

# ---------------------------------------------------------------------------
# 4. Relocate the standalone output.
#
# THIS STEP IS NOT OPTIONAL and skipping it is the classic standalone trap.
# `.next/standalone` holds server.js and a pruned node_modules but is incomplete
# by design: Next does not copy the static assets into it, on the assumption a
# CDN serves them. On a device with no CDN, the omission yields a server.js that
# boots, returns 200 for the document, and 404s every stylesheet and chunk — an
# unstyled page that looks like a CSS bug and is actually a packaging bug.
#
# server.js is LOCATED, not assumed. next.config.ts pins outputFileTracingRoot so
# the depth is deterministic, but a wrong guess here would produce a bundle that
# fails only on hardware, so the script discovers the file and hard-fails unless
# there is exactly one.
# ---------------------------------------------------------------------------
log "=== relocating standalone output ==="
[[ -d "${DASH}/.next/standalone" ]] \
    || fail ".next/standalone not produced — is output:\"standalone\" still set in next.config.ts?"

mapfile -t _found < <(find "${DASH}/.next/standalone" -maxdepth 6 -name server.js -type f)
(( ${#_found[@]} == 1 )) \
    || fail "expected exactly one server.js under .next/standalone, found ${#_found[@]}: ${_found[*]}"
SDIR="$(dirname "${_found[0]}")"
log "standalone entry point: ${_found[0]}"

STAGE="$(dirname "${DASH}")/.dashboard-standalone.$$"
rm -rf "${STAGE}"
mv "${SDIR}" "${STAGE}"

install -d "${STAGE}/.next"
[[ -d "${DASH}/.next/static" ]] || fail ".next/static missing — nothing to serve as assets"
cp -r "${DASH}/.next/static" "${STAGE}/.next/static"
if [[ -d "${DASH}/public" ]]; then
    cp -r "${DASH}/public" "${STAGE}/public"
else
    log "WARNING: no public/ in the source tree — skipping"
fi

# ---------------------------------------------------------------------------
# 5. Swap, which IS the cleanup.
#
# Replacing the directory wholesale is what removes the build-time node_modules
# (several hundred MB against the pruned copy's tens), .next/cache, and every
# source and test surface: tests/, playwright.config.ts, eslint.config.mjs,
# tsconfig.tsbuildinfo, app/. None of them were ever in the standalone output, so
# none of them come back. The explicit removals below are belt-and-braces for the
# case where a future dependency's file tracing drags one in.
# ---------------------------------------------------------------------------
rm -rf "${DASH}"
mv "${STAGE}" "${DASH}"

rm -rf "${DASH}/tests" "${DASH}/playwright.config.ts" "${DASH}/playwright-report" \
       "${DASH}/test-results" "${DASH}/tsconfig.tsbuildinfo" "${DASH}/eslint.config.mjs" \
       "${DASH}/.next/cache"

SIZE_AFTER="$(du -sh "${DASH}" | cut -f1)"
log "size: ${SIZE_BEFORE} (source + build tree) -> ${SIZE_AFTER} (shipped bundle)"

# ---------------------------------------------------------------------------
# 5b. Package-manager caches. These live OUTSIDE ${DASH}, so the directory swap
# above does not touch them and they would otherwise ship.
#
# pnpm's content-addressed global store holds a full copy of every package it
# resolved, which is the same order of magnitude as the node_modules we just
# deleted. corepack caches the pnpm tarball it fetched. Neither is reachable at
# runtime and both are build nondeterminism of exactly the kind the cleanup
# block at the end of 00-run-chroot.sh exists to remove — that block just cannot
# know these paths.
#
# Safe to delete after the relocation: Next's file tracing COPIES traced files
# into the standalone tree, and even where a copy shares an inode with a store
# entry, removing the store entry only drops a link, never the data.
# ---------------------------------------------------------------------------
log "=== removing package-manager caches (build-only, must not ship) ==="
PNPM_STORE="$(pnpm store path 2>/dev/null || true)"
for cache in "${PNPM_STORE}" "${HOME:-/root}/.local/share/pnpm" "${HOME:-/root}/.cache/node" \
             "${HOME:-/root}/.cache/pnpm" "${HOME:-/root}/.npm"; do
    if [[ -n "${cache}" && -d "${cache}" ]]; then
        log "  removing $(du -sh "${cache}" 2>/dev/null | cut -f1) ${cache}"
        rm -rf "${cache}"
    fi
done

# ---------------------------------------------------------------------------
# 6. Ownership, matching the rest of /opt/arlowe/runtime.
# ---------------------------------------------------------------------------
if getent group arlowe >/dev/null 2>&1; then
    chown -R root:arlowe "${DASH}"
    chmod -R g+rX,o+rX,go-w "${DASH}"
else
    log "WARNING: group 'arlowe' not found — leaving ownership unchanged"
fi
chown -R root:root "${NODE_PREFIX}"
chmod -R go-w "${NODE_PREFIX}"

# ---------------------------------------------------------------------------
# 7. Assert the shipped shape.
# ---------------------------------------------------------------------------
log "=== verifying ==="
for required in server.js .next/static; do
    [[ -e "${DASH}/${required}" ]] || fail "${DASH}/${required} is missing after relocation"
done
[[ ! -d "${DASH}/tests" ]] || fail "tests/ survived into the shipped bundle"

log "node:  ${NODE_BIN} v${NODE_ACTUAL}"
log "entry: ${DASH}/server.js"
log "complete"
