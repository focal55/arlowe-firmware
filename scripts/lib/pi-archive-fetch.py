#!/usr/bin/env python3
"""Locate, optionally fetch, and verify every deb in third_party/pi-archive/manifest.yml.

    pi-archive-fetch.py --manifest M --repo-root R --paths-out P

Covers `packages` and `resolve_only` alike. Each deb is looked up, first hit wins, in:
  1. $ARLOWE_PI_ARCHIVE_DIR
  2. R/third_party/pi-archive
  3. /var/cache/arlowe-build/pi-archive  ($ARLOWE_PI_ARCHIVE_SHARED_CACHE overrides it)
  4. ${XDG_CACHE_HOME:-~/.cache}/arlowe-build/pi-archive

With ARLOWE_PI_ARCHIVE_FETCH=1 a missing deb is downloaded from its `url` into the
first of 3 and 4 that is writable. `url` is only how a deb is obtained the first
time; the sha256 is the pin, checked on every deb whether fetched or found.

On success P gets one `filename<TAB>absolute path` line per deb, for the build's
flat repo. P is removed before anything else so a failed run never leaves one.

Exit 0 all verified, 1 any deb failed, 2 could not run.
"""
import argparse
import hashlib
import http.client
import os
import sys
import tempfile
import time
import urllib.request

import yaml

TAG = "[pi-archive]"
CHUNK = 1 << 20


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def mismatch(path, entry):
    """None if path holds the pinned bytes, else a one-line reason."""
    size = os.path.getsize(path)
    if size != entry["size"]:
        return "size mismatch: expected %d, actual %d" % (entry["size"], size)
    actual = sha256(path)
    if actual != entry["sha256"]:
        return "sha256 mismatch: expected %s, actual %s" % (entry["sha256"], actual)
    return None


def writable_dir(path):
    try:
        os.makedirs(path, exist_ok=True)
    except OSError:
        return False
    return os.access(path, os.W_OK | os.X_OK)


def fetch_dir(shared, user):
    if writable_dir(shared):
        return shared
    if writable_dir(user):
        print("%s %s not writable; caching in %s" % (TAG, shared, user))
        return user
    return None


def fetch(entry, dest_dir):
    """Download to <final>.part, and give it its final name only once it verifies."""
    final = os.path.join(dest_dir, entry["filename"])
    part = final + ".part"
    err = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(entry["url"], timeout=60) as r, open(part, "wb") as f:
                for chunk in iter(lambda: r.read(CHUNK), b""):
                    f.write(chunk)
            break
        except (OSError, http.client.HTTPException) as e:
            err = "download failed: %s" % e
            if attempt < 2:
                time.sleep(2)
    else:
        if os.path.exists(part):
            os.remove(part)
        return None, err
    bad = mismatch(part, entry)
    if bad:
        os.remove(part)
        return None, "fetched bytes rejected, " + bad
    os.replace(part, final)
    return final, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--repo-root", required=True)
    ap.add_argument("--paths-out", required=True)
    a = ap.parse_args()

    try:
        os.remove(a.paths_out)
    except FileNotFoundError:
        pass

    try:
        with open(a.manifest) as f:
            m = yaml.safe_load(f) or {}
        entries = (m.get("packages") or []) + (m.get("resolve_only") or [])
    except (OSError, AttributeError, yaml.YAMLError) as e:
        print("%s ERROR cannot read %s: %s" % (TAG, a.manifest, e), file=sys.stderr)
        return 2
    if not entries:
        print("%s ERROR %s names no debs" % (TAG, a.manifest), file=sys.stderr)
        return 2

    shared = os.environ.get("ARLOWE_PI_ARCHIVE_SHARED_CACHE") or "/var/cache/arlowe-build/pi-archive"
    xdg = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    user = os.path.join(xdg, "arlowe-build", "pi-archive")
    dirs = [os.path.join(a.repo_root, "third_party", "pi-archive"), shared, user]
    if os.environ.get("ARLOWE_PI_ARCHIVE_DIR"):
        dirs.insert(0, os.environ["ARLOWE_PI_ARCHIVE_DIR"])
    fetching = os.environ.get("ARLOWE_PI_ARCHIVE_FETCH") == "1"
    dest = None

    paths, failures, fetched = {}, [], 0
    for e in entries:
        name = e["filename"]
        path = next((os.path.join(d, name) for d in dirs if os.path.isfile(os.path.join(d, name))), None)
        if path:
            bad = mismatch(path, e)
            if bad:
                failures.append("%s: %s (%s)" % (name, bad, path))
                continue
        elif not fetching:
            failures.append("%s: not found in any cache; set ARLOWE_PI_ARCHIVE_FETCH=1 to download it" % name)
            continue
        else:
            dest = dest or fetch_dir(shared, user)
            if not dest:
                failures.append("%s: ARLOWE_PI_ARCHIVE_FETCH=1 but neither %s nor %s is writable" % (name, shared, user))
                continue
            print("%s fetching %s" % (TAG, name))
            path, bad = fetch(e, dest)
            if bad:
                failures.append("%s: %s" % (name, bad))
                continue
            fetched += 1
        paths[name] = os.path.abspath(path)

    if failures:
        for f in failures:
            print("%s FAIL %s" % (TAG, f), file=sys.stderr)
        print("%s %d of %d debs failed." % (TAG, len(failures), len(entries)), file=sys.stderr)
        if any("mismatch" in f for f in failures):
            print("%s If the pool changed deliberately, regenerate the manifest through the pin-bump\n"
                  "procedure (docs/operations/phase-07.3-pi-archive-pinning.md); never hand-edit it."
                  % TAG, file=sys.stderr)
        return 1

    out_dir = os.path.dirname(os.path.abspath(a.paths_out))
    os.makedirs(out_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=out_dir, prefix=".pi-archive-paths.")
    with os.fdopen(fd, "w") as f:
        for name in sorted(paths):
            f.write("%s\t%s\n" % (name, paths[name]))
    os.replace(tmp, a.paths_out)
    print("%s %d debs verified (%d fetched)" % (TAG, len(paths), fetched))
    return 0


if __name__ == "__main__":
    sys.exit(main())
