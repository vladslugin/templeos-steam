#!/usr/bin/env python3
"""
vnc_probe.py - pull a framebuffer out of the guest over VNC.

This exists to settle one architectural question before the launcher is built:
how does the host put the guest on screen?

QEMU drawing its own window next to the launcher is not a game. Rendering the
guest inside the launcher means getting at its framebuffer, and QEMU already
serves one over RFB - so the launcher becomes a small RFB client rather than
anything exotic. This script proves the path end to end in Python, where it is
quick to iterate; the same handshake then goes into the launcher.

Only what is needed is implemented: RFB 3.8, security type None, raw encoding.
Raw is wasteful on the wire - a full 640x480 frame is about 1.2 MB - but this is
loopback, and incremental updates mean most frames carry a few small rectangles.
Anything cleverer can wait until it is measured to matter.

    bash tools/run_qemu.sh --disk build/temple_disk.raw -- -vnc 127.0.0.1:9
    python tools/vnc_probe.py --port 5909 --out build/shots/vnc.png
"""

from __future__ import annotations

import argparse
import os
import socket
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from qemu_drive import write_png  # noqa: E402


class RfbError(Exception):
    pass


class Rfb:
    def __init__(self, host: str, port: int, timeout: float = 20.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        # Nagle off. Each frame costs one small request and the server has
        # nothing to say in between, so Nagle holds it until a delayed
        # acknowledgement arrives - 200ms on Windows - and the measurement
        # then records a stall that belongs to the measuring tool. The
        # launcher does the same on its own socket.
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.settimeout(timeout)
        self._handshake()

    # -- plumbing ----------------------------------------------------------

    def recv_exact(self, n: int) -> bytes:
        out = b""
        while len(out) < n:
            chunk = self.sock.recv(n - len(out))
            if not chunk:
                raise RfbError(f"connection closed with {n - len(out)} bytes outstanding")
            out += chunk
        return out

    def _handshake(self) -> None:
        version = self.recv_exact(12)
        if not version.startswith(b"RFB "):
            raise RfbError(f"not an RFB server: {version!r}")
        self.version = version.decode("ascii").strip()
        self.sock.sendall(b"RFB 003.008\n")

        count = self.recv_exact(1)[0]
        if count == 0:
            reason_len = struct.unpack(">I", self.recv_exact(4))[0]
            raise RfbError(f"server refused: {self.recv_exact(reason_len).decode()}")
        types = self.recv_exact(count)
        if 1 not in types:
            raise RfbError(f"no None security type on offer: {list(types)} - "
                           f"start QEMU without a VNC password")
        self.sock.sendall(bytes([1]))

        result = struct.unpack(">I", self.recv_exact(4))[0]
        if result != 0:
            raise RfbError("security handshake rejected")

        self.sock.sendall(bytes([1]))  # shared

        head = self.recv_exact(24)
        self.width, self.height = struct.unpack(">HH", head[:4])
        (self.bpp, self.depth, self.big_endian, self.true_colour,
         self.rmax, self.gmax, self.bmax,
         self.rshift, self.gshift, self.bshift) = struct.unpack(">BBBBHHHBBBxxx", head[4:20])
        name_len = struct.unpack(">I", head[20:24])[0]
        self.name = self.recv_exact(name_len).decode("latin1") if name_len else ""

        # Ask for something easy to unpack rather than accepting whatever the
        # server prefers: 32bpp true colour, one byte per channel.
        fmt = struct.pack(">BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        self.sock.sendall(struct.pack(">Bxxx", 0) + fmt)
        self.bpp, self.depth = 32, 24
        self.rshift, self.gshift, self.bshift = 16, 8, 0

        # Encodings, best first. Raw (0) is the only one required of a server,
        # and the only one this client can decode.
        self.sock.sendall(struct.pack(">BxH", 2, 1) + struct.pack(">i", 0))

    # -- framebuffer -------------------------------------------------------

    def request(self, incremental: bool = False) -> None:
        self.sock.sendall(struct.pack(">BBHHHH", 3, 1 if incremental else 0,
                                      0, 0, self.width, self.height))

    def read_update(self, fb: bytearray) -> int:
        """Read one FramebufferUpdate into fb (RGB, width*height*3). Returns rect count."""
        while True:
            msg = self.recv_exact(1)[0]
            if msg == 0:
                break
            elif msg == 2:      # bell
                continue
            elif msg == 3:      # server cut text
                self.recv_exact(3)
                n = struct.unpack(">I", self.recv_exact(4))[0]
                self.recv_exact(n)
                continue
            elif msg == 1:      # colour map
                self.recv_exact(3)
                _first, count = struct.unpack(">HH", self.recv_exact(4))
                self.recv_exact(count * 6)
                continue
            else:
                raise RfbError(f"unexpected server message {msg}")

        self.recv_exact(1)
        (nrects,) = struct.unpack(">H", self.recv_exact(2))
        for _ in range(nrects):
            x, y, w, h, enc = struct.unpack(">HHHHi", self.recv_exact(12))
            if enc != 0:
                raise RfbError(f"rectangle encoded as {enc}, only raw is handled")
            data = self.recv_exact(w * h * 4)
            for row in range(h):
                src = row * w * 4
                dst = ((y + row) * self.width + x) * 3
                for col in range(w):
                    p = src + col * 4
                    # QEMU sends little-endian BGRX for this pixel format.
                    fb[dst + col * 3 + 0] = data[p + 2]
                    fb[dst + col * 3 + 1] = data[p + 1]
                    fb[dst + col * 3 + 2] = data[p + 0]
        return nrects

    def close(self) -> None:
        self.sock.close()


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5909)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "build", "shots", "vnc.png"))
    ap.add_argument("--frames", type=int, default=1, help="how many updates to pull")
    args = ap.parse_args()

    try:
        r = Rfb(args.host, args.port)
    except (OSError, RfbError) as exc:
        print(f"cannot reach a VNC server at {args.host}:{args.port}: {exc}", file=sys.stderr)
        print("start the guest with:  -vnc 127.0.0.1:9", file=sys.stderr)
        return 1

    print(f"{r.version}  {r.width}x{r.height}  desktop {r.name!r}")
    fb = bytearray(r.width * r.height * 3)

    t0 = time.time()
    total = 0
    for i in range(args.frames):
        r.request(incremental=(i > 0))
        total += r.read_update(fb)
    elapsed = time.time() - t0

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    write_png(args.out, r.width, r.height, bytes(fb))
    r.close()

    print(f"{args.frames} update(s), {total} rectangle(s), {elapsed:.2f}s")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
