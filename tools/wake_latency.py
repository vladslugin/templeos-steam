#!/usr/bin/env python3
"""wake_latency.py - how long the first change after a pause takes to appear.

This is the number a player feels and the one every other measurement here
missed for a long time. The others keep the screen busy - an animation, a
pointer moving in a circle, a key every half second - and a guest that is
already moving hides the thing that hurts. Leave the screen alone for a second,
which is what a person reading their own terminal does constantly, and then
press one key.

    python tools/wake_latency.py                 quiet for a second between tries
    python tools/wake_latency.py --quiet-ms 2000
    python tools/wake_latency.py --keepalive 20  ask for a scrap of screen every
                                                 20ms during the quiet

What this tool was built to prove turned out to be wrong, and the wrong theory
is worth writing down because the numbers look the same either way. The belief
was that the emulator's VNC server was to blame: it scans the framebuffer for
changes on a timer and stretches that timer every time a scan finds nothing, so
a still screen was supposed to be slow to wake. Hence --keepalive, which asks
for a rectangle the server must always answer and so keeps the interval at its
floor. It made no useful difference, and neither did the server's own
non-adaptive switch, and neither did a pixel flipped inside the guest on every
frame.

The cause was in the guest, and this tool cannot see it: the emulated timer
delivers about sixty-five of the thousand interrupts a second the OS asks for,
so everything the guest schedules runs about fifteen times slow. /Game/Clock.HC
fixes it. Run this before and after that and the median goes from 185ms to
under 30 with nothing over a tenth of a second.

So: still a good measurement, and no longer a diagnosis. If this number is bad,
check the guest's timer rate first - the launcher's --stats prints it.
"""

from __future__ import annotations

import argparse
import os
import statistics
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from qemu_drive import Monitor  # noqa: E402
from vnc_probe import Rfb  # noqa: E402

KEYS = list("abcdefghijklmnopqrstuvwxyz")


def keepalive_request(r: Rfb) -> None:
    """A non-incremental request for a tiny square.

    Non-incremental means "send it whether or not it changed", so the server
    always has a rectangle to deliver on its next scan - which is what stops it
    concluding there is nothing happening and slowing down.
    """
    r.sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, 16, 16))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--vnc", type=int, default=5909)
    ap.add_argument("--qmp", type=int, default=4444)
    ap.add_argument("--rounds", type=int, default=15)
    ap.add_argument("--quiet-ms", type=int, default=1000,
                    help="how long to leave the screen alone before each try")
    ap.add_argument("--keepalive", type=int, default=0,
                    help="ms between keepalive requests during the quiet; "
                         "0 means none. Kept for the record; it does not help")
    args = ap.parse_args()

    mon = Monitor(args.host, args.qmp)
    r = Rfb(args.host, args.vnc)
    fb = bytearray(r.width * r.height * 4)
    r.request(incremental=False)
    r.read_update(fb)

    lat = []
    r.sock.settimeout(0.01)
    r.request(incremental=True)
    for i in range(args.rounds):
        # Sit still - but keep exactly one request outstanding the whole time,
        # because that is what the launcher does and the server behaves
        # differently when nobody is waiting on it. An earlier version of this
        # let the request lapse during the quiet and so measured a situation
        # the launcher never creates.
        end = time.time() + args.quiet_ms / 1000.0
        nxt = 0.0
        while time.time() < end:
            if args.keepalive and time.time() >= nxt:
                nxt = time.time() + args.keepalive / 1000.0
                keepalive_request(r)
            try:
                r.read_update(fb)
                r.request(incremental=True)
            except Exception:
                pass

        before = bytes(fb)
        t0 = time.time()
        mon.execute("send-key", keys=[{"type": "qcode", "data": KEYS[i % 26]}])
        seen = None
        deadline = t0 + 5.0
        while time.time() < deadline:
            try:
                r.read_update(fb)
                r.request(incremental=True)
            except Exception:
                continue
            if bytes(fb) != before:
                seen = (time.time() - t0) * 1000.0
                break
        lat.append(seen)
    r.close()

    got = sorted(x for x in lat if x is not None)
    if not got:
        print("nothing ever appeared")
        return 1
    print("quiet %d ms before each of %d tries%s"
          % (args.quiet_ms, args.rounds,
             ", keepalive every %d ms" % args.keepalive if args.keepalive else ""))
    print("  keystroke to pixels: median %.0f ms  p90 %.0f  min %.0f  max %.0f"
          % (statistics.median(got), got[int(len(got) * 0.9)], got[0], got[-1]))
    slow = [x for x in got if x > 100]
    print("  tries over 100 ms  : %d of %d" % (len(slow), len(got)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
