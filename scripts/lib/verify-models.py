#!/usr/bin/env python3
"""Verify model files against third_party/models/manifest.yml, file by file.

    verify-models.py --manifest M --root DIR [--model KEY] [--exact]

Every file a model entry lists is looked up at DIR/<filename> and must match its
sha256. A TODO placeholder digest is a failure: a pin that was never recorded
verifies nothing, and a warning let all four ship unchecked for three months.

--exact additionally fails on any regular file under DIR that no entry lists.
build-image.sh runs it over the staged models tree, which is what ships;
02-models copies whole directories, so anything extra in the cache would
otherwise reach the image unverified.

Exit 0 all verified, 1 any failure, 2 could not run.
"""
import argparse
import hashlib
import os
import sys

import yaml

EXEMPT_DIRS = {"lost+found"}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--model")
    ap.add_argument("--exact", action="store_true")
    a = ap.parse_args()

    try:
        with open(a.manifest) as f:
            models = yaml.safe_load(f)["models"]
    except (OSError, KeyError, TypeError, yaml.YAMLError) as e:
        print("[models] ERROR cannot read %s: %s" % (a.manifest, e), file=sys.stderr)
        return 2
    if a.model:
        if a.model not in models:
            print("[models] ERROR no model %r in manifest" % a.model, file=sys.stderr)
            return 2
        models = {a.model: models[a.model]}

    failed = 0
    listed = set()
    for key, entry in models.items():
        files = entry.get("files") or []
        if not files:
            print("[models] FAIL %s lists no files" % key)
            failed += 1
        for spec in files:
            rel, want = spec["filename"], spec["sha256"]
            listed.add(os.path.normpath(rel))
            path = os.path.join(a.root, rel)
            if want.startswith("TODO"):
                print("[models] FAIL %s: placeholder digest %s" % (rel, want))
                failed += 1
            elif not os.path.isfile(path):
                print("[models] FAIL %s: missing under %s" % (rel, a.root))
                failed += 1
            else:
                got = sha256(path)
                if got == want:
                    print("[models] OK   %s" % rel)
                else:
                    print("[models] FAIL %s: sha256 mismatch\n"
                          "         expected %s\n         actual   %s" % (rel, want, got))
                    failed += 1

    if a.exact:
        for dirpath, dirnames, filenames in os.walk(a.root):
            if dirpath == a.root:
                dirnames[:] = [d for d in dirnames if d not in EXEMPT_DIRS]
            for name in filenames:
                rel = os.path.relpath(os.path.join(dirpath, name), a.root)
                if os.path.normpath(rel) not in listed:
                    print("[models] FAIL %s: not in the manifest, would ship unverified" % rel)
                    failed += 1

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
