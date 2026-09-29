#!/usr/bin/env python3
"""
Generate runtime/lib/arlowe_hostname_banlist.json from scripts/sanitize/banlist.txt.

Keeps only entries that can occur in a hostname slug (entirely [a-z0-9-] after
lowercasing) and writes their (length, sha256) pairs, never the literals.

Usage:
    gen-hostname-banlist.py            write the hash file
    gen-hostname-banlist.py --check    exit 1 if the committed file differs

Reports how many entries it kept, never which.
"""

import hashlib
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BANLIST = REPO_ROOT / "scripts/sanitize/banlist.txt"
OUTPUT = REPO_ROOT / "runtime/lib/arlowe_hostname_banlist.json"


def render():
    kept = set()
    for line in BANLIST.read_text(encoding="utf-8").splitlines():
        entry = line.strip().lower()
        if entry and not entry.startswith("#") and re.fullmatch(r"[a-z0-9-]+", entry):
            kept.add((len(entry), hashlib.sha256(entry.encode()).hexdigest()))
    records = [{"length": n, "sha256": h} for n, h in sorted(kept)]
    return json.dumps(records, indent=2) + "\n", len(records)


def main(argv):
    if argv not in ([], ["--check"]):
        print("usage: gen-hostname-banlist.py [--check]", file=sys.stderr)
        return 2
    text, count = render()
    if argv == ["--check"]:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != text:
            print(f"{OUTPUT.relative_to(REPO_ROOT)} is stale; run {Path(__file__).name}", file=sys.stderr)
            return 1
        print(f"hostname banlist in sync ({count} entries)")
        return 0
    OUTPUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(REPO_ROOT)} ({count} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
