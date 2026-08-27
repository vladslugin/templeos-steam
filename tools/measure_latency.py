#!/usr/bin/env python3
"""
measure_latency.py - how long between pressing a key and seeing it.

This is the number that decides whether the launcher feels like a computer or
like a video call, and it is not frames per second. RFB holds an incremental
update request open until pixels actually change, so a still desktop honestly
answers two or three times a second; counting that as a frame rate and calling
it lag sends you chasing the wrong thing. Ask instead how long a keystroke
takes to appear.

Two clocks on the same keystroke, so the answer says where the time went:

    guest paints it   read back over QMP with screendump, which copies the
                      framebuffer on demand. This is TempleOS's own latency,
                      and at 29.97 FPS (WINMGR_FPS) it cannot go below ~33ms.

    RFB delivers it   the path the launcher actually uses. The difference
                      between the two is what the display path costs, and it
                      is the only part a host-side change can recover.

The guest must be at the desktop before this runs - it types into whatever has
focus. Harmless letters, but they do land somewhere.

    python tools/measure_latency.py --vnc 5909 --qmp 4444

A worked example, on the guest this was written against. The launcher used to
pause 30ms between update requests, to keep the server's change-scan off the
CPU that emulation runs on:

    guest paints it    54 ms
    RFB delivers it   145 ms

The pause was the whole difference. QEMU stretches its own scan interval every
time it looks and finds nobody waiting, so a client that goes quiet between
requests teaches the server to answer slowly. Keeping one request outstanding
at all times brought delivery to 40ms, and cost the guest four frames a second.
"""

from __future__ import annotations

import argparse
import os
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from qemu_drive import Monitor, read_ppm  # noqa: E402
from vnc_probe import Rfb  # noqa: E402

# Letters, one per round, so consecutive rounds cannot be confused with each
# other by a repeat that draws the same glyph in the same place.
KEYS = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
        "k", "l", "m", "n", "o", "p", "q", "r", "s", "t"]


def press(mon: Monitor, i: int) -> None:
    mon.execute("send-key", keys=[{"type": "qcode", "data": KEYS[i % len(KEYS)]}])


def guest_latency(mon: Monitor, out: str, rounds: int) -> list:
    """Keystroke to painted framebuffer, read straight out of QEMU."""

    def shot():
        if os.path.exists(out):
            os.remove(out)
        mon.execute("screendump", filename=out)
        # screendump returns once the file is written, but on Windows the name
        # can appear a moment before the contents are readable.
        for _ in range(200):
            if os.path.exists(out):
                try:
                    return read_ppm(out)[2]
                except Exception:
                    pass
            time.sleep(0.002)
        return None

    lat = []
    for i in range(rounds):
        before = shot()
        t0 = time.time()
        press(mon, i)
        seen = None
        deadline = t0 + 4.0
        while time.time() < deadline:
            cur = shot()
            if cur is not None and cur != before:
                seen = (time.time() - t0) * 1000.0
                break
        lat.append(seen)
        time.sleep(0.3)
    return lat


def rfb_latency(mon: Monitor, host: str, port: int, rounds: int, gap_ms: int) -> list:
    """Keystroke to a rectangle on the wire, the way the launcher sees it.

    gap_ms is how long to leave the server with nothing to answer between
    rounds. Zero is what the launcher does; anything else is there to show
    what a pause costs.
    """
    r = Rfb(host, port)
    fb = bytearray(r.width * r.height * 4)
    r.request(incremental=False)
    r.read_update(fb)

    def drain(seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end:
            r.request(incremental=True)
            try:
                r.read_update(fb)
            except Exception:
                return

    drain(1.0)

    lat = []
    for i in range(rounds):
        # Settle, so the change we time is the keystroke and not something
        # still outstanding from the round before.
        if gap_ms > 0:
            time.sleep(gap_ms / 1000.0)
        else:
            drain(0.3)

        before = bytes(fb)
        t0 = time.time()
        press(mon, i)
        seen = None
        deadline = t0 + 4.0
        while time.time() < deadline:
            r.request(incremental=True)
            try:
                r.read_update(fb)
            except Exception:
                break
            if bytes(fb) != before:
                seen = (time.time() - t0) * 1000.0
                break
        lat.append(seen)
    r.close()
    return lat


def report(label: str, xs: list) -> float | None:
    good = sorted(x for x in xs if x is not None)
    if not good:
        print("%-24s no response to any of %d keys" % (label, len(xs)))
        return None
    med = statistics.median(good)
    print("%-24s median %5.0f ms   p90 %5.0f   min %4.0f   max %5.0f   (%d/%d)"
          % (label, med, good[int(len(good) * 0.9)], good[0], good[-1],
             len(good), len(xs)))
    return med


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--vnc", type=int, default=5909)
    ap.add_argument("--qmp", type=int, default=4444)
    ap.add_argument("--rounds", type=int, default=14)
    ap.add_argument("--gap", type=int, default=0,
                    help="ms to leave the server unasked between rounds; "
                         "shows what a client-side pause costs")
    ap.add_argument("--skip-guest", action="store_true",
                    help="RFB only; screendump is slow and perturbs the guest")
    args = ap.parse_args()

    try:
        mon = Monitor(args.host, args.qmp)
    except OSError as e:
        print("no QMP on %s:%d (%s)" % (args.host, args.qmp, e), file=sys.stderr)
        print("another client may be holding it - qemu_drive.py serve keeps one "
              "connection for the whole session", file=sys.stderr)
        return 1

    guest = None
    if not args.skip_guest:
        out = os.path.join(os.path.dirname(HERE), "build", "latency_shot.ppm")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        guest = report("guest paints it",
                       guest_latency(mon, out, args.rounds))
        if os.path.exists(out):
            os.remove(out)

    label = "RFB delivers it" if args.gap == 0 else "RFB, %dms gap" % args.gap
    wire = report(label, rfb_latency(mon, args.host, args.vnc,
                                     args.rounds, args.gap))

    if guest is not None and wire is not None:
        print("\ndisplay path adds %.0f ms on top of the guest" % (wire - guest))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
