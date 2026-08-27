#!/usr/bin/env python3
"""
wait_guest.py - block until the guest has finished booting, then say how long it took.

The launcher used to sleep a fixed ninety-five seconds. That number came from
timing a boot under emulation and rounding up, and it was wrong in both
directions: too short on a cold file cache, and absurdly long now that the guest
runs under hardware acceleration, where it reaches the desktop in about eight.

There is a better signal than a clock. The game layer starts from
/Home/MakeHome.HC at the very end of start-up, and the first thing it does is
open COM1 and begin sending heartbeats. So the first line that arrives means the
same thing as "the guest is up" - not approximately, but exactly, because the
layer is the last thing to run.

    python tools/wait_guest.py --port 4556 --timeout 180

Exit code 0 when the guest answered, 1 when it did not. The elapsed time goes to
stdout as a bare number of seconds so a shell can capture it.

The port here is combridge's client port, not the one QEMU dials out to. That
indirection exists because the emulator exits if a connection attempt is
refused, so something has to hold its port for the whole session while tools
like this one come and go - see tools/combridge.py.
"""

from __future__ import annotations

import argparse
import socket
import sys
import time


def wait(host: str, port: int, timeout: float, quiet: bool) -> float | None:
    started = time.time()
    deadline = started + timeout

    sock = None
    while sock is None and time.time() < deadline:
        try:
            sock = socket.create_connection((host, port), timeout=2)
        except OSError:
            time.sleep(0.25)
    if sock is None:
        if not quiet:
            print("wait_guest: nothing accepting on %s:%d - is combridge up?"
                  % (host, port), file=sys.stderr)
        return None

    sock.settimeout(0.5)
    buf = b""
    try:
        while time.time() < deadline:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                # The bridge is there but the guest has not dialled in yet, or
                # has just gone. Either way, try again rather than give up.
                sock.close()
                sock = None
                while sock is None and time.time() < deadline:
                    try:
                        sock = socket.create_connection((host, port), timeout=2)
                    except OSError:
                        time.sleep(0.25)
                if sock is None:
                    return None
                sock.settimeout(0.5)
                buf = b""
                continue
            buf += chunk
            # HELLO if we caught the layer starting, HB if we arrived after it.
            # Either one means the same thing.
            for line in buf.split(b"\n"):
                line = line.strip()
                if line.startswith(b"HELLO") or line.startswith(b"HB "):
                    return time.time() - started
            buf = buf[-512:]
    finally:
        if sock is not None:
            sock.close()
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4556,
                    help="combridge's client port")
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    took = wait(args.host, args.port, args.timeout, args.quiet)
    if took is None:
        if not args.quiet:
            print("wait_guest: the guest never spoke; it may still be booting, "
                  "or the layer may not be installed", file=sys.stderr)
        return 1
    print("%.1f" % took)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
