#!/usr/bin/env python3
"""Generate third_party/pi-archive/manifest.yml from a resolved package set.

    pi-archive-manifest.py generate (--installed-reference REF | --installed-status S)
        --pi-list P... --debian-list P... --kernel-manifest M --pool-base URL --out F
        [--allow-local N...] [--resolve-only NAME[=VERSION]...]

The installed set is the `pkg` rows of an inputs-reference file, or the
`install ok installed` stanzas of a dpkg status file. Index lists may be
plain, .gz or .xz.

Attribution per installed (name, version, arch); a stanza matches on name,
version and Architecture equal to arch or `all`.
  - armhf installed: failure. The image is arm64-only.
  - kernel package (third_party/kernel/manifest.yml): excluded, it is pinned
    there. At any version other than that pin it is a failure.
  - Pi archive only: a manifest entry. The Pi archive has no snapshot service,
    so these are what this manifest pins.
  - both archives, identical sha256: left to the Debian snapshot pin.
  - both archives, different sha256: failure. Origin would be apt's tie-break.
  - neither: failure, unless named by --allow-local.
Zero entries is a failure: an empty manifest pins nothing and says it succeeded.

--resolve-only names a Pi package apt must be able to locate but that is never
installed (an upstream stage list names it as a removal marker). It goes under
resolve_only. Failure if it is installed, or if its Pi stanzas do not resolve to
exactly one version and sha256.

Exit 0 written, 1 attribution failure (every one is reported, nothing is
written), 2 could not run.
"""
import argparse
import gzip
import json
import lzma
import os
import sys
import tempfile

import yaml

KEEP = ("Package", "Version", "Architecture", "Filename", "Size", "SHA256")
KEY_ORDER = ("name", "version", "arch", "filename", "size", "sha256", "url", "why")
REFUSED_SUFFIXES = (".lz4", ".bz2", ".zst", ".lzma", ".Z")
RESOLVE_ONLY_WHY = ("named by an upstream pi-gen package list as a removal marker; "
                    "apt must be able to locate it, it is never installed")


class InputError(Exception):
    pass


def read_text(path, opener=open):
    try:
        with opener(path, "rt", encoding="utf-8") as f:
            return f.read()
    except (OSError, EOFError, UnicodeDecodeError, lzma.LZMAError) as e:
        raise InputError("cannot read %s: %s" % (path, e))


def parse_stanzas(text, keep):
    stanzas, cur = [], {}
    for line in text.splitlines():
        if not line.strip():
            if cur:
                stanzas.append(cur)
            cur = {}
        elif line[0] in " \t":
            continue
        elif ":" in line:
            k, v = line.split(":", 1)
            if k in keep:
                cur[k] = v.strip()
    if cur:
        stanzas.append(cur)
    return stanzas


def open_index(path):
    """Parse a plain, .gz or .xz Packages index into stanza dicts (KEEP fields only)."""
    if path.endswith(REFUSED_SUFFIXES):
        raise InputError(
            "%s: unsupported index compression. apt in a docker image stores .lz4 lists "
            "because of /etc/apt/apt.conf.d/docker-gzip-indexes; delete that file before "
            "apt-get update, or pass a plain, .gz or .xz index" % path)
    opener = gzip.open if path.endswith(".gz") else lzma.open if path.endswith(".xz") else open
    return parse_stanzas(read_text(path, opener), KEEP)


def load_indexes(paths):
    index = {}
    for p in paths:
        for s in open_index(p):
            if "Package" in s and "Version" in s:
                index.setdefault((s["Package"], s["Version"]), []).append(s)
    return index


def load_installed_reference(path):
    """(name, version, arch) for every `pkg` row of an inputs-reference file."""
    rows = []
    for line in read_text(path).splitlines():
        f = line.split("\t")
        if f[0] == "pkg":
            if len(f) != 4:
                raise InputError("%s: malformed pkg row %r" % (path, line))
            rows.append(tuple(f[1:]))
    return rows


def load_installed_status(path):
    """(name, version, arch) for every `install ok installed` stanza of a dpkg status file."""
    rows = []
    for s in parse_stanzas(read_text(path), ("Package", "Status", "Version", "Architecture")):
        if s.get("Status") == "install ok installed":
            if not all(k in s for k in ("Package", "Version", "Architecture")):
                raise InputError("%s: installed stanza lacks Package, Version or Architecture: %r"
                                 % (path, s))
            rows.append((s["Package"], s["Version"], s["Architecture"]))
    return rows


def pi_entry(s, pool_base):
    return {
        "name": s["Package"], "version": s["Version"], "arch": s["Architecture"],
        "filename": os.path.basename(s["Filename"]), "size": int(s["Size"]),
        "sha256": s["SHA256"], "url": pool_base.rstrip("/") + "/" + s["Filename"],
    }


def complete(s):
    return bool(s.get("Filename") and s.get("SHA256") and s.get("Size", "").isdigit())


def resolve_only(specs, installed, pi, pool_base):
    entries, failures = [], []
    installed_names = {name for name, _, _ in installed}
    for spec in specs:
        name, _, version = spec.partition("=")
        if name in installed_names:
            failures.append("%s: resolve-only package is installed" % spec)
            continue
        hits = [s for (n, v), ss in sorted(pi.items()) if n == name and version in ("", v)
                for s in ss]
        found = sorted({(s["Version"], s.get("SHA256")) for s in hits})
        if len(found) != 1:
            failures.append("%s: resolve-only needs exactly one Pi version and sha256, found %d: %s"
                            % (spec, len(found), ", ".join(v for v, _ in found) or "none"))
            continue
        if not complete(hits[0]):
            failures.append("%s: Pi stanza lacks Filename, SHA256 or a numeric Size" % spec)
            continue
        entries.append(dict(pi_entry(hits[0], pool_base), why=RESOLVE_ONLY_WHY))
    return sorted(entries, key=lambda e: e["name"]), failures


def load_kernel(path):
    try:
        k = yaml.safe_load(read_text(path))["kernel"]
        names = {d["filename"].split("_", 1)[0] for d in k["debs"]}
        return names, k["deb_version"]
    except (KeyError, TypeError, AttributeError, yaml.YAMLError) as e:
        raise InputError("%s: not a kernel manifest: %s" % (path, e))


def matches(index, name, version, arch):
    return [s for s in index.get((name, version), [])
            if s.get("Architecture") in (arch, "all")]


def attribute(installed, pi, deb, kernel_names, kernel_ver, allow_local, pool_base):
    entries, failures = [], []
    skipped = {"debian-identical": 0, "kernel": 0, "local": 0}
    for name, version, arch in installed:
        where = "%s %s %s" % (name, version, arch)
        if arch == "armhf":
            failures.append("%s: armhf is installed; the image is arm64-only" % where)
            continue
        if name in kernel_names:
            if version.split(":", 1)[-1] != kernel_ver:
                failures.append("%s: kernel package off the kernel pin %s" % (where, kernel_ver))
            else:
                skipped["kernel"] += 1
            continue
        pi_hits, deb_hits = matches(pi, name, version, arch), matches(deb, name, version, arch)
        if not pi_hits and not deb_hits:
            if name in allow_local:
                skipped["local"] += 1
            else:
                failures.append("%s: in neither archive and not --allow-local" % where)
            continue
        if not pi_hits:
            continue
        pi_shas = {s.get("SHA256") for s in pi_hits}
        if len(pi_shas) != 1:
            failures.append("%s: Pi lists disagree on sha256: %s" % (where, sorted(map(str, pi_shas))))
            continue
        s = pi_hits[0]
        if deb_hits:
            deb_shas = {d.get("SHA256") for d in deb_hits}
            if s.get("SHA256") in deb_shas:
                skipped["debian-identical"] += 1
            else:
                failures.append("%s: both archives carry it with different bytes: pi %s, debian %s"
                                % (where, s.get("SHA256"), ", ".join(sorted(map(str, deb_shas)))))
            continue
        if not complete(s):
            failures.append("%s: Pi stanza lacks Filename, SHA256 or a numeric Size" % where)
            continue
        entries.append(pi_entry(s, pool_base))
    if not entries:
        failures.append("zero Pi-only packages attributed; refusing to write an empty manifest")
    return sorted(entries, key=lambda e: (e["name"], e["arch"])), failures, skipped


def duplicate_filenames(entries):
    seen, failures = {}, []
    for e in entries:
        if e["filename"] in seen:
            failures.append("%s: duplicate filename, also %s" % (e["filename"], seen[e["filename"]]))
        seen[e["filename"]] = e["name"]
    return failures


def flow(entry):
    return "{" + ", ".join("%s: %s" % (k, entry[k] if k == "size" else json.dumps(entry[k]))
                           for k in KEY_ORDER if k in entry) + "}"


def write_manifest(out, pool_base, entries, resolve_only):
    lines = [
        "# GENERATED by scripts/lib/pi-archive-manifest.py. Do not hand-edit;",
        "# regenerate through the pin-bump procedure.",
        "# `url` is how a deb is first obtained. `sha256` is the pin.",
        "pool_base: %s" % json.dumps(pool_base),
        "packages:",
    ] + ["  - " + flow(e) for e in entries]
    if resolve_only:
        lines += ["resolve_only:"] + ["  - " + flow(e) for e in resolve_only]
    else:
        lines.append("resolve_only: []")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(out)), prefix=".pi-archive.")
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, out)


def cmd_generate(a):
    try:
        installed = (load_installed_reference(a.installed_reference) if a.installed_reference
                     else load_installed_status(a.installed_status))
        pi, deb = load_indexes(a.pi_list), load_indexes(a.debian_list)
        kernel_names, kernel_ver = load_kernel(a.kernel_manifest)
    except InputError as e:
        print("[pi-archive] ERROR %s" % e, file=sys.stderr)
        return 2
    entries, failures, skipped = attribute(installed, pi, deb, kernel_names, kernel_ver,
                                           set(a.allow_local), a.pool_base)
    extra, ro_failures = resolve_only(a.resolve_only, installed, pi, a.pool_base)
    failures += ro_failures + duplicate_filenames(entries + extra)
    if failures:
        for f in failures:
            print("[pi-archive] FAIL %s" % f, file=sys.stderr)
        return 1
    try:
        write_manifest(a.out, a.pool_base, entries, extra)
    except OSError as e:
        print("[pi-archive] ERROR cannot write %s: %s" % (a.out, e), file=sys.stderr)
        return 2
    print("[pi-archive] %d packages, %d resolve_only; skipped: %d debian-identical, %d kernel, %d local"
          % (len(entries), len(extra), skipped["debian-identical"], skipped["kernel"], skipped["local"]))
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate", help="write the manifest from a resolved package set")
    installed = g.add_mutually_exclusive_group(required=True)
    installed.add_argument("--installed-reference")
    installed.add_argument("--installed-status")
    g.add_argument("--pi-list", action="append", required=True)
    g.add_argument("--debian-list", action="append", required=True)
    g.add_argument("--kernel-manifest", required=True)
    g.add_argument("--pool-base", required=True)
    g.add_argument("--out", required=True)
    g.add_argument("--allow-local", action="append", default=[])
    g.add_argument("--resolve-only", action="append", default=[], metavar="NAME[=VERSION]")
    g.set_defaults(func=cmd_generate)
    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
