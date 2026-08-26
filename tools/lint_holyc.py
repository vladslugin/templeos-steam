#!/usr/bin/env python3
r"""
lint_holyc.py - catch HolyC traps that fail silently.

Right now it checks one thing, because that one thing cost an afternoon.

BLOCK COMMENTS NEST IN HOLYC. In C they do not - C89 and C99 both say the first
`*/` ends the comment, so `/* see foo/*.c */` is a complete comment. HolyC counts
depth instead (vendor/TempleOS/Compiler/Lex.HC:1123-1145: `j++` on `/*`, `j--` on
`*/`, loop `while (j)`), and CCmpCtrl even carries a comment_depth field
(Kernel/KernelA.HH:1163).

So a `/*` inside a block comment - a glob like `data/tasks/*.json`, a path like
`Adam/Gr/*`, a bit of maths - opens a nested comment. The visible `*/` closes
only that one, and the lexer eats the rest of the file, hits EOF and returns
quietly. No error, no diagnostic. The include appears to succeed in microseconds,
nothing is defined, and the terminal is left wedged.

That is the worst possible failure mode for a beginner and it is invisible on
review, so it gets a linter.

Usage:
    python tools/lint_holyc.py                 # check guest/
    python tools/lint_holyc.py path [path ...]
"""

from __future__ import annotations

import argparse
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def check_comments(text: str) -> list[tuple[int, str]]:
    """Return (line, message) for every unbalanced nested block comment."""
    problems = []
    depth = 0
    opened_at: list[int] = []
    line = 1
    i = 0
    n = len(text)
    in_line_comment = False
    in_string = False
    in_char = False

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if c == "\n":
            line += 1
            in_line_comment = False
            i += 1
            continue

        if in_line_comment:
            i += 1
            continue

        if depth == 0:
            # Track strings so a "/*" inside a literal is not mistaken for one.
            if in_string:
                if c == "\\":
                    i += 2
                    continue
                if c == '"':
                    in_string = False
                i += 1
                continue
            if in_char:
                if c == "\\":
                    i += 2
                    continue
                if c == "'":
                    in_char = False
                i += 1
                continue
            if c == '"':
                in_string = True
                i += 1
                continue
            if c == "'":
                in_char = True
                i += 1
                continue
            if c == "/" and nxt == "/":
                in_line_comment = True
                i += 2
                continue

        if c == "/" and nxt == "*":
            depth += 1
            opened_at.append(line)
            if depth > 1:
                problems.append((
                    line,
                    f"'/*' inside a block comment opened at line {opened_at[0]} - "
                    f"HolyC nests comments, so the matching '*/' will only close "
                    f"this inner one and the rest of the file is swallowed",
                ))
            i += 2
            continue

        if c == "*" and nxt == "/" and depth:
            depth -= 1
            opened_at.pop()
            i += 2
            continue

        i += 1

    if depth:
        problems.append((opened_at[0], f"block comment opened here is never closed "
                                       f"(depth {depth} at end of file)"))
    return problems


def check_file(path: str) -> list[str]:
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
    return [f"{rel}:{line}: {msg}" for line, msg in check_comments(text)]


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("paths", nargs="*", help="files or directories (default: guest/)")
    args = ap.parse_args()

    targets = args.paths or [os.path.join(ROOT, "guest")]
    files: list[str] = []
    for t in targets:
        if os.path.isdir(t):
            files += glob.glob(os.path.join(t, "**", "*.HC"), recursive=True)
            files += glob.glob(os.path.join(t, "**", "*.HH"), recursive=True)
        elif os.path.isfile(t):
            files.append(t)
        else:
            print(f"no such path: {t}", file=sys.stderr)
            return 2

    problems = []
    for f in sorted(set(files)):
        problems += check_file(f)

    for p in problems:
        print(p)
    print(f"\n{len(files)} file(s) checked, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
