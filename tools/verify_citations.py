#!/usr/bin/env python3
"""
verify_citations.py - check that every path:line citation actually says what we
claim it says.

The whole project rests on one rule: nothing about the OS gets asserted unless a
line of the 5.03 source backs it up. That rule is worthless if the line numbers
drift, so this walks the citations and opens each one.

Two modes:

  data/*.json     Structured entries with def_file/def_line. For an API entry the
                  function name has to appear at or near the cited line.
  markdown        Any `path/to/file.HC:123` in prose. Checks the file exists and
                  the line is in range - we cannot know what the prose meant, so
                  this catches drift and typos, not wrong interpretation.

One thing the tool cannot judge: a document may quote a citation in order to
reject it ("the claim cites X:277, but that file has 42 lines"). That shows up
here as a failure. Read the flagged line before fixing anything.

A note on assembly. Some kernel routines are declared in a header and implemented
as an asm label, so StrCmp lives behind `_STRCMP::`:

    Kernel/KernelC.HH:67   public _extern _STRCMP I64 StrCmp(U8 *st1,U8 *st2);
    Kernel/StrA.HC:85      _STRCMP::

Citing the label is correct, so `_NAME::` counts as a match for NAME.

Usage:
    python tools/verify_citations.py                 # data/ only
    python tools/verify_citations.py --markdown analysis
    python tools/verify_citations.py --strict        # non-zero exit on any miss
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# vendor/TempleOS/Kernel/KernelA.HH:3555  or  Doc/Charter.DD:56
# The optional drive letter keeps a Windows absolute path from being chopped at
# "C:" and then reported as a missing file.
CITATION_RE = re.compile(
    r"`?((?:[A-Za-z]:/)?(?:[\w.\-]+/)+[\w.\-]+\.(?:HC|HH|DD|TXT|MAP|PRJ|IN|py|sh|json)):(\d+)"
)

WINDOW = 2  # lines of slack either side, for small edits above a definition


class Result:
    def __init__(self):
        self.ok = 0
        self.asm = 0
        self.no_location = 0
        self.problems: list[tuple[str, str]] = []

    def fail(self, what: str, why: str):
        self.problems.append((what, why))

    @property
    def checked(self):
        return self.ok + self.asm + len(self.problems)


def read_lines(path: str):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def resolve(path: str) -> str | None:
    """Citations come in two shapes and both are legitimate.

    Repo-relative:  vendor/TempleOS/Doc/GuideLines.DD:3
    OS-relative:    Doc/GuideLines.DD:3        (how a path reads inside the OS)

    Try them in that order, plus a bare path for anything outside the snapshot.
    """
    candidates = (
        os.path.join(ROOT, path),
        os.path.join(ROOT, "vendor", "TempleOS", path),
        path,
    )
    for cand in candidates:
        if os.path.isfile(cand):
            return cand
    return None


def check_named(res: Result, name: str, path: str, line: int, label: str):
    full = resolve(path)
    if full is None:
        res.fail(label, f"file not found: {path}")
        return
    lines = read_lines(full)
    if not 1 <= line <= len(lines):
        res.fail(label, f"line {line} out of range, file has {len(lines)}")
        return
    window = "\n".join(lines[max(0, line - 1 - WINDOW): line + WINDOW])
    if re.search(r"\b" + re.escape(name) + r"\b", window):
        res.ok += 1
    elif re.search(r"_" + re.escape(name.upper()) + r"\s*::", window):
        res.asm += 1
    else:
        res.fail(label, f"{name!r} not at {path}:{line} -> {lines[line - 1].strip()[:70]!r}")


def check_range_only(res: Result, path: str, line: int, label: str):
    full = resolve(path)
    if full is None:
        res.fail(label, f"file not found: {path}")
        return
    lines = read_lines(full)
    if not 1 <= line <= len(lines):
        res.fail(label, f"line {line} out of range, file has {len(lines)}")
        return
    res.ok += 1


def check_api_index(res: Result, path: str):
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    for entry in doc.get("api", []):
        name = entry.get("name")
        f, ln = entry.get("def_file"), entry.get("def_line")
        if not f or not ln:
            res.no_location += 1
            continue
        check_named(res, name, f, int(ln), f"api_index/{name}")
        header = entry.get("header")
        if header and ":" in header:
            hp, _, hl = header.rpartition(":")
            if hl.isdigit():
                check_named(res, name, hp, int(hl), f"api_index/{name}(header)")


def check_json_hooks(res: Result, path: str):
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    for entry in doc.get("events", []):
        src = entry.get("hook_source")
        if not src or ":" not in src:
            continue
        p, _, ln = src.rpartition(":")
        if ln.isdigit():
            check_range_only(res, p, int(ln), f"events/{entry['id']}")


def check_markdown(res: Result, root: str):
    for dirpath, _dirs, files in os.walk(root):
        for fn in sorted(files):
            if not fn.endswith(".md"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
            for i, line in enumerate(read_lines(full), 1):
                for m in CITATION_RE.finditer(line):
                    check_range_only(res, m.group(1), int(m.group(2)), f"{rel}:{i}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--markdown", metavar="DIR", help="also sweep .md files under DIR")
    ap.add_argument("--strict", action="store_true", help="exit non-zero if anything fails")
    args = ap.parse_args()

    if not os.path.isdir(os.path.join(ROOT, "vendor", "TempleOS")):
        print("sources missing - run: bash tools/fetch_sources.sh", file=sys.stderr)
        return 1

    res = Result()

    api = os.path.join(ROOT, "data", "api_index.json")
    if os.path.isfile(api):
        check_api_index(res, api)

    events = os.path.join(ROOT, "data", "events.json")
    if os.path.isfile(events):
        check_json_hooks(res, events)

    if args.markdown:
        target = os.path.join(ROOT, args.markdown)
        if os.path.isdir(target):
            check_markdown(res, target)
        else:
            print(f"no such directory: {args.markdown}", file=sys.stderr)
            return 2

    print(f"citations checked : {res.checked}")
    print(f"  exact match     : {res.ok}")
    print(f"  asm entry point : {res.asm}")
    print(f"  no location     : {res.no_location}")
    print(f"  FAILED          : {len(res.problems)}")
    for what, why in res.problems[:40]:
        print(f"    {what}: {why}")
    if len(res.problems) > 40:
        print(f"    ... and {len(res.problems) - 40} more")

    return 1 if (args.strict and res.problems) else 0


if __name__ == "__main__":
    raise SystemExit(main())
