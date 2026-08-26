#!/usr/bin/env python3
r"""
eventbridge_host.py - the host end of the guest bridge.

Two jobs. It is the bring-up rig: attach to the guest's COM1, watch the event
stream, poke a command in by hand. And it is the reference parser - the real
launcher uses these same functions, and the selftest below exercises them
without needing QEMU at all.

Transport:
  Linux/macOS  qemu -serial unix:<path>,server,nowait   -> AF_UNIX
  Windows      qemu -serial pipe:<name>                 -> \\.\pipe\<name>

Usage:
    python tools/eventbridge_host.py --listen /tmp/temple.sock
    python tools/eventbridge_host.py --listen temple --pipe        # Windows
    python tools/eventbridge_host.py --selftest                    # no QEMU needed
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PROTO_VER = 1
LINE_MAX = 240

# The host only accepts event ids it knows about. data/events.json is the source
# of truth; this fallback keeps the tool usable before that file exists.
EVENTS_FALLBACK = {
    "help_open": [],
    "help_topic": ["name"],
    "shell_cmd": ["name"],
    "ed_save": ["path"],
    "ed_run": ["path"],
    "file_open": ["path"],
    "file_run": ["path"],
    "sprite_saved": ["colors"],
    "task_loaded": ["id"],
    "task_done": ["id", "sig", "hinted"],
    "godword_used": [],
    "goddoodle_used": [],
    "godsong_done": [],
    "crash_recovered": ["addr"],
    "loc_counted": ["lines"],
    "arcade_start": ["game"],
    "arcade_win": ["game", "score"],
    "stat": ["name", "value"],
}


def load_events() -> dict:
    path = os.path.join(ROOT, "data", "events.json")
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return {e["id"]: e.get("fields", []) for e in doc.get("events", [])}
    return dict(EVENTS_FALLBACK)


# Parsing. Pure functions, no sockets, so the selftest can hit them directly.

class ProtocolError(Exception):
    pass


def parse_kv(parts: list[str]) -> dict:
    """Pull k=v pairs off the tail of a line. Bare tokens are ignored."""
    out = {}
    for p in parts:
        if "=" in p:
            k, _, v = p.partition("=")
            if k:
                out[k] = v
    return out


def parse_line(line: str) -> dict:
    """Parse one guest->host line into {'kind': 'hello'|'ev'|'hb'|'log', ...}.

    Raises ProtocolError on junk. The caller decides whether that is fatal;
    during bring-up it usually just gets logged.
    """
    line = line.rstrip("\r\n")
    if len(line) > LINE_MAX:
        raise ProtocolError(f"line over {LINE_MAX} bytes: {len(line)}")
    if not line:
        raise ProtocolError("empty line")

    parts = line.split(" ")
    verb = parts[0]

    if verb == "HELLO":
        if len(parts) < 4:
            raise ProtocolError(f"HELLO wants 3 fields, got {len(parts) - 1}")
        return {
            "kind": "hello",
            "proto": parts[1],
            "os_build": parts[2],
            "layer_ver": parts[3],
        }
    if verb == "EV":
        if len(parts) < 2:
            raise ProtocolError("EV with no event id")
        return {"kind": "ev", "id": parts[1], "fields": parse_kv(parts[2:])}
    if verb == "HB":
        if len(parts) < 2:
            raise ProtocolError("HB with no jiffies")
        return {"kind": "hb", "jiffies": parts[1]}
    if verb == "LOG":
        return {"kind": "log", "text": " ".join(parts[1:])}
    raise ProtocolError(f"unknown verb: {verb!r}")


def validate_event(msg: dict, whitelist: dict) -> list[str]:
    """Check an event against the whitelist. Returns a list of complaints."""
    problems = []
    eid = msg["id"]
    if eid not in whitelist:
        problems.append(f"event not in whitelist: {eid!r}")
        return problems
    for field in whitelist[eid]:
        if field not in msg["fields"]:
            problems.append(f"{eid}: missing required field {field!r}")
    # A task_done with no signature is almost always a double fire.
    if eid == "task_done" and not msg["fields"].get("sig"):
        problems.append("task_done without sig= - dropped")
    return problems


def make_cmd(name: str, **kw) -> str:
    """Build a host->guest line."""
    parts = ["CMD", name] + [f"{k}={v}" for k, v in kw.items()]
    line = " ".join(parts)
    if len(line) > LINE_MAX:
        raise ProtocolError(f"command over {LINE_MAX} bytes")
    return line


# Transport

class Transport:
    """Common shape over AF_UNIX and Windows named pipes."""

    def readline(self) -> str | None:  # pragma: no cover - I/O
        raise NotImplementedError

    def write(self, line: str) -> None:  # pragma: no cover - I/O
        raise NotImplementedError

    def close(self) -> None:  # pragma: no cover - I/O
        pass


class UnixTransport(Transport):  # pragma: no cover - needs QEMU
    def __init__(self, path: str):
        if os.path.exists(path):
            os.unlink(path)
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(1)
        print(f"waiting for the guest on {path} ...")
        self.conn, _ = self.srv.accept()
        print("guest connected")
        self.buf = b""

    def readline(self):
        while b"\n" not in self.buf:
            chunk = self.conn.recv(4096)
            if not chunk:
                return None
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\n")
        return line.decode("ascii", errors="replace")

    def write(self, line):
        self.conn.sendall(line.encode("ascii") + b"\n")

    def close(self):
        self.conn.close()
        self.srv.close()


class TcpTransport(Transport):  # pragma: no cover - needs QEMU
    """Attach to `-serial tcp:HOST:PORT,server,nowait`.

    Preferred while developing: identical on every host, and QEMU does not stall
    at start-up waiting for us to show up, so the bridge can attach late or
    reattach after a crash.
    """

    def __init__(self, host: str, port: int, timeout: float = 60.0):
        print(f"connecting to the guest's COM1 at {host}:{port} ...")
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.create_connection((host, port), timeout=5)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.5)
        self.sock.settimeout(None)
        print("attached")
        self.buf = b""

    def readline(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                return None
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\n")
        return line.decode("ascii", errors="replace")

    def write(self, line):
        self.sock.sendall(line.encode("ascii") + b"\n")

    def close(self):
        self.sock.close()


class PipeTransport(Transport):  # pragma: no cover - needs Windows + QEMU
    r"""QEMU -serial pipe:<name> creates \\.\pipe\<name>.in and .out."""

    def __init__(self, name: str):
        self.r = open(rf"\\.\pipe\{name}.out", "rb", buffering=0)
        self.w = open(rf"\\.\pipe\{name}.in", "wb", buffering=0)
        self.buf = b""

    def readline(self):
        while b"\n" not in self.buf:
            chunk = self.r.read(4096)
            if not chunk:
                return None
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\n")
        return line.decode("ascii", errors="replace")

    def write(self, line):
        self.w.write(line.encode("ascii") + b"\n")

    def close(self):
        self.r.close()
        self.w.close()


class Session:
    def __init__(self, transport: Transport, whitelist: dict, verbose=True, log=None):
        self.t = transport
        self.whitelist = whitelist
        self.verbose = verbose
        self.log = log
        self.stats = {"ev": 0, "hb": 0, "log": 0, "bad": 0, "rejected": 0}
        self.events: list[dict] = []
        self.hello = None
        self.last_hb = None

    def handle(self, raw: str) -> None:
        if self.log:
            with open(self.log, "a", encoding="utf-8") as fh:
                fh.write(raw + chr(10))
        try:
            msg = parse_line(raw)
        except ProtocolError as exc:
            self.stats["bad"] += 1
            print(f"  [protocol] {exc}  <- {raw!r}")
            return

        kind = msg["kind"]
        if kind == "hello":
            self.hello = msg
            print(f"  HELLO proto={msg['proto']} os={msg['os_build']} layer={msg['layer_ver']}")
            if msg["proto"] != str(PROTO_VER):
                print(f"  [warn] guest speaks proto {msg['proto']}, host expects {PROTO_VER}")
            self.t.write("ACK HELLO")
        elif kind == "ev":
            self.stats["ev"] += 1
            problems = validate_event(msg, self.whitelist)
            if problems:
                self.stats["rejected"] += 1
                for p in problems:
                    print(f"  [rejected] {p}")
                return
            self.events.append(msg)
            fields = " ".join(f"{k}={v}" for k, v in msg["fields"].items())
            print(f"  EV {msg['id']} {fields}".rstrip())
            self.t.write(f"ACK {msg['id']}")
        elif kind == "hb":
            self.stats["hb"] += 1
            self.last_hb = msg["jiffies"]
            if self.verbose:
                print(f"  HB {msg['jiffies']}")
        elif kind == "log":
            self.stats["log"] += 1
            print(f"  LOG {msg['text']}")

    def run(self) -> None:  # pragma: no cover - I/O
        while True:
            raw = self.t.readline()
            if raw is None:
                print("guest disconnected")
                return
            self.handle(raw)


def selftest() -> int:
    ok = failed = 0

    def check(name, cond):
        nonlocal ok, failed
        if cond:
            ok += 1
        else:
            failed += 1
            print(f"  FAIL: {name}")

    wl = load_events()

    m = parse_line("HELLO 1 TempleOS-5.03 0.1.0")
    check("HELLO parses", m["kind"] == "hello" and m["layer_ver"] == "0.1.0")

    m = parse_line("EV task_done id=hc_fib sig=1A2B3C4D hinted=0")
    check("EV parses", m["kind"] == "ev" and m["id"] == "task_done")
    check("EV fields", m["fields"]["id"] == "hc_fib" and m["fields"]["hinted"] == "0")
    check("task_done with sig passes", validate_event(m, wl) == [])

    m = parse_line("EV task_done id=hc_fib hinted=0")
    check("task_done without sig rejected", validate_event(m, wl) != [])

    m = parse_line("EV not_a_real_event")
    check("unknown event rejected", validate_event(m, wl) != [])

    m = parse_line("HB 123456")
    check("HB parses", m["kind"] == "hb" and m["jiffies"] == "123456")

    m = parse_line("LOG ERROR: Missing ';' at")
    check("LOG keeps its spaces", m["text"] == "ERROR: Missing ';' at")

    for bad in ["", "NOPE x", "HELLO 1", "EV", "HB"]:
        try:
            parse_line(bad)
            check(f"junk rejected: {bad!r}", False)
        except ProtocolError:
            check(f"junk rejected: {bad!r}", True)

    try:
        parse_line("EV x " + "y" * LINE_MAX)
        check("overlong line rejected", False)
    except ProtocolError:
        check("overlong line rejected", True)

    check("make_cmd", make_cmd("load_task", id="hc_fib") == "CMD load_task id=hc_fib")
    try:
        make_cmd("hint", id="x" * LINE_MAX)
        check("overlong command rejected", False)
    except ProtocolError:
        check("overlong command rejected", True)

    # Paths and compiler text can carry '=' inside a value.
    m = parse_line("EV file_open path=/Home/A=B.HC")
    check("'=' inside a value", m["fields"]["path"] == "/Home/A=B.HC")

    print(f"\nselftest: {ok} passed, {failed} failed")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--listen", metavar="PATH", help="unix socket path or pipe name")
    ap.add_argument("--tcp", metavar="PORT", type=int,
                    help="attach to the guest's COM1 over TCP (matches run_qemu.sh --serial PORT)")
    ap.add_argument("--pipe", action="store_true", help="Windows named pipe instead of a unix socket")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--log", metavar="PATH", help="append every line seen to this file")
    ap.add_argument("--selftest", action="store_true", help="exercise the parser without QEMU")
    ap.add_argument("--quiet-hb", action="store_true", help="do not print heartbeats")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not args.listen and not args.tcp:
        ap.error("need --tcp, --listen or --selftest")

    wl = load_events()
    print(f"whitelist: {len(wl)} events")
    if args.tcp:
        transport = TcpTransport(args.host, args.tcp)
    elif args.pipe:
        transport = PipeTransport(args.listen)
    else:
        transport = UnixTransport(args.listen)
    sess = Session(transport, wl, verbose=not args.quiet_hb, log=args.log)
    try:
        sess.run()
    except KeyboardInterrupt:
        pass
    finally:
        transport.close()
        print(f"\ntotals: {sess.stats}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
