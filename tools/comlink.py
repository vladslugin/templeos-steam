#!/usr/bin/env python3
"""
comlink.py - accept the guest's serial connection.

The guest dials out. QEMU is given -serial tcp:HOST:PORT,reconnect-ms=1000, so
it knocks on this port once a second for as long as it runs, and whoever is
listening gets the bridge.

That is the opposite of the obvious arrangement and it is deliberate. With QEMU
as the server its serial socket takes one client for the life of the guest: the
launcher connects, the player closes it, and every launcher after that is
refused - the port still shows as listening and simply never accepts again.
There is no way out of that except restarting the emulator, which for a player
means restarting the game. Reversed, closing one client and opening another is
a second's wait and no more.

It also means the tooling can hand the bridge over. wait_guest.py listens until
the guest speaks, then lets go; the launcher starts listening; the guest
reconnects on its next knock. Nothing coordinates that beyond closing a socket.

One catch, and it decides the order everything starts in: QEMU treats the
FIRST connection failing as fatal and exits, even with reconnect-ms set. Only
later failures are retried. So the port has to be bound before the emulator
starts, which is why this is a class - bind now, accept later:

    link = comlink.Listener(4555)         # bound; safe to start QEMU now
    sock = link.accept(timeout=180)       # blocks until the guest calls
    link.close()

Once that first connection has been made, the guest survives losing it and
knocks again every second, so handing the bridge from one host process to the
next needs no more than closing a socket.
"""

from __future__ import annotations

import socket
import time


class Listener:
    """A bound port waiting for the guest.

    Binding happens in the constructor so the caller can start the emulator
    immediately afterwards and know the port is already there.
    """

    def __init__(self, port: int, host: str = "127.0.0.1", backlog: int = 1):
        self.port = port
        self.host = host
        # SO_REUSEADDR because the previous holder may still be in TIME_WAIT,
        # and making a player wait out a TCP timer to reopen the launcher
        # would be a strange thing to ship.
        self._srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._srv.bind((host, port))
        self._srv.listen(backlog)
        self._srv.settimeout(0.5)

    def accept(self, timeout: float = 180.0):
        """The guest's socket, or None if it never called.

        A timeout of zero is a poll: one look, no waiting. That is what a
        select loop wants when it is minding two listeners at once.
        """
        deadline = time.time() + timeout
        first = True
        while first or time.time() < deadline:
            first = False
            try:
                self._srv.settimeout(0.0 if timeout <= 0 else 0.5)
                conn, _ = self._srv.accept()
            except (socket.timeout, BlockingIOError):
                if timeout <= 0:
                    return None
                continue
            except OSError:
                return None
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            return conn
        return None

    def close(self) -> None:
        # Holding this open would take the next reconnection away from whoever
        # should have it next.
        try:
            self._srv.close()
        except OSError:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def listen(port: int, host: str = "127.0.0.1", timeout: float = 180.0,
           backlog: int = 1) -> socket.socket | None:
    """Bind and wait in one go. Only safe when the emulator is already up."""
    link = Listener(port, host, backlog)
    try:
        return link.accept(timeout)
    finally:
        link.close()
