#!/usr/bin/env python3
"""
vnc_gaps.py - time the arrival of the guest's frames, and nothing else.

Written to answer one question - "it still stutters, what is stalling?" - and
it took several wrong tools to get here, each of which measured itself:

  - vnc_probe copies every pixel in a Python loop, which for a large rectangle
    is a tenth of a second of work. That is the same size as the stalls being
    hunted, so it cannot be used to hunt them. This reads the same stream and
    throws the pixels away.

  - Driving the animation from the host - keystrokes, or the pointer moved in a
    circle - couples the measurement to the thing measured. When the driver
    hiccups the guest's screen stops changing, the emulator correctly sends
    nothing, and the tool records a gap of its own making. So this sends the
    guest nothing at all; give it something that animates on its own.

  - Asking the guest how it is doing, over the bridge, several times a second,
    loads it enough to change the answer.

What it prints: the distribution of gaps between arriving updates, how many
were long, and the size of the update that ended each of the longest. That last
column separates the two explanations - a server saving up a repaint sends a
big update afterwards, a server that was simply quiet sends an ordinary one.

    python tools/vnc_gaps.py 25

Run two at once, in separate processes, to tell a server stall from a client
one: if both report the same numbers, it is not the client.
"""
import socket
import statistics
import struct
import sys
import time

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 25.0
HOST, PORT = "127.0.0.1", 5909


def recv_exact(sock, n):
    out = b""
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise EOFError
        out += chunk
    return out


sock = socket.create_connection((HOST, PORT), timeout=20)
sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

version = recv_exact(sock, 12)
sock.sendall(b"RFB 003.008\n")
n = recv_exact(sock, 1)[0]
recv_exact(sock, n)
sock.sendall(bytes([1]))
if struct.unpack(">I", recv_exact(sock, 4))[0] != 0:
    raise SystemExit("security handshake refused")
sock.sendall(bytes([1]))                       # shared
# ServerInit: width, height, sixteen bytes of pixel format, then the name.
head = recv_exact(sock, 24)
w, h = struct.unpack(">HH", head[:4])
namelen = struct.unpack(">I", head[20:24])[0]
recv_exact(sock, namelen)
print("connected: %dx%d, %s" % (w, h, version.strip().decode()))

# Pin the format so four bytes a pixel is a fact rather than an assumption,
# then ask for raw only. This is a reader, not a renderer - the pixels are
# counted and dropped.
fmt = struct.pack(">BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
sock.sendall(struct.pack(">Bxxx", 0) + fmt)
sock.sendall(struct.pack(">BxH", 2, 1) + struct.pack(">i", 0))


def request():
    sock.sendall(struct.pack(">BBHHHH", 3, 1, 0, 0, w, h))


def read_update():
    """Pixels covered by one update, or None for a non-update message."""
    msg = recv_exact(sock, 1)[0]
    if msg == 2:
        return None
    if msg == 3:
        recv_exact(sock, 3)
        n = struct.unpack(">I", recv_exact(sock, 4))[0]
        recv_exact(sock, n)
        return None
    if msg == 1:
        recv_exact(sock, 3)
        _first, count = struct.unpack(">HH", recv_exact(sock, 4))
        recv_exact(sock, count * 6)
        return None
    if msg != 0:
        raise SystemExit("unexpected server message %d" % msg)
    recv_exact(sock, 1)
    (nrects,) = struct.unpack(">H", recv_exact(sock, 2))
    pixels = 0
    for _ in range(nrects):
        x, y, rw, rh, enc = struct.unpack(">HHHHi", recv_exact(sock, 12))
        if enc != 0:
            raise SystemExit("encoding %d, expected raw" % enc)
        recv_exact(sock, rw * rh * 4)
        pixels += rw * rh
    return pixels


request()
events = []
t0 = time.time()
last = None
while time.time() - t0 < SECONDS:
    got = read_update()
    if got is None:
        continue
    now = time.time()
    request()
    if last is not None:
        events.append(((now - last) * 1000.0, got))
    last = now
span = time.time() - t0
sock.close()

gaps = [g for g, _ in events]
print("\n%d updates in %.0fs  (%.1f/s)" % (len(events), span, len(events) / span))
s = sorted(gaps)
print("gap: median %.1f ms  p90 %.1f  p99 %.1f  max %.1f"
      % (statistics.median(s), s[int(len(s) * 0.9)],
         s[int(len(s) * 0.99)], s[-1]))
for edge in (60, 100):
    k = [g for g in gaps if g > edge]
    print("gaps over %d ms: %d  (%.2f/s)" % (edge, len(k), len(k) / span))

typical = statistics.median([p for _, p in events])
print("\npixels per update: median %d   (a whole screen is %d)" % (typical, w * h))
print("\nthe ten longest gaps, and the update that ended each:")
for g, px in sorted(events, key=lambda e: -e[0])[:10]:
    print("   %7.1f ms   %8d pixels   %s"
          % (g, px, "FULL SCREEN" if px >= w * h else
             ("large" if px > typical * 20 else "ordinary")))
