#!/usr/bin/env python3
"""
sync_host_data.py - copy the game data into the Godot project.

data/ is the source of truth: CI reads it, the guest table is generated from it,
and the launcher shows it. The launcher can only load what sits under res://, so
the files are copied rather than referenced - and copied by a script rather than
by hand, because two divergent copies of the task list is exactly the kind of
bug that shows up as a task that cannot be completed.

Run it after changing anything under data/:

    python tools/sync_host_data.py
    python tools/sync_host_data.py --check    # fail if the copy is stale
"""

from __future__ import annotations

import argparse
import filecmp
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "data")
DST = os.path.join(ROOT, "host", "temple", "data")

# Only what the launcher actually reads. The reference solutions are not here on
# purpose: they are the answer key, and the launcher has no business shipping
# them next to the tasks.
WANTED = [
    "events.json",
    "api_index.json",
    os.path.join("errors", "compiler_messages.json"),
]
WANTED_DIRS = ["tasks"]


def iter_files():
    for rel in WANTED:
        p = os.path.join(SRC, rel)
        if os.path.isfile(p):
            yield rel
    for d in WANTED_DIRS:
        base = os.path.join(SRC, d)
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            if name.endswith(".json"):
                yield os.path.join(d, name)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--check", action="store_true", help="report staleness, copy nothing")
    args = ap.parse_args()

    stale, copied = [], []
    for rel in iter_files():
        src = os.path.join(SRC, rel)
        dst = os.path.join(DST, rel)
        same = os.path.isfile(dst) and filecmp.cmp(src, dst, shallow=False)
        if same:
            continue
        if args.check:
            stale.append(rel)
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        copied.append(rel)

    # A file left behind in the copy is as bad as a missing one - it would show
    # a task the campaign no longer has.
    expected = set(iter_files())
    orphans = []
    for dirpath, _dirs, files in os.walk(DST):
        for name in files:
            if not name.endswith(".json"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), DST)
            if rel.replace("/", os.sep) not in {e.replace("/", os.sep) for e in expected}:
                orphans.append(rel)
                if not args.check:
                    os.unlink(os.path.join(DST, rel))

    if args.check:
        if stale or orphans:
            for rel in stale:
                print(f"stale: {rel}", file=sys.stderr)
            for rel in orphans:
                print(f"orphan: {rel}", file=sys.stderr)
            print("run: python tools/sync_host_data.py", file=sys.stderr)
            return 1
        print(f"up to date: {len(list(iter_files()))} file(s)")
        return 0

    for rel in copied:
        print(f"  copied  {rel}")
    for rel in orphans:
        print(f"  removed {rel}")
    print(f"{len(list(iter_files()))} file(s) in {os.path.relpath(DST, ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
