#!/usr/bin/env python3
"""
screen_gaps.py - time what actually reaches the monitor.

Every other measurement in this project stops at "the client received a frame".
That is not what a player looks at. Between a frame arriving and a pixel
changing on the screen there is a texture upload, the engine's own draw, and
the wait for the display's refresh - and any of those can hold a frame back
while the counters upstream report a metronome.

So this grabs a small rectangle of the launcher's window as fast as Windows
will hand it over, and records when its contents change. The gaps between those
changes are what the eye is given.

A small rectangle on purpose: capturing the whole window costs tens of
milliseconds and would set the sampling floor above the thing being measured.
A couple of hundred pixels can be grabbed several hundred times a second.

    python tools/screen_gaps.py 10          ten seconds, guest area
    python tools/screen_gaps.py 10 --panel  the launcher's own panel instead

The launcher must be running and something in the guest must be moving, or
there is nothing to time. The comparison worth making is against the same
number taken from the emulator's own window, where the chain is short.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import statistics
import sys
import time

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
SRCCOPY = 0x00CC0020


class RECT(ctypes.Structure):
    _fields_ = [("left", wt.LONG), ("top", wt.LONG),
                ("right", wt.LONG), ("bottom", wt.LONG)]


def find_window(match: str):
    """The first visible top-level window whose title contains match."""
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def each(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        n = user32.GetWindowTextLengthW(hwnd)
        if n == 0:
            return True
        buf = ctypes.create_unicode_buffer(n + 1)
        user32.GetWindowTextW(hwnd, buf, n + 1)
        if match.lower() in buf.value.lower():
            # Windows keeps hidden and minimised windows parked off-screen at
            # -32000; taking one of those gives a negative sample rectangle and
            # a confusing crash rather than an empty result.
            wr = RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(wr))
            if wr.left > -30000 and (wr.right - wr.left) > 200:
                found.append((hwnd, buf.value))
        return True

    user32.EnumWindows(each, 0)
    return found[0] if found else (None, None)


class Grabber:
    """Repeated captures of one rectangle of the screen."""

    def __init__(self, x, y, w, h):
        self.x, self.y, self.w, self.h = x, y, w, h
        self.screen_dc = user32.GetDC(0)
        self.mem_dc = gdi32.CreateCompatibleDC(self.screen_dc)
        self.bmp = gdi32.CreateCompatibleBitmap(self.screen_dc, w, h)
        gdi32.SelectObject(self.mem_dc, self.bmp)
        # 32bpp top-down, so the buffer can be compared as raw bytes.
        self.info = ctypes.create_string_buffer(40 + 1024)
        hdr = ctypes.cast(self.info, ctypes.POINTER(ctypes.c_int32))
        hdr[0] = 40          # biSize
        hdr[1] = w           # biWidth
        hdr[2] = -h          # biHeight, negative for top-down
        ctypes.cast(self.info, ctypes.POINTER(ctypes.c_int16))[6] = 1    # planes
        ctypes.cast(self.info, ctypes.POINTER(ctypes.c_int16))[7] = 32   # bits
        hdr[4] = 0           # BI_RGB
        self.buf = ctypes.create_string_buffer(w * h * 4)

    def grab(self) -> bytes:
        gdi32.BitBlt(self.mem_dc, 0, 0, self.w, self.h,
                     self.screen_dc, self.x, self.y, SRCCOPY)
        gdi32.GetDIBits(self.mem_dc, self.bmp, 0, self.h,
                        self.buf, self.info, 0)
        return self.buf.raw

    def close(self):
        gdi32.DeleteObject(self.bmp)
        gdi32.DeleteDC(self.mem_dc)
        user32.ReleaseDC(0, self.screen_dc)


def find_motion(r, ww, wh, panel: bool, skip_top: int = 80):
    """A small rectangle over whatever is moving, or (None,)*4.

    Two captures half a second apart, differenced in coarse blocks, and the
    busiest block wins. Coarse because this runs once and only has to be
    roughly right - and it exists because guessing where to look cost a whole
    run that reported, truthfully and uselessly, that nothing ever changed.
    """
    if panel:
        x0 = r.left + int(ww * 0.72)
        width = ww - int(ww * 0.72)
    else:
        x0 = r.left
        width = int(ww * 0.70)

    # Skip the top of the window. The launcher's own status line carries a
    # frame counter, so it changes on every engine frame and would win the
    # search every time - which measures the launcher talking to itself rather
    # than the guest arriving. Cost one run to notice.
    top = r.top + skip_top
    height = wh - skip_top
    big = Grabber(x0, top, width, height)
    a = big.grab()
    time.sleep(0.5)
    b = big.grab()
    big.close()

    BLOCK = 40
    best, best_at = 0, None
    for by in range(0, height - BLOCK, BLOCK):
        for bx in range(0, width - BLOCK, BLOCK):
            diff = 0
            for row in range(0, BLOCK, 8):
                off = ((by + row) * width + bx) * 4
                if a[off:off + BLOCK * 4] != b[off:off + BLOCK * 4]:
                    diff += 1
            if diff > best:
                best, best_at = diff, (bx, by)
    if best_at is None:
        return None, None, None, None

    bx, by = best_at
    w, h = min(320, width), 80
    x = max(r.left, min(x0 + bx - w // 2, x0 + width - w))
    y = max(top, min(top + by - h // 2, top + height - h))
    return x, y, w, h


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("seconds", nargs="?", type=float, default=10.0)
    ap.add_argument("--title", default="Temple",
                    help="part of the window title to look for")
    ap.add_argument("--skip-top", type=int, default=80,
                    help="pixels of window top to ignore when looking for "
                         "motion, so the launcher's own status line does not "
                         "win the search")
    ap.add_argument("--panel", action="store_true",
                    help="sample the launcher's panel rather than the guest")
    args = ap.parse_args()

    hwnd, title = find_window(args.title)
    if hwnd is None:
        print("no visible window with %r in its title" % args.title,
              file=sys.stderr)
        return 1
    r = RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    ww, wh = r.right - r.left, r.bottom - r.top
    print("window %r  %dx%d at %d,%d" % (title, ww, wh, r.left, r.top))

    # Where to point the small rectangle. Guessing costs a run - the first
    # attempt sampled a patch the animation never crossed and reported that
    # nothing ever changed - so find the moving part instead: two captures
    # of the window, a moment apart, and put the sample where they differ.
    x, y, w, h = find_motion(r, ww, wh, args.panel, args.skip_top)
    if x is None:
        print("nothing on that window changed in half a second. Is anything "
              "moving?", file=sys.stderr)
        return 1
    print("sampling %dx%d at %d,%d - the busiest part of the window"
          % (w, h, x, y))

    g = Grabber(x, y, w, h)
    prev = g.grab()
    t0 = time.perf_counter()
    stamps = []
    samples = 0
    while time.perf_counter() - t0 < args.seconds:
        cur = g.grab()
        samples += 1
        if cur != prev:
            stamps.append(time.perf_counter())
            prev = cur
    span = time.perf_counter() - t0
    g.close()

    print("sampled %d times in %.1fs  (%.0f/s - the floor for what follows)"
          % (samples, span, samples / span))
    if len(stamps) < 3:
        print("the rectangle never changed. Is anything moving on that part of "
              "the screen?")
        return 1
    gaps = [(b - a) * 1000.0 for a, b in zip(stamps, stamps[1:])]
    s = sorted(gaps)
    print("changes: %d  (%.1f/s)" % (len(stamps), len(stamps) / span))
    print("gap between changes: median %.1f ms  p90 %.1f  p99 %.1f  max %.1f"
          % (statistics.median(s), s[int(len(s) * 0.9)],
             s[int(len(s) * 0.99)], s[-1]))
    for edge in (50, 100, 200):
        n = sum(1 for x in gaps if x > edge)
        print("  gaps over %3d ms: %4d  (%.2f/s)" % (edge, n, n / span))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
