#!/usr/bin/env python3
"""
extract_compiler_errors.py - build the HolyC compiler message database.

The launcher shows a plain-English explanation next to whatever the compiler
prints. The real messages are terse, and without a gloss a beginner stalls on
their first typo. The original message always stays on screen; we annotate it,
we never replace it.

Collecting these by hand - make forty typical mistakes in a VM, write down what
comes out - only finds what you thought to try. Pulling them straight out of the
compiler source is exhaustive by construction. A VM pass is still needed to
confirm the exact rendering and to add context.

Message format, traced through the source:

  Compiler/CExcept.HC:81   U0 LexExcept(CCmpCtrl *cc,U8 *str=NULL)
      -> PrintErr(str)                     Kernel/StrPrint.HC:906
      -> LexPutPos(cc)                     Compiler/CExcept.HC:50
      -> throw('Compiler')                 Compiler/CExcept.HC:95

  Kernel/KernelA.HH:3459   #define ST_ERR_ST  "$$LTRED$$$$BK,1$$ERROR:$$FG$$$$BK,0$$ "
  Kernel/KernelA.HH:3460   #define ST_WARN_ST "$$RED$$$$BK,1$$WARNING:$$FG$$$$BK,0$$ "

What lands on screen:

  <Caller> <Caller(2)> <Caller(3)> <Caller(4)> ERROR: <message><token>
  <file>,<line>
  <the offending source line>

"ERROR:" renders light red and blinking - $BK,1$ turns blink on. Worth noting
for the photosensitivity warning, since a beginner meets blinking text on their
very first typo.

Usage:
    python tools/extract_compiler_errors.py                 # markdown report
    python tools/extract_compiler_errors.py --json > out.json
    python tools/extract_compiler_errors.py --seed data/errors/compiler_messages.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "vendor", "TempleOS")

# LexExcept(cc,"...") / LexWarn(cc,"...") / PrintErr("...") / PrintWarn("...")
CALL_RE = re.compile(
    r'\b(LexExcept|LexWarn|PrintErr|PrintWarn)\s*\(\s*'
    r'(?:cc\s*,\s*)?'
    r'"((?:[^"\\]|\\.)*)"'
)

# throw('XxxxXxxx'). The spec says these codes are 8 characters. They are not,
# so measure rather than assume - 8 is the ceiling, since they pack into an I64.
THROW_RE = re.compile(r"\bthrow\s*\(\s*'([^']*)'\s*\)")

SEVERITY = {
    "LexExcept": "error",
    "PrintErr": "error",
    "LexWarn": "warning",
    "PrintWarn": "warning",
}


def iter_sources(subdirs=("Compiler", "Kernel", "Adam")):
    for sub in subdirs:
        base = os.path.join(SRC, sub)
        for dirpath, _dirnames, filenames in os.walk(base):
            for fn in sorted(filenames):
                if fn.endswith((".HC", ".HH")):
                    yield os.path.join(dirpath, fn)


def rel(path: str) -> str:
    return os.path.relpath(path, ROOT).replace(os.sep, "/")


def read_lines(path: str):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def normalise(msg: str) -> str:
    """Collapse a message into a grouping key: squeeze space, drop trailing 'at'."""
    key = msg.strip()
    key = re.sub(r"\s+", " ", key)
    key = re.sub(r"\s*\bat\b\s*$", "", key, flags=re.I)
    return key


def collect():
    messages = defaultdict(lambda: {"sites": [], "severity": set(), "raw": set()})
    throws = defaultdict(list)

    for path in iter_sources():
        lines = read_lines(path)
        for i, line in enumerate(lines, 1):
            for m in CALL_RE.finditer(line):
                fn, raw = m.group(1), m.group(2)
                if not raw.strip():
                    continue  # decorative string, no content
                key = normalise(raw)
                if not key:
                    continue
                rec = messages[key]
                rec["sites"].append({"file": rel(path), "line": i, "emitter": fn})
                rec["severity"].add(SEVERITY.get(fn, "error"))
                rec["raw"].add(raw)
            for m in THROW_RE.finditer(line):
                throws[m.group(1)].append({"file": rel(path), "line": i})

    out = []
    for key, rec in sorted(messages.items()):
        sev = "error" if "error" in rec["severity"] else "warning"
        out.append(
            {
                "id": slugify(key),
                "message": key,
                "raw_variants": sorted(rec["raw"]),
                "severity": sev,
                "sites": sorted(rec["sites"], key=lambda s: (s["file"], s["line"])),
                "site_count": len(rec["sites"]),
            }
        )
    return out, throws


def slugify(msg: str) -> str:
    s = msg.lower()
    s = re.sub(r"[^a-z0-9]+", "_", s)
    return s.strip("_")[:60] or "unnamed"


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--json", action="store_true", help="emit JSON instead of markdown")
    ap.add_argument("--seed", metavar="PATH", help="write the translation database skeleton")
    ap.add_argument("--min-sites", type=int, default=1, help="only messages appearing >= N times")
    args = ap.parse_args()

    if not os.path.isdir(SRC):
        print(f"sources missing: {SRC}\nrun: bash tools/fetch_sources.sh", file=sys.stderr)
        return 1

    messages, throws = collect()
    messages = [m for m in messages if m["site_count"] >= args.min_sites]

    errors = [m for m in messages if m["severity"] == "error"]
    warnings = [m for m in messages if m["severity"] == "warning"]

    lens = sorted({len(code) for code in throws})
    non8 = {c: v for c, v in throws.items() if len(c) != 8}

    if args.seed:
        seed = {
            "$schema": "temple/compiler-errors-v1",
            "_source": {
                "repo": "cia-foundation/TempleOS",
                "commit_file": "vendor/TempleOS.commit",
                "emitter": (
                    "Compiler/CExcept.HC:81 LexExcept -> PrintErr "
                    "(Kernel/StrPrint.HC:906) -> LexPutPos (Compiler/CExcept.HC:50) "
                    "-> throw('Compiler')"
                ),
                "prefix_error": 'Kernel/KernelA.HH:3459  ST_ERR_ST = "$$LTRED$$$$BK,1$$ERROR:$$FG$$$$BK,0$$ "',
                "prefix_warning": 'Kernel/KernelA.HH:3460  ST_WARN_ST = "$$RED$$$$BK,1$$WARNING:$$FG$$$$BK,0$$ "',
                "note": "the ERROR:/WARNING: prefix blinks ($BK,1$) - flag for the photosensitivity warning",
            },
            "messages": [
                {
                    **m,
                    # filled in by hand and from VM runs - this is the translation
                    "explain": {"en": "", "ru": ""},
                    "common_cause": {"en": "", "ru": ""},
                    "novice_frequency": None,
                    "confirmed_in_vm": False,
                }
                for m in messages
            ],
            "exception_codes": [
                {"code": c, "length": len(c), "sites": v} for c, v in sorted(throws.items())
            ],
        }
        os.makedirs(os.path.dirname(os.path.abspath(args.seed)), exist_ok=True)
        with open(args.seed, "w", encoding="utf-8") as fh:
            json.dump(seed, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        print(f"wrote {args.seed}: {len(messages)} messages, {len(throws)} exception codes")
        return 0

    if args.json:
        json.dump(
            {"messages": messages, "exception_codes": {k: v for k, v in throws.items()}},
            sys.stdout,
            ensure_ascii=False,
            indent=2,
        )
        sys.stdout.write("\n")
        return 0

    print("# HolyC compiler messages, extracted from source\n")
    print(f"Unique messages: **{len(messages)}** ({len(errors)} errors, {len(warnings)} warnings).")
    print(f"Target for the translator database is 40 or more: "
          f"{'met' if len(messages) >= 40 else 'NOT MET'}.\n")

    print("## Output format\n")
    print("```")
    print("<Caller> <Caller(2)> <Caller(3)> <Caller(4)> ERROR: <message><token>")
    print("<file>,<line>")
    print("<the offending source line>")
    print("```")
    print("`ERROR:` is light red and **blinking** (`$BK,1$`), "
          "`vendor/TempleOS/Kernel/KernelA.HH:3459`.\n")

    for title, rows in (("Errors", errors), ("Warnings", warnings)):
        print(f"## {title}\n")
        print("| Message | Sites | First occurrence |")
        print("|---|---:|---|")
        for m in sorted(rows, key=lambda r: -r["site_count"]):
            first = m["sites"][0]
            print(f"| `{m['message']}` | {m['site_count']} | `{first['file']}:{first['line']}` |")
        print()

    print("## Exception codes\n")
    print(f"The spec claims `throw` codes are 8 characters. Found {len(throws)} unique codes, "
          f"lengths: {lens}.\n")
    if non8:
        print("**Codes that are not 8 characters**, so the claim is wrong:\n")
        print("| Code | Length | Where |")
        print("|---|---:|---|")
        for c, v in sorted(non8.items()):
            print(f"| `'{c}'` | {len(c)} | `{v[0]['file']}:{v[0]['line']}` |")
    else:
        print("Every code is exactly 8 characters, so the claim holds.")
    print()
    print("| Code | Length | Sites | First occurrence |")
    print("|---|---:|---:|---|")
    for c, v in sorted(throws.items()):
        print(f"| `'{c}'` | {len(c)} | {len(v)} | `{v[0]['file']}:{v[0]['line']}` |")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
