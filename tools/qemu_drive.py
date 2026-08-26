#!/usr/bin/env python3
"""
qemu_drive.py - drive a running guest through the QEMU monitor.

Needed because the TempleOS installer asks questions, and CI has nobody to
answer them. Also how we grab screenshots for a regression check on a task that
draws something: the campaign checks framebuffer output, and comparing hashes of
a screen region only works if something can capture the screen.

Start the guest with a monitor port:

    bash tools/run_qemu.sh --install --headless --monitor 4444

then:

    python tools/qemu_drive.py --port 4444 shot build/boot.png
    python tools/qemu_drive.py --port 4444 keys ret
    python tools/qemu_drive.py --port 4444 type 'Dir;'
    python tools/qemu_drive.py --port 4444 cmd 'info status'

Screenshots come back as PPM from the monitor and are converted to PNG here so
they can be looked at directly. PNG is written by hand - zlib and struct only,
no third-party imaging library, same as the rest of tools/.

Key names are QEMU's own (ret, spc, esc, kp_enter, a, 1, shift-a, ctrl-alt-c).
`type` spells a string out into sendkey calls, which is slower but survives the
guest not having a paste buffer.

Queue lines with backslashes in them - which is most HolyC worth typing - want a
quoted heredoc, not printf. Feeding `"x\n"` through printf mangles the escape and
the guest ends up compiling something you did not write; that shows up as a
baffling compiler error about a character constant rather than as a typo:

    cat >> build/mon_queue.txt <<'EOF'
    type '"hi\n";' --enter
    EOF
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import struct
import sys
import time
import zlib

CRLF = chr(13) + chr(10)  # QMP wants CRLF-terminated JSON

# Characters that need a shift, plus their unshifted key name.
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal", "{": "bracket_left",
    "}": "bracket_right", "|": "backslash", ":": "semicolon", '"': "apostrophe",
    "<": "comma", ">": "dot", "?": "slash", "~": "grave_accent",
}
PLAIN = {
    " ": "spc", "-": "minus", "=": "equal", "[": "bracket_left",
    "]": "bracket_right", "\\": "backslash", ";": "semicolon",
    "'": "apostrophe", ",": "comma", ".": "dot", "/": "slash",
    "`": "grave_accent", "\n": "ret", "\t": "tab",
}


class Monitor:
    """QMP client.

    QMP frames every message as one JSON object per line and answers each
    command with a return or an error, so there is no guessing about where a
    reply ends - which is exactly what the human monitor got wrong here.
    """

    def __init__(self, host: str, port: int, timeout: float = 30.0, retries: int = 8):
        # The chardev serves one client at a time, and on Windows a dropped
        # client can sit in CLOSE_WAIT long enough to refuse the next connect.
        last = None
        for attempt in range(retries):
            try:
                self.sock = socket.create_connection((host, port), timeout=timeout)
                break
            except OSError as exc:
                last = exc
                time.sleep(0.4 * (attempt + 1))
        else:
            raise last
        self.sock.settimeout(timeout)
        self.f = self.sock.makefile("rwb")
        greeting = self._read()          # {"QMP": {...}}
        if "QMP" not in greeting:
            raise RuntimeError(f"not a QMP endpoint: {greeting!r}")
        self.version = greeting["QMP"]["version"]["qemu"]
        self.execute("qmp_capabilities")

    def _read(self) -> dict:
        while True:
            line = self.f.readline()
            if not line:
                raise ConnectionError("QMP closed")
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            if "event" in msg:           # asynchronous, not our reply
                continue
            return msg

    def execute(self, command: str, **arguments) -> dict:
        req = {"execute": command}
        if arguments:
            req["arguments"] = arguments
        self.f.write((json.dumps(req) + CRLF).encode())
        self.f.flush()
        reply = self._read()
        if "error" in reply:
            raise RuntimeError(f"{command}: {reply['error']['desc']}")
        return reply.get("return", {})

    def cmd(self, line: str, wait: float = 1.5) -> str:
        """Run a human-monitor command through QMP for the things QMP lacks."""
        out = self.execute("human-monitor-command", **{"command-line": line})
        return out.strip() if isinstance(out, str) else json.dumps(out)

    def close(self):
        try:
            self.f.close()
        finally:
            self.sock.close()


def write_png(path: str, width: int, height: int, rgb: bytes) -> None:
    """Minimal RGB8 PNG writer."""
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)  # filter type 0
        raw += rgb[y * stride:(y + 1) * stride]

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def read_ppm(path: str):
    """Parse the binary P6 PPM that `screendump` writes."""
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(b"P6"):
        raise ValueError(f"not a P6 PPM: {data[:16]!r}")
    fields, pos = [], 2
    while len(fields) < 3:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            while data[pos:pos + 1] not in (b"\n", b""):
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1  # single whitespace after maxval
    w, h, _maxval = fields
    return w, h, data[pos:pos + w * h * 3]


def to_keys(text: str):
    for ch in text:
        if ch in SHIFTED:
            yield f"shift-{SHIFTED[ch]}"
        elif ch in PLAIN:
            yield PLAIN[ch]
        elif ch.isupper():
            yield f"shift-{ch.lower()}"
        elif ch.isalnum():
            yield ch
        else:
            raise ValueError(f"no key mapping for {ch!r}")


def do_shot(mon: "Monitor", out: str) -> str:
    out = os.path.abspath(out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    ppm = out + ".ppm"
    if os.path.exists(ppm):
        os.unlink(ppm)
    # QEMU writes the file itself, so it needs a path it can resolve, and its
    # parser is happier with forward slashes. Native QMP rather than the human
    # monitor: a failure comes back as an error instead of as silence.
    mon.execute("screendump", filename=ppm.replace(os.sep, "/"))
    for _ in range(24):
        if os.path.isfile(ppm) and os.path.getsize(ppm) > 0:
            break
        time.sleep(0.25)
    if not os.path.isfile(ppm):
        return "ERROR: screendump produced nothing"
    w, h, rgb = read_ppm(ppm)
    write_png(out, w, h, rgb)
    os.unlink(ppm)
    return f"{out}  {w}x{h}"


def run_action(mon: "Monitor", line: str, delay: float) -> str:
    """Execute one queued line. Shape mirrors the CLI subcommands."""
    line = line.strip()
    if not line or line.startswith("#"):
        return ""
    verb, _, rest = line.partition(" ")
    rest = rest.strip()
    try:
        if verb == "shot":
            return do_shot(mon, rest)
        if verb == "keys":
            names = rest.split()
            for name in names:
                mon.cmd(f"sendkey {name}", wait=0.15)
                time.sleep(delay)
            return f"sent {len(names)} key(s): {' '.join(names)}"
        if verb == "type":
            enter = rest.endswith(" --enter")
            if enter:
                rest = rest[: -len(" --enter")]
            if len(rest) >= 2 and rest[0] == rest[-1] and rest[0] in "'\"":
                rest = rest[1:-1]
            names = list(to_keys(rest))
            for name in names:
                mon.cmd(f"sendkey {name}", wait=0.1)
                time.sleep(delay)
            if enter:
                mon.cmd("sendkey ret", wait=0.1)
            return f"typed {len(names)} char(s)"
        if verb == "cmd":
            return mon.cmd(rest, wait=1.5)
        if verb == "sleep":
            time.sleep(float(rest))
            return f"slept {rest}s"
        return f"ERROR: unknown action {verb!r}"
    except Exception as exc:  # keep the session alive whatever one action does
        return f"ERROR: {exc}"


def serve(args) -> int:
    """Hold a single monitor connection and drain a queue file.

    QEMU's socket chardev on Windows keeps a disconnected client in CLOSE_WAIT
    and refuses further connections, so connect-per-command does not work. One
    long-lived connection sidesteps that, and it is what CI wants anyway.
    """
    queue, out = os.path.abspath(args.queue), os.path.abspath(args.out)
    for path in (queue, out):
        os.makedirs(os.path.dirname(path), exist_ok=True)
    open(queue, "a").close()
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("")

    try:
        mon = Monitor(args.host, args.port)
    except OSError as exc:
        print(f"cannot reach the monitor at {args.host}:{args.port}: {exc}", file=sys.stderr)
        return 1

    def emit(text: str):
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(text + "\n")

    emit(f"# connected to {args.host}:{args.port}")
    print(f"serving; append actions to {queue}, results land in {out}", flush=True)

    seen = 0
    idle = 0
    try:
        while True:
            try:
                with open(queue, encoding="utf-8") as fh:
                    lines = fh.read().splitlines()
            except FileNotFoundError:
                # Somebody cleared the queue between polls. Start over rather
                # than dying and taking the monitor connection with us.
                open(queue, "a").close()
                seen = 0
                continue
            if len(lines) > seen:
                idle = 0
                for line in lines[seen:]:
                    if line.strip() == "quit":
                        emit("# quit")
                        return 0
                    result = run_action(mon, line, args.delay)
                    if result:
                        emit(f"$ {line}\n{result}")
                seen = len(lines)
            else:
                idle += 1
                time.sleep(0.3)
                if idle > 4000:  # ~20 min with nothing to do
                    emit("# idle timeout")
                    return 0
    finally:
        mon.close()


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4444)
    ap.add_argument("--delay", type=float, default=0.05, help="pause between keystrokes")
    sub = ap.add_subparsers(dest="action", required=True)

    p = sub.add_parser("shot", help="grab the screen as PNG")
    p.add_argument("out")

    p = sub.add_parser("keys", help="send QEMU key names")
    p.add_argument("names", nargs="+")

    p = sub.add_parser("type", help="spell out a string")
    p.add_argument("text")
    p.add_argument("--enter", action="store_true", help="press Return afterwards")

    p = sub.add_parser("cmd", help="raw monitor command")
    p.add_argument("line")

    p = sub.add_parser(
        "serve",
        help="hold one connection open and execute commands appended to a queue file",
    )
    p.add_argument("--queue", required=True)
    p.add_argument("--out", required=True)

    args = ap.parse_args()

    if args.action == "serve":
        return serve(args)

    try:
        mon = Monitor(args.host, args.port)
    except OSError as exc:
        print(f"cannot reach the monitor at {args.host}:{args.port}: {exc}", file=sys.stderr)
        print("is the guest running with --monitor?", file=sys.stderr)
        return 1

    try:
        if args.action == "shot":
            out = os.path.abspath(args.out)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            ppm = out + ".ppm"
            # The monitor writes the file itself, so it needs a host path it can
            # resolve. Backslashes confuse its parser; forward slashes are fine.
            mon.cmd(f'screendump "{ppm.replace(os.sep, "/")}"', wait=2.5)
            for _ in range(20):
                if os.path.isfile(ppm) and os.path.getsize(ppm) > 0:
                    break
                time.sleep(0.25)
            if not os.path.isfile(ppm):
                print("screendump produced nothing", file=sys.stderr)
                return 1
            w, h, rgb = read_ppm(ppm)
            write_png(out, w, h, rgb)
            os.unlink(ppm)
            print(f"{out}  {w}x{h}")

        elif args.action == "keys":
            for name in args.names:
                mon.cmd(f"sendkey {name}", wait=0.15)
                time.sleep(args.delay)
            print(f"sent {len(args.names)} key(s)")

        elif args.action == "type":
            names = list(to_keys(args.text))
            for name in names:
                mon.cmd(f"sendkey {name}", wait=0.1)
                time.sleep(args.delay)
            if args.enter:
                mon.cmd("sendkey ret", wait=0.1)
            print(f"typed {len(names)} char(s)")

        elif args.action == "cmd":
            print(mon.cmd(args.line, wait=1.5))
    finally:
        mon.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
