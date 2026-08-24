#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
loc_count.py -- LOC counter for the TempleOS 5.03 source snapshot.

Phase 0 deliverable for analysis/01_inventory.md (spec section 2.2 / 2.3.3).

Python 3.6+, standard library only, deterministic, cross-platform.

WHY THIS IS NOT `wc -l`
=======================
TempleOS source files are not plain text.  Most of them are DolDoc documents,
and a DolDoc document is stored on disk as:

    <NUL-terminated ASCII text><CDocBin record><CDocBin record>...

See vendor/TempleOS/Adam/DolDoc/DocFile.HC:3-33 (`DocLoad`):

      DocPutS(doc,src2);            // line 11  -- the ASCII part
      src=src2+StrLen(src2)+1;      // line 12  -- everything AFTER the first
                                    //             NUL byte is binary
      i=size-(offset(CDocBin.end)-offset(CDocBin.start));
      while (src<=src2+i) { ... }   // lines 14-26 -- CDocBin records

and the record layout in vendor/TempleOS/Kernel/KernelA.HH:1118-1128
(`class CDocBin`): the serialised part is `U32 num, flags, size, use_cnt`
(16 bytes) followed by `size` raw payload bytes.

So the exact, source-derived rule for separating text from binary is:

    text  = data[:data.index(b'\\x00')]
    blobs = data[data.index(b'\\x00')+1:]   (parsed as CDocBin records)

That payload is sprite / image / resource data (see the `$SP,...,BI=n$` and
`$IB,...,BI=n$` tags in the text part).  Counting `\\n` bytes inside it is
meaningless -- 0x0A simply occurs at random inside pixel data.  This script
therefore reports BOTH numbers for every bucket:

    raw_lines   -- newlines over the whole file (what `wc -l` would give)
    text_lines  -- newlines over the DolDoc text region only  <-- use this one

TERRY'S OWN RECIPE
==================
The author's own line count (the number behind `DD_TEMPLEOS_LOC`) is produced
by `UpdateLineCnts` in vendor/TempleOS/Demo/AcctExample/TOS/TOSDistro.HC:231-257:

    res=LineRep("C:/*","-r")+LineRep("C:/Adam/*")+
        LineRep("C:/Compiler/*","-S+$")+LineRep("C:/Kernel/*");

`LineRep` defaults to flags "+r+S" = recurse + FUf_JUST_SRC
(vendor/TempleOS/Adam/Opt/Utils/LineRep.HC:41), and the masks are
(vendor/TempleOS/Kernel/KernelA.HH:2300-2305):

    FILEMASK_SRC = "*.HC*;*.HH*;*.IN*;*.PRJ*"
    FILEMASK_DD  = FILEMASK_SRC ";*.DD*"

so the recipe is:
    root       non-recursive, {HC,HH,IN,PRJ}
    /Adam      recursive,     {HC,HH,IN,PRJ}
    /Compiler  recursive,     {HC,HH,IN,PRJ,DD}   (-S+$ swaps SRC for DD)
    /Kernel    recursive,     {HC,HH,IN,PRJ}
and /Apps /Demo /Doc /Misc /0000Boot /Downloads /Linux /Home are NOT counted.
`--terry` reproduces exactly that selection.

USAGE
=====
    python tools/loc_count.py                       # markdown tables, default root
    python tools/loc_count.py --root vendor/TempleOS
    python tools/loc_count.py --json                # machine-readable
    python tools/loc_count.py --terry               # only the author's recipe
    python tools/loc_count.py --files               # add per-file table
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys

# --------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------

DEFAULT_ROOT = os.path.join("vendor", "TempleOS")

SKIP_DIRS = {".git", ".hg", ".svn"}

# TempleOS "wrapper" extensions: NAME.EXT.Z (compressed) / NAME.EXT.C (contiguous).
# See ST_FILE_ATTRS in vendor/TempleOS/Kernel/KDefine.HC:108 and
# BOOT_DIR_KERNEL_BIN_C in vendor/TempleOS/Adam/Opt/Boot/BootDVDIns.HC:9-11.
WRAPPER_EXTS = {"Z", "C"}

# Buckets that are genuinely line-oriented source/text.
TEXT_EXTS = {"HC", "HH", "DD", "TXT", "PRJ", "IN", "MAP", "CPP", "LOG"}

# Buckets that are opaque machine data (no meaningful line count at all).
BINARY_EXTS = {"BIN", "DATA", "GR"}

# Terry's recipe, from TOSDistro.HC:246-247.
TERRY_MASKS = {
    "SRC": {"HC", "HH", "IN", "PRJ"},              # FILEMASK_SRC
    "DD": {"HC", "HH", "IN", "PRJ", "DD"},         # FILEMASK_DD
}

CDOCBIN_HDR = 16  # U32 num, flags, size, use_cnt -- KernelA.HH:1118-1128

# --------------------------------------------------------------------------
# core
# --------------------------------------------------------------------------


def classify(filename: str) -> str:
    """Return the bucket name for a file, TempleOS-style.

    'Kernel.BIN.C'  -> 'BIN'   (.C is a wrapper, see WRAPPER_EXTS)
    'Bible.TXT'     -> 'TXT'
    'access.LOG'    -> 'LOG'
    'gw'            -> '(none)'
    """
    parts = filename.split(".")
    if len(parts) == 1:
        return "(none)"
    exts = [p.upper() for p in parts[1:]]
    while len(exts) > 1 and exts[-1] in WRAPPER_EXTS:
        exts.pop()
    ext = exts[-1]
    if ext in WRAPPER_EXTS and len(parts) > 2:
        ext = exts[-2] if len(exts) > 1 else ext
    return ext


def split_doldoc(data: bytes):
    """Split a file into (text_region, binary_region) the way DocLoad does.

    vendor/TempleOS/Adam/DolDoc/DocFile.HC:11-12.
    Files with no NUL byte are entirely text.
    """
    nul = data.find(b"\x00")
    if nul < 0:
        return data, b""
    return data[:nul], data[nul + 1:]


def count_lines(region: bytes) -> int:
    """Deterministic line count: newlines, +1 for an unterminated last line.

    CR/LF-agnostic: TempleOS text is CRLF, the /Linux shell scripts are LF;
    only b'\\n' is counted so both give the same answer.
    """
    if not region:
        return 0
    n = region.count(b"\n")
    if not region.endswith(b"\n"):
        n += 1
    return n


def parse_doldoc_bins(blob: bytes):
    """Walk the CDocBin chain. Returns (n_records, payload_bytes, clean).

    `clean` is True when the records tile the blob exactly -- i.e. the file
    really is a DolDoc document and not an opaque binary that merely happens
    to contain a NUL byte.  Layout from KernelA.HH:1118-1128 and the
    read loop in DocFile.HC:13-26.
    """
    pos = 0
    n = 0
    payload = 0
    while pos + CDOCBIN_HDR <= len(blob):
        num, flags, size, use_cnt = struct.unpack_from("<IIII", blob, pos)
        pos += CDOCBIN_HDR
        if size > len(blob) - pos:
            return n, payload, False
        pos += size
        payload += size
        n += 1
        if n > 100000:
            return n, payload, False
    return n, payload, pos == len(blob)


def scan(root: str):
    """Walk `root`, return a sorted list of per-file records."""
    root = os.path.abspath(root)
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            with open(full, "rb") as fh:
                data = fh.read()
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            top = rel.split("/")[0] if "/" in rel else "(root files)"
            text, blob = split_doldoc(data)
            nrec, payload, clean = parse_doldoc_bins(blob) if blob else (0, 0, True)
            out.append({
                "path": rel,
                "top": top,
                "ext": classify(name),
                "bytes": len(data),
                "text_bytes": len(text),
                "bin_bytes": len(blob),
                "raw_lines": count_lines(data),
                "text_lines": count_lines(text),
                "bin_records": nrec,
                "bin_payload": payload,
                "doldoc_clean": clean,
                "blob_lf": blob.count(b"\n"),
                "blob_crlf": blob.count(b"\r\n"),
            })
    out.sort(key=lambda r: r["path"])
    return out


def aggregate(records, key):
    acc = {}
    for r in records:
        a = acc.setdefault(r[key], {
            "files": 0, "bytes": 0, "raw_lines": 0,
            "text_lines": 0, "bin_bytes": 0, "bin_records": 0,
        })
        a["files"] += 1
        a["bytes"] += r["bytes"]
        a["raw_lines"] += r["raw_lines"]
        a["text_lines"] += r["text_lines"]
        a["bin_bytes"] += r["bin_bytes"]
        a["bin_records"] += r["bin_records"]
    return acc


def terry_total(records):
    """Reproduce UpdateLineCnts (TOSDistro.HC:246-247) on this snapshot."""
    buckets = {
        "(root files)": ("SRC", False),   # LineRep("C:/*","-r")   non-recursive
        "Adam": ("SRC", True),            # LineRep("C:/Adam/*")
        "Compiler": ("DD", True),         # LineRep("C:/Compiler/*","-S+$")
        "Kernel": ("SRC", True),          # LineRep("C:/Kernel/*")
    }
    per = {}
    picked = []
    for r in records:
        spec = buckets.get(r["top"])
        if not spec:
            continue
        mask, recursive = spec
        if not recursive and "/" in r["path"]:
            continue
        if r["ext"] not in TERRY_MASKS[mask]:
            continue
        picked.append(r)
        b = per.setdefault(r["top"], {"files": 0, "text_lines": 0, "raw_lines": 0})
        b["files"] += 1
        b["text_lines"] += r["text_lines"]
        b["raw_lines"] += r["raw_lines"]
    return per, picked


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------


def md_table(header, rows):
    widths = [len(h) for h in header]
    srows = [[str(c) for c in row] for row in rows]
    for row in srows:
        for i, c in enumerate(row):
            widths[i] = max(widths[i], len(c))
    def line(cells):
        return "| " + " | ".join(c.ljust(widths[i]) for i, c in enumerate(cells)) + " |"
    out = [line(header),
           "|" + "|".join("-" * (w + 2) for w in widths) + "|"]
    out += [line(r) for r in srows]
    return "\n".join(out)


def fmt(n):
    return "{:,}".format(n)


def render(records, show_files=False):
    chunks = []
    total_files = len(records)
    total_bytes = sum(r["bytes"] for r in records)
    total_raw = sum(r["raw_lines"] for r in records)
    total_text = sum(r["text_lines"] for r in records)
    total_bin = sum(r["bin_bytes"] for r in records)

    chunks.append("### LOC by top-level directory\n")
    acc = aggregate(records, "top")
    rows = []
    for k in sorted(acc, key=lambda x: (x == "(root files)", x)):
        a = acc[k]
        rows.append([k, fmt(a["files"]), fmt(a["raw_lines"]), fmt(a["text_lines"]),
                     fmt(a["raw_lines"] - a["text_lines"]),
                     fmt(a["bin_bytes"]), fmt(a["bytes"])])
    rows.append(["**TOTAL**", fmt(total_files), fmt(total_raw), fmt(total_text),
                 fmt(total_raw - total_text), fmt(total_bin), fmt(total_bytes)])
    chunks.append(md_table(
        ["directory", "files", "raw lines", "text lines",
         "lines inside blobs", "blob bytes", "bytes"], rows))

    chunks.append("\n### LOC by file type\n")
    acc = aggregate(records, "ext")
    rows = []
    for k in sorted(acc, key=lambda x: (-acc[x]["text_lines"], x)):
        a = acc[k]
        kind = "text" if k in TEXT_EXTS else ("binary" if k in BINARY_EXTS else "other")
        rows.append(["." + k if k != "(none)" else k, kind, fmt(a["files"]),
                     fmt(a["raw_lines"]), fmt(a["text_lines"]),
                     fmt(a["raw_lines"] - a["text_lines"]),
                     fmt(a["bin_bytes"]), fmt(a["bytes"])])
    rows.append(["**TOTAL**", "", fmt(total_files), fmt(total_raw), fmt(total_text),
                 fmt(total_raw - total_text), fmt(total_bin), fmt(total_bytes)])
    chunks.append(md_table(
        ["type", "kind", "files", "raw lines", "text lines",
         "lines inside blobs", "blob bytes", "bytes"], rows))

    withbin = [r for r in records if r["bin_bytes"]]
    chunks.append("\n### Files carrying a DolDoc binary payload "
                  "(top 25 by payload size)\n")
    withbin.sort(key=lambda r: (-r["bin_bytes"], r["path"]))
    rows = [[r["path"], fmt(r["bin_bytes"]), fmt(r["bin_records"]),
             fmt(r["raw_lines"]), fmt(r["text_lines"]),
             "yes" if r["doldoc_clean"] else "no -- runs past end"]
            for r in withbin[:25]]
    chunks.append(md_table(
        ["file", "blob bytes", "CDocBin recs", "raw lines",
         "text lines", "CDocBin chain tiles blob"], rows))
    lf = sum(r["blob_lf"] for r in withbin)
    crlf = sum(r["blob_crlf"] for r in withbin)
    chunks.append("\n{} of {} files carry a binary payload; "
                  "{} of those have a CDocBin chain that tiles the payload "
                  "exactly.\nBlob-integrity probe: {} LF bytes inside payloads, "
                  "of which {} are preceded by CR; "
                  "chance would predict about {:.0f}.\n".format(
                      fmt(len(withbin)), fmt(total_files),
                      fmt(sum(1 for r in withbin if r["doldoc_clean"])),
                      fmt(lf), fmt(crlf), lf / 256.0))

    per, picked = terry_total(records)
    chunks.append("\n### Author's own recipe (`UpdateLineCnts`, "
                  "TOSDistro.HC:246-247) reproduced\n")
    rows = []
    for k in ["(root files)", "Adam", "Compiler", "Kernel"]:
        if k in per:
            b = per[k]
            rows.append([k, fmt(b["files"]), fmt(b["raw_lines"]), fmt(b["text_lines"])])
    rows.append(["**TOTAL**", fmt(len(picked)),
                 fmt(sum(r["raw_lines"] for r in picked)),
                 fmt(sum(r["text_lines"] for r in picked))])
    chunks.append(md_table(["scope", "files", "raw lines", "text lines"], rows))

    if show_files:
        chunks.append("\n### Per-file\n")
        rows = [[r["path"], "." + r["ext"], fmt(r["raw_lines"]),
                 fmt(r["text_lines"]), fmt(r["bin_bytes"])] for r in records]
        chunks.append(md_table(
            ["file", "type", "raw lines", "text lines", "blob bytes"], rows))

    return "\n".join(chunks) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Count lines in the TempleOS 5.03 source snapshot, "
                    "excluding DolDoc binary blobs.")
    ap.add_argument("--root", default=DEFAULT_ROOT,
                    help="source root (default: %(default)s)")
    ap.add_argument("--json", action="store_true",
                    help="emit machine-readable JSON instead of markdown")
    ap.add_argument("--files", action="store_true",
                    help="markdown mode: also print the per-file table")
    ap.add_argument("--terry", action="store_true",
                    help="print only the author's own LOC recipe total")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.root):
        sys.stderr.write("error: no such directory: %s\n" % args.root)
        return 2

    records = scan(args.root)
    per, picked = terry_total(records)

    if args.terry and not args.json:
        sys.stdout.write(md_table(
            ["scope", "files", "raw lines", "text lines"],
            [[k, fmt(per[k]["files"]), fmt(per[k]["raw_lines"]),
              fmt(per[k]["text_lines"])]
             for k in ["(root files)", "Adam", "Compiler", "Kernel"] if k in per] +
            [["**TOTAL**", fmt(len(picked)),
              fmt(sum(r["raw_lines"] for r in picked)),
              fmt(sum(r["text_lines"] for r in picked))]]) + "\n")
        return 0

    if args.json:
        payload = {
            "root": os.path.abspath(args.root).replace(os.sep, "/"),
            "totals": {
                "files": len(records),
                "bytes": sum(r["bytes"] for r in records),
                "raw_lines": sum(r["raw_lines"] for r in records),
                "text_lines": sum(r["text_lines"] for r in records),
                "blob_bytes": sum(r["bin_bytes"] for r in records),
            },
            "by_directory": aggregate(records, "top"),
            "by_type": aggregate(records, "ext"),
            "terry_recipe": {
                "source": "Demo/AcctExample/TOS/TOSDistro.HC:246-247",
                "per_scope": per,
                "files": len(picked),
                "raw_lines": sum(r["raw_lines"] for r in picked),
                "text_lines": sum(r["text_lines"] for r in picked),
            },
            "files": records,
        }
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    sys.stdout.write(render(records, show_files=args.files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
