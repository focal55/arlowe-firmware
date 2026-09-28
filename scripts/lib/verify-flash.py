#!/usr/bin/env python3
"""Read a flashed card back and compare it with the image it was written from.

usage: verify-flash.py IMAGE TARGET [--bmap FILE]

bmaptool checksums what it reads from the image, never what lands on the card,
so a reader that drops or misplaces writes still reports success. On 2026-09-27
one landed runs of writes 64 KiB low and the card booted with four services
dead. This is the only check that looks at the card itself.

With --bmap only the mapped ranges are compared: bmaptool never writes the
holes, so the card keeps whatever was there before. Without it the whole image
is compared. A block device is read past the page cache (O_DIRECT on Linux,
F_NOCACHE on macOS; pass /dev/rdiskN there), otherwise the read-back could be
served from the very buffers that were just written.

Exit 0: every compared block matches. 1: a block differs or the target is too
short. 2: usage error or unreadable input.
"""
import mmap
import os
import re
import stat
import sys

CHUNK_BLOCKS = 256
REPORT = 20


def fail_usage(msg):
    print(f"[flash-verify] ERROR {msg}", file=sys.stderr)
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    sys.exit(2)


def parse_args(argv):
    args = [a for a in argv if not a.startswith("--")]
    bmap = None
    if "--bmap" in argv:
        i = argv.index("--bmap")
        if i + 1 >= len(argv):
            fail_usage("--bmap needs a file")
        bmap = argv[i + 1]
        args.remove(bmap)
    if len(args) != 2:
        fail_usage("need IMAGE and TARGET")
    return args[0], args[1], bmap


def load_ranges(bmap_path, image_size):
    if bmap_path is None:
        return 4096, [(0, (image_size + 4095) // 4096 - 1)]
    text = open(bmap_path).read()
    m = re.search(r"<BlockSize>\s*(\d+)\s*</BlockSize>", text)
    if not m:
        fail_usage(f"{bmap_path}: no <BlockSize>")
    ranges = [(int(a), int(b or a)) for a, b in
              re.findall(r"<Range[^>]*>\s*(\d+)(?:\s*-\s*(\d+))?\s*</Range>", text)]
    if not ranges:
        fail_usage(f"{bmap_path}: no <Range> entries")
    return int(m.group(1)), ranges


def open_uncached(path):
    if not stat.S_ISBLK(os.stat(path).st_mode):
        return os.open(path, os.O_RDONLY), False
    if hasattr(os, "O_DIRECT"):
        return os.open(path, os.O_RDONLY | os.O_DIRECT), True
    fd = os.open(path, os.O_RDONLY)
    import fcntl
    fcntl.fcntl(fd, fcntl.F_NOCACHE, 1)
    return fd, True


def main():
    image, target, bmap = parse_args(sys.argv[1:])
    try:
        image_size = os.path.getsize(image)
        bs, ranges = load_ranges(bmap, image_size)
        img = open(image, "rb")
        fd, direct = open_uncached(target)
    except OSError as e:
        fail_usage(str(e))
    buf = mmap.mmap(-1, CHUNK_BLOCKS * bs)
    bad, checked = [], 0
    for first, last in ranges:
        b = first
        while b <= last:
            n = min(CHUNK_BLOCKS, last - b + 1)
            img.seek(b * bs)
            want = img.read(n * bs)
            os.lseek(fd, b * bs, os.SEEK_SET)
            got_len = os.readv(fd, [memoryview(buf)[:n * bs]])
            if got_len < len(want):
                print(f"[flash-verify] FAIL target is shorter than the image: "
                      f"read {got_len} bytes at offset {b * bs}, expected {len(want)}")
                sys.exit(1)
            got = buf[:len(want)]
            if got != want:
                for i in range(0, len(want), bs):
                    if got[i:i + bs] != want[i:i + bs]:
                        bad.append(b * bs + i)
            checked += n
            b += n
    os.close(fd)
    mode = "mapped" if bmap else "all"
    print(f"[flash-verify] {checked} {mode} blocks of {bs} bytes read back"
          f"{' uncached' if direct else ''}, {len(bad)} differ")
    if bad:
        print("[flash-verify] FAIL first differing byte offsets: "
              + ", ".join(str(o) for o in bad[:REPORT]))
        sys.exit(1)


if __name__ == "__main__":
    main()
