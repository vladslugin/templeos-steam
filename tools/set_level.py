#!/usr/bin/env python3
"""set_level.py - choose how much the guest meets a newcomer halfway.

Writes /Game/Level.HC on the disk image. The level has to be there before the
machine boots because it is a #define, not a setting: at level 0 the friendly
names must not merely be inert, they must not be defined at all, or the shell
answers `ls` and the promise of stock TempleOS 5.03 is not kept.

    python tools/set_level.py 0     stock - nothing is added
    python tools/set_level.py 1     learner - familiar names, a card, errors explained
    python tools/set_level.py 2     guided - and each name says what it stands for
    python tools/set_level.py       print what the disk is set to now

The emulator must not be running: writing a disk it has open corrupts it, and
fat32.in_use_by refuses rather than letting that happen.
"""

from __future__ import annotations

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from fat32 import Fat32, in_use_by  # noqa: E402

DEFAULT_IMAGE = os.path.join(ROOT, "build", "temple_disk.raw")
GUEST_PATH = "/Game/Level.HC"
SOURCE = os.path.join(ROOT, "guest", "Game", "Level.HC")

NAMES = {0: "stock", 1: "learner", 2: "guided"}


def render(level: int) -> bytes:
    """The file, with everything above the #define kept as written.

    The prose in guest/Game/Level.HC explains why this is a compile-time switch,
    and that explanation should not be rewritten by a script every time somebody
    changes difficulty. So the header is copied and only the two lines that say
    anything are generated.
    """
    with open(SOURCE, "rb") as f:
        text = f.read().decode("utf-8")
    head = text.split("#define GAME_LEVEL")[0].rstrip("\n")

    out = [head, "", "#define GAME_LEVEL\t%d" % level, ""]
    if level > 0:
        out += [
            "//Defined only above level 0. The include in GameInit turns on",
            "//#ifdef rather than on a comparison: #ifdef asks the compiler",
            "//whether it has heard of a symbol, which its lexer answers",
            "//directly (Compiler/Lex.HC:887), and there is then nothing to be",
            "//wrong about.",
            "#define GAME_NOVICE",
            "",
        ]
    else:
        out += [
            "//GAME_NOVICE is deliberately absent. /Game/Novice.HC is then not",
            "//compiled at all, and the machine is TempleOS 5.03 with a serial",
            "//link on it and nothing else.",
            "",
        ]
    return "\n".join(out).encode("ascii")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("level", nargs="?", type=int, choices=[0, 1, 2],
                    help="0 stock, 1 learner, 2 guided; omit to read it back")
    ap.add_argument("--image", default=DEFAULT_IMAGE)
    args = ap.parse_args()

    if not os.path.exists(args.image):
        print("no disk image at %s" % args.image, file=sys.stderr)
        return 1

    if args.level is None:
        fs = Fat32(args.image, None, readonly=True)
        try:
            data = fs.read_file(GUEST_PATH)
        except Exception:
            data = None
        finally:
            fs.close()
        if not data:
            print("%s is not on the disk; it will boot at the default" % GUEST_PATH)
            return 0
        for line in data.decode("ascii", "replace").splitlines():
            if line.startswith("#define GAME_LEVEL"):
                n = int(line.split()[-1])
                print("level %d - %s" % (n, NAMES.get(n, "?")))
                return 0
        print("could not find the level in %s" % GUEST_PATH, file=sys.stderr)
        return 1

    holder = in_use_by(args.image)
    if holder:
        print("refusing to write: the disk is open in a running emulator",
              file=sys.stderr)
        print("  %s" % holder, file=sys.stderr)
        return 1

    body = render(args.level)
    fs = Fat32(args.image, None, readonly=False)
    try:
        fs.write_file(GUEST_PATH, body)
    finally:
        fs.close()
    print("level %d - %s  (%d bytes to %s)"
          % (args.level, NAMES[args.level], len(body), GUEST_PATH))
    print("takes effect the next time the machine starts.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
