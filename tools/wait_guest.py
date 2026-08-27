#!/usr/bin/env python3
"""
wait_guest.py - block until the guest has finished booting, then say how long it took.

The launcher used to sleep a fixed ninety-five seconds. That number came from
timing a boot under emulation and rounding up, and it was wrong in both
directions: too short on a cold file cache, and absurdly long now that the guest
runs under hardware acceleration, where it reaches the desktop in about fifteen.

There is a better signal than a clock. The game layer starts from
/Home/MakeHome.HC at the very end of start-up, and the first thing it does is
open COM1 and begin sending heartbeats. So the first line that arrives on the
serial port means the same thing as "the guest is up" - not approximately, but
exactly, because the layer is the last thing to run.

    python tools/wait_guest.py --port 4555 --timeout 180

Exit code 0 when the guest answered, 1 when it did not. The elapsed time goes to
stdout as a bare number of seconds so a shell can capture it.

The port has to be free for us to connect, and QEMU's -serial socket serves one
client at a time - so this must finish before the launcher's own bridge client
starts. It closes its connection on the way out, and QEMU accepts the next one.
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

    # QEMU opens its listening socket before the guest has executed anything, so
    # connecting proves nothing on its own - it is the traffic that matters.
    while sock is None and time.time() < deadline:
        try:
            sock = socket.create_connection((host, port), timeout=2)
        except OSError:
            time.sleep(0.25)
    if sock is None:
        if not quiet:
            print("wait_guest: nothing listening on %s:%d" % (host, port),
                  file=sys.stderr)
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
                break
            buf += chunk
            # HELLO if we caught the layer starting, HB if we arrived after it.
            # Either one means the same thing.
            for line in buf.split(b"\n"):
                line = line.strip()
                if line.startswith(b"HELLO") or line.startswith(b"HB "):
                    return time.time() - started
            buf = buf[-512:]
    finally:
        sock.close()
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4555,
                    help="the guest's COM1, as passed to -serial")
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
