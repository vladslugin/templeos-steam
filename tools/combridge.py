#!/usr/bin/env python3
"""
combridge.py - hold the guest's serial connection open for the whole session.

The guest dials out. QEMU is given

    -chardev socket,id=com1,host=127.0.0.1,port=<guest>,reconnect-ms=1000
    -serial chardev:com1

which means it connects to us and keeps knocking if the connection drops. That
is the right way round - as a server, QEMU's serial socket accepts one client
for the life of the guest, so the second launcher of a session is refused with
the port still showing as listening, and there is no way out of it except
restarting the emulator.

But it comes with a condition that is easy to miss and fatal when missed: QEMU
exits if a connection attempt is REFUSED. Not the first one only - any of them.
So the port cannot be allowed to go unbound even for the moment between one
host process letting go and the next taking over, which is exactly what happens
every time the launcher is closed and reopened.

So this holds it. One process, bound for the whole session, that talks to the
guest on one port and re-serves that conversation on another:

    guest  --dials-->  <guest port>  [combridge]  <client port>  <--dials--  launcher

The launcher, the boot waiter and any diagnostic connect to the client port as
ordinary clients, come and go as they please, and the guest never notices. When
nobody is connected the guest's chatter is dropped on the floor, which is what
should happen to a heartbeat nobody asked for.

    python tools/combridge.py --guest-port 4555 --client-port 4556

Runs until killed. One client at a time: the protocol has one launcher in mind,
and quietly interleaving two of them would be worse than refusing the second.
"""

from __future__ import annotations

import argparse
import os
import selectors
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comlink  # noqa: E402


class Bridge:
    def __init__(self, guest_port: int, client_port: int, host: str,
                 verbose: bool) -> None:
        self.host = host
        self.verbose = verbose
        self.guest_listen = comlink.Listener(guest_port, host, backlog=2)
        self.client_listen = comlink.Listener(client_port, host, backlog=2)
        self.guest: socket.socket | None = None
        self.client: socket.socket | None = None
        self.sel = selectors.DefaultSelector()
        self.from_guest = 0
        self.from_client = 0

    def say(self, msg: str) -> None:
        if self.verbose:
            print("combridge: " + msg, file=sys.stderr, flush=True)

    # -- connection bookkeeping -------------------------------------------

    def _accept(self, listener: comlink.Listener, which: str) -> None:
        sock = listener.accept(timeout=0.0)
        if sock is None:
            return
        old = self.guest if which == "guest" else self.client
        if old is not None:
            # Whoever was here has been replaced. For the guest that means the
            # emulator restarted; for the client, that a second launcher
            # arrived and the first never let go.
            self.say("%s reconnected; dropping the previous one" % which)
            self._drop(old)
        sock.setblocking(False)
        self.sel.register(sock, selectors.EVENT_READ, which)
        if which == "guest":
            self.guest = sock
        else:
            self.client = sock
        self.say("%s connected" % which)

    def _drop(self, sock: socket.socket) -> None:
        try:
            self.sel.unregister(sock)
        except (KeyError, ValueError):
            pass
        try:
            sock.close()
        except OSError:
            pass
        if sock is self.guest:
            self.guest = None
        if sock is self.client:
            self.client = None

    # -- the pump ----------------------------------------------------------

    def run(self) -> None:
        self.say("holding the guest port; clients welcome")
        next_report = time.time() + 5.0
        last = (0, 0)
        while True:
            # A line every few seconds while anything is moving. Which side has
            # gone quiet is the first question whenever the bridge misbehaves,
            # and counting bytes answers it without a packet capture.
            now = time.time()
            if now >= next_report:
                next_report = now + 5.0
                if (self.from_guest, self.from_client) != last:
                    last = (self.from_guest, self.from_client)
                    self.say("guest %s %d bytes | client %s %d bytes"
                             % ("up" if self.guest else "--", self.from_guest,
                                "up" if self.client else "--", self.from_client))

            # accept() with a zero timeout is a poll, so this loop stays
            # responsive to both listeners without a thread for each.
            self._accept(self.guest_listen, "guest")
            self._accept(self.client_listen, "client")

            # select() with nothing registered is an error on Windows, and
            # nothing registered is the ordinary state between a guest booting
            # and a launcher arriving.
            if not self.sel.get_map():
                time.sleep(0.05)
                continue

            events = self.sel.select(timeout=0.05)
            for key, _ in events:
                sock = key.fileobj
                which = key.data
                try:
                    data = sock.recv(4096)
                except (BlockingIOError, InterruptedError):
                    continue
                except OSError:
                    data = b""
                if not data:
                    self.say("%s went away" % which)
                    self._drop(sock)
                    continue

                if which == "guest":
                    self.from_guest += len(data)
                    # No client is not an error. The guest talks to itself
                    # between launchers and nobody needs to hear it.
                    if self.client is not None:
                        self._send(self.client, data, "client")
                else:
                    self.from_client += len(data)
                    if self.guest is not None:
                        self._send(self.guest, data, "guest")

    def _send(self, sock: socket.socket, data: bytes, which: str) -> None:
        try:
            sock.sendall(data)
        except OSError:
            self.say("%s stopped listening mid-write" % which)
            self._drop(sock)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--guest-port", type=int, default=4555,
                    help="the port QEMU dials out to")
    ap.add_argument("--client-port", type=int, default=4556,
                    help="the port the launcher and tools connect to")
    ap.add_argument("--ready-file", default="",
                    help="written once both ports are bound, so a script can "
                         "start the emulator without guessing at a delay")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    try:
        bridge = Bridge(args.guest_port, args.client_port, args.host,
                        not args.quiet)
    except OSError as e:
        print("combridge: could not bind (%s)" % e, file=sys.stderr)
        return 1

    if args.ready_file:
        with open(args.ready_file, "w") as fh:
            fh.write(str(args.client_port))

    try:
        bridge.run()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
