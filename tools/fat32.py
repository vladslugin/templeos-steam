#!/usr/bin/env python3
"""
fat32.py - read and write the guest's FAT32 partition from the host.

This is how the game layer gets into the image. TempleOS installs onto FAT32,
so once the disk is a raw image the host can drop /Game straight in without
booting anything - no RedSea reader, no scripted installer, no typing code in
through the keyboard.

Long names are supported because the OS supports them: TempleOS reads and writes
VFAT entries itself (vendor/TempleOS/Kernel/BlkDev/FileSysFAT.HC:171 defines
fat_long_name_map, :202-207 read them, :250-267 write them), and its own files
need them - MakeHome.HC.Z does not fit 8.3.

Usage:
    python tools/fat32.py <image> ls /
    python tools/fat32.py <image> mkdir /Game
    python tools/fat32.py <image> put local.HC /Game/Local.HC
    python tools/fat32.py <image> putdir guest/Game /Game
    python tools/fat32.py <image> cat /Game/Local.HC

The partition is found from the MBR by default; --part picks which one.
"""

from __future__ import annotations

import argparse
import os
import struct
import subprocess
import sys

ATTR_READ_ONLY = 0x01
ATTR_HIDDEN = 0x02
ATTR_SYSTEM = 0x04
ATTR_VOLUME_ID = 0x08
ATTR_DIRECTORY = 0x10
ATTR_ARCHIVE = 0x20
ATTR_LFN = 0x0F

EOC = 0x0FFFFFF8
FREE = 0x00000000

# Characters FAT allows in a short name. Anything else becomes '_'.
SHORT_OK = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789$%'-_@~`!(){}^#&")


def lfn_checksum(short11: bytes) -> int:
    s = 0
    for b in short11:
        s = (((s & 1) << 7) + (s >> 1) + b) & 0xFF
    return s


class Fat32:
    def __init__(self, path: str, part_lba: int | None = None, readonly: bool = True):
        self.path = path
        self.readonly = readonly
        self.f = open(path, "rb" if readonly else "r+b")
        self.part_lba = part_lba if part_lba is not None else self._find_partition()
        self._read_boot()

    # ---------------------------------------------------------------- layout

    def _find_partition(self) -> int:
        self.f.seek(0)
        mbr = self.f.read(512)
        if mbr[510:512] != b"\x55\xAA":
            raise ValueError("no MBR signature; is this a whole-disk image?")
        for i in range(4):
            e = mbr[446 + i * 16: 446 + (i + 1) * 16]
            ptype = e[4]
            lba = struct.unpack_from("<I", e, 8)[0]
            if ptype in (0x0B, 0x0C) and lba:
                return lba
        raise ValueError("no FAT32 partition in the MBR")

    def _read_boot(self):
        self.f.seek(self.part_lba * 512)
        bs = self.f.read(512)
        if bs[510:512] != b"\x55\xAA":
            raise ValueError(f"partition at LBA {self.part_lba} has no boot signature")
        self.bytes_per_sector = struct.unpack_from("<H", bs, 11)[0]
        self.sectors_per_cluster = bs[13]
        self.reserved = struct.unpack_from("<H", bs, 14)[0]
        self.num_fats = bs[16]
        self.sectors_per_fat = struct.unpack_from("<I", bs, 36)[0]
        self.root_cluster = struct.unpack_from("<I", bs, 44)[0]
        if not self.sectors_per_fat or not self.bytes_per_sector:
            raise ValueError("not a FAT32 boot sector")
        self.cluster_bytes = self.bytes_per_sector * self.sectors_per_cluster
        self.fat_lba = self.part_lba + self.reserved
        self.data_lba = self.fat_lba + self.num_fats * self.sectors_per_fat
        total = struct.unpack_from("<I", bs, 32)[0]
        self.total_clusters = (total - (self.reserved + self.num_fats * self.sectors_per_fat)) \
            // self.sectors_per_cluster

    def cluster_offset(self, clus: int) -> int:
        return (self.data_lba + (clus - 2) * self.sectors_per_cluster) * self.bytes_per_sector

    # ------------------------------------------------------------------- FAT

    def fat_get(self, clus: int) -> int:
        self.f.seek(self.fat_lba * self.bytes_per_sector + clus * 4)
        return struct.unpack("<I", self.f.read(4))[0] & 0x0FFFFFFF

    def fat_set(self, clus: int, val: int) -> None:
        for i in range(self.num_fats):
            base = (self.fat_lba + i * self.sectors_per_fat) * self.bytes_per_sector
            self.f.seek(base + clus * 4)
            old = struct.unpack("<I", self.f.read(4))[0]
            new = (old & 0xF0000000) | (val & 0x0FFFFFFF)
            self.f.seek(base + clus * 4)
            self.f.write(struct.pack("<I", new))

    def chain(self, clus: int) -> list[int]:
        out = []
        while 2 <= clus < EOC:
            out.append(clus)
            clus = self.fat_get(clus)
            if len(out) > 1 << 22:
                raise ValueError("cluster chain loops")
        return out

    def alloc_cluster(self, prev: int | None = None) -> int:
        for c in range(2, self.total_clusters + 2):
            if self.fat_get(c) == FREE:
                self.fat_set(c, 0x0FFFFFFF)
                if prev is not None:
                    self.fat_set(prev, c)
                self.zero_cluster(c)
                return c
        raise OSError("filesystem full")

    def free_chain(self, clus: int) -> None:
        for c in self.chain(clus):
            self.fat_set(c, FREE)

    def zero_cluster(self, clus: int) -> None:
        self.f.seek(self.cluster_offset(clus))
        self.f.write(b"\x00" * self.cluster_bytes)

    # ------------------------------------------------------------- directory

    def read_chain_bytes(self, clus: int) -> bytes:
        out = bytearray()
        for c in self.chain(clus):
            self.f.seek(self.cluster_offset(c))
            out += self.f.read(self.cluster_bytes)
        return bytes(out)

    def parse_dir(self, clus: int):
        """Yield (name, attr, first_cluster, size, index) for each live entry."""
        raw = self.read_chain_bytes(clus)
        lfn_parts: dict[int, str] = {}
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if len(e) < 32 or e[0] == 0x00:
                break
            if e[0] == 0xE5:
                lfn_parts.clear()
                continue
            attr = e[11]
            if attr == ATTR_LFN:
                order = e[0] & 0x3F
                chunk = (e[1:11] + e[14:26] + e[28:32]).decode("utf-16-le", errors="replace")
                cut = chunk.find("￿")
                if cut >= 0:
                    chunk = chunk[:cut]
                cut = chunk.find("\x00")
                if cut >= 0:
                    chunk = chunk[:cut]
                lfn_parts[order] = chunk
                continue
            if attr & ATTR_VOLUME_ID:
                lfn_parts.clear()
                continue
            if lfn_parts:
                name = "".join(lfn_parts[k] for k in sorted(lfn_parts))
            else:
                base = e[0:8].decode("latin1").rstrip()
                ext = e[8:11].decode("latin1").rstrip()
                name = base + ("." + ext if ext else "")
            lfn_parts.clear()
            first = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
            size = struct.unpack_from("<I", e, 28)[0]
            yield name, attr, first, size, i

    def resolve(self, path: str):
        """Return (name, attr, first_cluster, size) or None. '/' gives the root."""
        parts = [p for p in path.replace("\\", "/").split("/") if p]
        clus, attr, size = self.root_cluster, ATTR_DIRECTORY, 0
        name = "/"
        for part in parts:
            found = None
            for nm, a, first, sz, _idx in self.parse_dir(clus):
                if nm.upper() == part.upper():
                    found = (nm, a, first, sz)
                    break
            if not found:
                return None
            name, attr, clus, size = found
            if clus == 0 and attr & ATTR_DIRECTORY:
                clus = self.root_cluster
        return name, attr, clus, size

    def listdir(self, path: str):
        got = self.resolve(path)
        if not got:
            raise FileNotFoundError(path)
        _nm, attr, clus, _sz = got
        if not attr & ATTR_DIRECTORY:
            raise NotADirectoryError(path)
        return [(nm, a, first, sz) for nm, a, first, sz, _i in self.parse_dir(clus)
                if nm not in (".", "..")]

    def read_file(self, path: str) -> bytes:
        got = self.resolve(path)
        if not got:
            raise FileNotFoundError(path)
        _nm, attr, clus, size = got
        if attr & ATTR_DIRECTORY:
            raise IsADirectoryError(path)
        return self.read_chain_bytes(clus)[:size]

    # ----------------------------------------------------------------- write

    def _short_name(self, name: str, taken: set[str]) -> bytes:
        base, _, ext = name.rpartition(".")
        if not base:
            base, ext = name, ""

        def clean(s):
            return "".join(c if c in SHORT_OK else "_" for c in s.upper())

        b, e = clean(base)[:8], clean(ext)[:3]
        cand = (b.ljust(8) + e.ljust(3)).encode("latin1")
        if b == clean(base) and e == clean(ext) and cand.decode("latin1") not in taken:
            return cand
        # Needs a ~N tail to stay unique, same convention Windows uses.
        for n in range(1, 1000):
            tail = f"~{n}"
            stem = (b[: 8 - len(tail)] + tail).ljust(8)
            cand = (stem + e.ljust(3)).encode("latin1")
            if cand.decode("latin1") not in taken:
                return cand
        raise OSError(f"cannot make a unique short name for {name!r}")

    def _dir_entries(self, name: str, short11: bytes, attr: int, clus: int, size: int) -> bytes:
        out = bytearray()
        need_lfn = name != short11[:8].decode("latin1").rstrip() + (
            "." + short11[8:].decode("latin1").rstrip() if short11[8:].strip() else ""
        )
        if need_lfn:
            chk = lfn_checksum(short11)
            units = name.encode("utf-16-le")
            chars = [units[i:i + 2] for i in range(0, len(units), 2)]
            chars.append(b"\x00\x00")
            while len(chars) % 13:
                chars.append(b"\xFF\xFF")
            total = len(chars) // 13
            for seq in range(total, 0, -1):
                part = chars[(seq - 1) * 13: seq * 13]
                ent = bytearray(32)
                ent[0] = seq | (0x40 if seq == total else 0)
                ent[11] = ATTR_LFN
                ent[13] = chk
                ent[1:11] = b"".join(part[0:5])
                ent[14:26] = b"".join(part[5:11])
                ent[28:32] = b"".join(part[11:13])
                out += bytes(ent)
        ent = bytearray(32)
        ent[0:11] = short11
        ent[11] = attr
        struct.pack_into("<H", ent, 20, (clus >> 16) & 0xFFFF)
        struct.pack_into("<H", ent, 26, clus & 0xFFFF)
        struct.pack_into("<I", ent, 28, size)
        # A fixed timestamp keeps images reproducible: same inputs, same bytes.
        struct.pack_into("<H", ent, 22, 0)      # write time 00:00:00
        struct.pack_into("<H", ent, 24, 0x5B01)  # write date 2025-08-01
        out += bytes(ent)
        return bytes(out)

    def _append_entries(self, dir_clus: int, blob: bytes) -> None:
        need = len(blob) // 32
        chain = self.chain(dir_clus)
        per_clus = self.cluster_bytes // 32
        run_start = None
        run = 0
        for ci, c in enumerate(chain):
            self.f.seek(self.cluster_offset(c))
            data = self.f.read(self.cluster_bytes)
            for si in range(per_clus):
                e = data[si * 32:(si + 1) * 32]
                if e[0] in (0x00, 0xE5):
                    if run == 0:
                        run_start = (ci, si)
                    run += 1
                    if run == need:
                        break
                else:
                    run = 0
            if run == need:
                break
        if run < need:
            last = chain[-1]
            newc = self.alloc_cluster(last)
            chain.append(newc)
            run_start, run = (len(chain) - 1, 0), need
        ci, si = run_start
        pos = 0
        while pos < len(blob):
            c = chain[ci]
            room = (self.cluster_bytes - si * 32)
            take = min(room, len(blob) - pos)
            self.f.seek(self.cluster_offset(c) + si * 32)
            self.f.write(blob[pos:pos + take])
            pos += take
            ci += 1
            si = 0
            if pos < len(blob) and ci >= len(chain):
                chain.append(self.alloc_cluster(chain[-1]))

    def _taken_shorts(self, dir_clus: int) -> set[str]:
        raw = self.read_chain_bytes(dir_clus)
        out = set()
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if len(e) < 32 or e[0] == 0x00:
                break
            if e[0] == 0xE5 or e[11] == ATTR_LFN:
                continue
            out.add(e[0:11].decode("latin1"))
        return out

    def _remove(self, dir_clus: int, name: str) -> None:
        """Mark an existing entry and its LFN run deleted, and free its data."""
        raw = bytearray(self.read_chain_bytes(dir_clus))
        target = None
        lfn_start = None
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if len(e) < 32 or e[0] == 0x00:
                break
            if e[0] == 0xE5:
                lfn_start = None
                continue
            if e[11] == ATTR_LFN:
                if lfn_start is None:
                    lfn_start = i
                continue
            nm = None
            for got in self.parse_dir(dir_clus):
                if got[4] == i:
                    nm = got[0]
                    break
            if nm and nm.upper() == name.upper():
                target = (lfn_start if lfn_start is not None else i, i, e)
                break
            lfn_start = None
        if not target:
            return
        start, end, ent = target
        first = (struct.unpack_from("<H", ent, 20)[0] << 16) | struct.unpack_from("<H", ent, 26)[0]
        if first >= 2:
            self.free_chain(first)
        chain = self.chain(dir_clus)
        for off in range(start, end + 32, 32):
            ci, si = divmod(off, self.cluster_bytes)
            self.f.seek(self.cluster_offset(chain[ci]) + si)
            self.f.write(b"\xE5")

    def mkdir(self, path: str) -> None:
        if self.resolve(path):
            return
        parent, _, name = path.replace("\\", "/").rstrip("/").rpartition("/")
        parent = parent or "/"
        got = self.resolve(parent)
        if not got:
            self.mkdir(parent)
            got = self.resolve(parent)
        _n, attr, pclus, _s = got
        if not attr & ATTR_DIRECTORY:
            raise NotADirectoryError(parent)
        clus = self.alloc_cluster()
        # "." and ".." as FAT requires. ".." of a root child is written as 0.
        dot = self._dir_entries(".", b".          ", ATTR_DIRECTORY, clus, 0)
        dotdot = self._dir_entries("..", b"..         ", ATTR_DIRECTORY,
                                   0 if pclus == self.root_cluster else pclus, 0)
        self.f.seek(self.cluster_offset(clus))
        self.f.write(dot[-32:] + dotdot[-32:])
        short = self._short_name(name, self._taken_shorts(pclus))
        self._append_entries(pclus, self._dir_entries(name, short, ATTR_DIRECTORY, clus, 0))

    def write_file(self, path: str, data: bytes) -> None:
        parent, _, name = path.replace("\\", "/").rpartition("/")
        parent = parent or "/"
        got = self.resolve(parent)
        if not got:
            self.mkdir(parent)
            got = self.resolve(parent)
        _n, attr, pclus, _s = got
        if not attr & ATTR_DIRECTORY:
            raise NotADirectoryError(parent)
        self._remove(pclus, name)

        first = 0
        if data:
            nclus = (len(data) + self.cluster_bytes - 1) // self.cluster_bytes
            clusters = []
            prev = None
            for _ in range(nclus):
                c = self.alloc_cluster(prev)
                clusters.append(c)
                prev = c
            for i, c in enumerate(clusters):
                chunk = data[i * self.cluster_bytes:(i + 1) * self.cluster_bytes]
                self.f.seek(self.cluster_offset(c))
                self.f.write(chunk.ljust(self.cluster_bytes, b"\x00"))
            first = clusters[0]
        short = self._short_name(name, self._taken_shorts(pclus))
        self._append_entries(pclus, self._dir_entries(name, short, ATTR_ARCHIVE, first, len(data)))

    def close(self):
        self.f.close()


def in_use_by(image: str):
    """Any emulator command line that mentions this image, as (pid, cmdline).

    Writing into a disk an emulator has open is a way to lose an afternoon. The
    host tool and the guest are both caching, so the write appears to succeed,
    the reads afterwards even show the new bytes, and then the emulator flushes
    its own idea of those sectors over the top - or does not, and the change
    survives by luck. Neither is a thing to build on.

    Checked by process rather than by file lock because QEMU opens the image
    shared, so the lock says nothing.
    """
    if sys.platform != "win32":
        try:
            out = subprocess.run(["ps", "-eo", "pid,args"], capture_output=True,
                                 text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return []
        name = os.path.basename(image)
        return [(line.split(None, 1)[0], line)
                for line in out.splitlines()
                if "qemu-system" in line and name in line]

    script = ("Get-CimInstance Win32_Process -Filter \"Name like '%qemu-system%'\" "
              "| ForEach-Object { \"$($_.ProcessId)`t$($_.CommandLine)\" }")
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command", script],
                             capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    name = os.path.basename(image)
    found = []
    for line in out.splitlines():
        if "	" not in line:
            continue
        pid, cmd = line.split("	", 1)
        if name in cmd:
            found.append((pid.strip(), cmd.strip()))
    return found


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("image")
    ap.add_argument("--part", type=int, default=None, help="partition start LBA")
    sub = ap.add_subparsers(dest="action", required=True)

    p = sub.add_parser("info")
    p = sub.add_parser("ls"); p.add_argument("path", nargs="?", default="/")
    p = sub.add_parser("cat"); p.add_argument("path")
    p = sub.add_parser("mkdir"); p.add_argument("path")
    p = sub.add_parser("put"); p.add_argument("src"); p.add_argument("dst")
    p = sub.add_parser("putdir"); p.add_argument("src"); p.add_argument("dst")
    p = sub.add_parser("rm"); p.add_argument("path")

    ap.add_argument("--force", action="store_true",
                    help="write even if an emulator has the image open")

    args = ap.parse_args()
    write_actions = {"mkdir", "put", "putdir", "rm"}

    if args.action in write_actions and not args.force:
        busy = in_use_by(args.image)
        if busy:
            print("refusing to write: %s is open in a running emulator"
                  % args.image, file=sys.stderr)
            for pid, cmd in busy:
                print("  pid %s  %s" % (pid, cmd[:140]), file=sys.stderr)
            print("Shut the guest down first, or pass --force if you are sure.",
                  file=sys.stderr)
            return 2

    fs = Fat32(args.image, args.part, readonly=args.action not in write_actions)

    try:
        if args.action == "info":
            print(f"partition LBA   : {fs.part_lba}")
            print(f"bytes/sector    : {fs.bytes_per_sector}")
            print(f"sectors/cluster : {fs.sectors_per_cluster}")
            print(f"cluster bytes   : {fs.cluster_bytes}")
            print(f"FATs            : {fs.num_fats} x {fs.sectors_per_fat} sectors")
            print(f"root cluster    : {fs.root_cluster}")
            print(f"clusters        : {fs.total_clusters}")

        elif args.action == "ls":
            for nm, attr, first, size in fs.listdir(args.path):
                kind = "DIR " if attr & ATTR_DIRECTORY else f"{size:>8}"
                print(f"  {kind}  clus={first:<8} {nm}")

        elif args.action == "cat":
            sys.stdout.buffer.write(fs.read_file(args.path))

        elif args.action == "mkdir":
            fs.mkdir(args.path)
            print(f"created {args.path}")

        elif args.action == "put":
            with open(args.src, "rb") as fh:
                data = fh.read()
            fs.write_file(args.dst, data)
            print(f"wrote {args.dst}  {len(data)} bytes")

        elif args.action == "rm":
            # Needed to replace an OS file rather than shadow it: TempleOS
            # resolves both X.HC and X.HC.Z (FUF_Z_OR_NOT_Z, KernelA.HH:2585),
            # so leaving the compressed original in place makes which one wins
            # anyone's guess.
            parent, _, name = args.path.replace("\\", "/").rpartition("/")
            got = fs.resolve(parent or "/")
            if not got:
                print(f"no such directory: {parent}", file=sys.stderr)
                return 1
            fs._remove(got[2], name)
            print(f"removed {args.path}")

        elif args.action == "putdir":
            fs.mkdir(args.dst)
            n = 0
            for entry in sorted(os.listdir(args.src)):
                src = os.path.join(args.src, entry)
                if not os.path.isfile(src):
                    continue
                with open(src, "rb") as fh:
                    data = fh.read()
                fs.write_file(f"{args.dst.rstrip('/')}/{entry}", data)
                print(f"  {entry}  {len(data)} bytes")
                n += 1
            print(f"wrote {n} file(s) into {args.dst}")
    finally:
        fs.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
