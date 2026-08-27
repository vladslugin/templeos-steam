#!/usr/bin/env python3
"""
install_layer.py - put the whole game layer onto a disk image, in one command.

Until this existed the layer went onto the image a file at a time, by hand,
whenever one of them changed. That works right up until it does not, and the
way it fails is quiet: the image ends up with yesterday's TaskRunner and three
of the four campaign tasks missing their starter files, and everything a test
touches still passes because the tests deploy what they need themselves. Found
exactly that way.

So this copies all of it, every time, and says what it wrote:

    guest/Game/**           the layer, including each task's Start and Solution
    guest/Home/MakeHome.HC  the one line that starts it at boot

    python tools/install_layer.py                       build/temple_disk.raw
    python tools/install_layer.py --image other.raw
    python tools/install_layer.py --check               compare, change nothing

The image must not be open in an emulator - fat32.py refuses, and it is right
to: both ends cache the same sectors and the loser is whoever writes first.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from fat32 import Fat32, in_use_by  # noqa: E402

DEFAULT_IMAGE = os.path.join(ROOT, "build", "temple_disk.raw")

# Source on the host, destination in the guest. Directories are walked.
LAYOUT = [
    (os.path.join(ROOT, "guest", "Game"), "/Game"),
    (os.path.join(ROOT, "guest", "Home", "MakeHome.HC"), "/Home/MakeHome.HC"),
]


def walk(src: str, dst: str):
    """(host path, guest path) for every file under src."""
    if os.path.isfile(src):
        yield src, dst
        return
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames.sort()
        rel = os.path.relpath(dirpath, src).replace(os.sep, "/")
        here = dst if rel == "." else dst + "/" + rel
        for name in sorted(filenames):
            yield os.path.join(dirpath, name), here + "/" + name


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:12]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", nargs="?", default=DEFAULT_IMAGE)
    ap.add_argument("--check", action="store_true",
                    help="report what differs and write nothing")
    ap.add_argument("--force", action="store_true",
                    help="write even if an emulator has the image open")
    args = ap.parse_args()

    if not os.path.isfile(args.image):
        print("no image at %s" % args.image, file=sys.stderr)
        return 1

    if not args.check and not args.force:
        busy = in_use_by(args.image)
        if busy:
            print("refusing to write: %s is open in a running emulator"
                  % args.image, file=sys.stderr)
            for pid, cmd in busy:
                print("  pid %s  %s" % (pid, cmd[:140]), file=sys.stderr)
            return 2

    fs = Fat32(args.image, None, readonly=args.check)

    made_dirs: set[str] = set()
    same = changed = added = 0

    for src, dst in [(s, d) for a, b in LAYOUT for s, d in walk(a, b)]:
        with open(src, "rb") as fh:
            want = fh.read()

        try:
            have = fs.read_file(dst)
        except Exception:
            have = None

        if have == want:
            same += 1
            continue

        state = "changed" if have is not None else "added"
        if state == "added":
            added += 1
        else:
            changed += 1
        print("  %-7s %-32s %6d bytes  %s" % (state, dst, len(want),
                                              digest(want)))
        if args.check:
            continue

        parent = dst.rsplit("/", 1)[0]
        if parent and parent not in made_dirs:
            made_dirs.add(parent)
            try:
                fs.mkdir(parent)
            except Exception:
                pass          # already there, which is the usual case
        fs.write_file(dst, want)

    total = same + changed + added
    if args.check:
        print("\n%d file(s): %d already right, %d would change, %d would be added"
              % (total, same, changed, added))
        return 1 if (changed or added) else 0

    print("\n%d file(s): %d unchanged, %d rewritten, %d new"
          % (total, same, changed, added))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
