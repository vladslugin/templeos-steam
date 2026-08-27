#!/usr/bin/env python3
"""
ci_tasks.py - check every campaign task against a real guest, unattended.

The spec asks each task for two things: a reference solution that passes, and a
negative test proving an untouched template does not. Doing that by hand costs a
VM session per task, which does not survive fifty-seven of them.

The awkward part is that the disk cannot be written while QEMU has it open. So
the suite runs in two passes over the same image:

    pass 1  every task's template deployed   -> every task must FAIL
    pass 2  every task's solution deployed   -> every task must PASS

Two boots for the whole campaign rather than two per task. Within a pass the
host drives each task over the bridge with CMD check_task and reads the answer,
so adding a task costs no extra boot at all.

The guest is never trusted to be ready: the run waits for HELLO before sending
anything, and every check waits for that task's own task_checked reply.

    python tools/ci_tasks.py --image build/temple_disk.raw
    python tools/ci_tasks.py --image build/temple_disk.raw --task hc_fib
    python tools/ci_tasks.py --image build/temple_disk.raw --keep-going

Exit code is 0 only if every task failed when it should and passed when it should.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comlink  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from fat32 import Fat32                       # noqa: E402
from qemu_drive import Monitor                # noqa: E402
from eventbridge_host import parse_line, ProtocolError  # noqa: E402

TASK_DIR = os.path.join(ROOT, "data", "tasks")


def log(msg: str) -> None:
    print(msg, flush=True)


# ---------------------------------------------------------------- task loading

def load_tasks(only: str | None) -> list[dict]:
    tasks = []
    for path in sorted(glob.glob(os.path.join(TASK_DIR, "*.json"))):
        with open(path, encoding="utf-8") as fh:
            t = json.load(fh)
        if only and t["id"] != only:
            continue
        t["_path"] = path
        tasks.append(t)
    return tasks


def template_path(t: dict) -> str:
    rel = t.get("template") or f"guest/Game/Tasks/{t['id']}/Start.HC"
    return os.path.join(ROOT, rel)


def solution_path(t: dict) -> str:
    return os.path.join(ROOT, "guest", "Game", "Tasks", t["id"], "Solution.HC")


# ------------------------------------------------------------------- deploying

def deploy(image: str, tasks: list[dict], which: str) -> None:
    """Put the layer plus each task's template or solution into the image."""
    fs = Fat32(image, readonly=False)
    try:
        fs.mkdir("/Game")
        for src in sorted(glob.glob(os.path.join(ROOT, "guest", "Game", "*.HC"))):
            with open(src, "rb") as fh:
                fs.write_file("/Game/" + os.path.basename(src), fh.read())

        home = os.path.join(ROOT, "guest", "Home", "MakeHome.HC")
        if os.path.isfile(home):
            fs._remove(fs.resolve("/Home")[2], "MakeHome.HC.Z")
            with open(home, "rb") as fh:
                fs.write_file("/Home/MakeHome.HC", fh.read())

        for t in tasks:
            src = template_path(t) if which == "template" else solution_path(t)
            if not os.path.isfile(src):
                raise FileNotFoundError(f"{t['id']}: missing {which} at {src}")
            with open(src, "rb") as fh:
                data = fh.read()
            fs.write_file(t["start_file"], data)
    finally:
        fs.close()


# ----------------------------------------------------------------------- guest

def _default_accel() -> str:
    """Whatever this host can actually do, with QEMU falling back if it cannot.

    The suite used to default to emulation everywhere because WHPX was believed
    broken on this guest. It is not - see the machine string in Guest.start -
    and a full two-pass run over the campaign is long enough that six times
    faster is the difference between a check you run and a check you skip.
    """
    if sys.platform == "win32":
        return "whpx"
    if sys.platform == "darwin":
        return "hvf"
    return "kvm" if os.access("/dev/kvm", os.W_OK) else "tcg"


class Guest:
    """A booted guest with its QMP and bridge connections."""

    def __init__(self, image: str, qmp_port: int, com_port: int, accel: str):
        self.proc = None
        self.mon = None
        self.sock = None
        self.buf = b""
        self.image = image
        self.qmp_port = qmp_port
        self.com_port = com_port
        self.accel = accel

    def start(self) -> None:
        qemu = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
        # Bound before the emulator starts, not after: it dials out to us and
        # treats a failed first connection as fatal. See tools/comlink.py.
        link = comlink.Listener(self.com_port)
        # The accelerator goes in the machine string as a list so QEMU falls
        # back on its own where the first one is not installed.
        #
        # kernel_irqchip=on is not decoration. With the interrupt controller
        # left outside the hypervisor partition, WHPX aborts during boot in
        # QEMU's own x86 decoder; leave it inside and the guest runs about six
        # times faster than emulated. It is inert under TCG, so one string
        # serves both.
        accel = self.accel if self.accel == "tcg" else "%s:tcg" % self.accel
        args = [
            qemu,
            "-machine", "pc,kernel_irqchip=on,accel=%s" % accel,
            # qemu64 whatever the accelerator. Under WHPX, host and max both
            # leave the guest with no display and no error worth the name.
            "-cpu", "qemu64",
            # Two cores: emulated, more of them is slower rather than faster,
            # and accelerated they buy nothing. A campaign task needs two.
            "-smp", "cores=2",
            "-m", "2048",
            "-rtc", "base=localtime",
            # Name the format; probing makes QEMU refuse writes to block 0.
            "-drive", "file=%s,format=raw,index=0,media=disk" % self.image,
            # The guest dials out; the suite listens. The long chardev form
            # matters: -serial tcp:...,reconnect-ms exits when the peer goes
            # away instead of reconnecting. See tools/comlink.py.
            "-chardev",
            f"socket,id=com1,host=127.0.0.1,port={self.com_port},reconnect-ms=1000",
            "-serial", "chardev:com1",
            "-qmp", f"tcp:127.0.0.1:{self.qmp_port},server,nowait",
            "-display", "none",
        ]
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.STDOUT)
        self.mon = Monitor("127.0.0.1", self.qmp_port, retries=30)
        self.sock = link.accept(timeout=60.0)
        link.close()
        if self.sock is None:
            raise SystemExit("the guest never opened its serial connection")
        self.sock.settimeout(1.0)

    def key(self, name: str) -> None:
        self.mon.cmd(f"sendkey {name}")

    def type_line(self, text: str) -> None:
        """Spell a line into the guest's keyboard and press return."""
        from qemu_drive import to_keys
        for name in to_keys(text):
            self.mon.cmd(f"sendkey {name}")
            time.sleep(0.04)
        self.mon.cmd("sendkey ret")

    def send(self, line: str) -> None:
        self.sock.sendall(line.encode("ascii") + b"\n")

    def readline(self, timeout: float) -> str | None:
        end = time.time() + timeout
        while time.time() < end:
            if b"\n" in self.buf:
                line, _, self.buf = self.buf.partition(b"\n")
                return line.decode("ascii", errors="replace").strip()
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                return None
            if not chunk:
                return None
            self.buf += chunk
        return None

    def wait_event(self, want: str, timeout: float) -> dict | None:
        """Read until an EV with this id arrives. Heartbeats are ignored."""
        end = time.time() + timeout
        while time.time() < end:
            raw = self.readline(max(1.0, end - time.time()))
            if raw is None:
                continue
            try:
                msg = parse_line(raw)
            except ProtocolError:
                continue
            if msg["kind"] == "hello" and want == "HELLO":
                return msg
            if msg["kind"] == "ev" and msg["id"] == want:
                return msg
            if msg["kind"] == "log":
                log(f"      guest LOG: {msg['text']}")
        return None

    def stop(self) -> None:
        for closer in (lambda: self.sock and self.sock.close(),
                       lambda: self.mon and self.mon.close()):
            try:
                closer()
            except Exception:
                pass
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def boot(guest: Guest, boot_timeout: float) -> bool:
    """Bring the guest to a running layer, answering what it asks on the way.

    Two prompts stand between power-on and a usable system, and neither should
    ever face a player - the boot menu in particular is a factory-image problem
    still to be solved. For now CI just answers them.
    """
    log("    booting ...")
    # Terry's boot menu: 0 old record, 1 drive C, 2 drive D.
    time.sleep(12)
    guest.key("1")
    # "Take Tour(y or n)?" comes up once the desktop is there.
    hello = guest.wait_event("HELLO", boot_timeout)
    if not hello:
        return False
    log(f"    layer up: proto {hello['proto']} {hello['os_build']} {hello['layer_ver']}")
    time.sleep(3)
    guest.key("n")
    time.sleep(2)
    return True


# ------------------------------------------------------------------------ pass

def run_pass(image: str, tasks: list[dict], which: str, args) -> dict[str, dict]:
    """Deploy one variant, boot, and check every task. Returns id -> result."""
    log(f"\n=== pass: {which} ===")
    work = image + f".{which}.tmp"
    shutil.copyfile(image, work)
    try:
        deploy(work, tasks, which)
        guest = Guest(work, args.qmp_port, args.com_port, args.accel)
        results: dict[str, dict] = {}
        try:
            guest.start()
            if not boot(guest, args.boot_timeout):
                log("    ERROR: the layer never announced itself")
                return {t["id"]: {"error": "no HELLO"} for t in tasks}

            for t in tasks:
                tid = t["id"]
                kind = t["check"]["kind"]
                log(f"    check {tid} [{kind}]")
                if kind == "stdout":
                    # Capturing output needs a terminal, and the bridge pump is
                    # not one - see the note in TaskRunner.HC. So these are typed
                    # into the guest's own shell, which is also how a player runs
                    # them. The event still comes back over the bridge.
                    guest.type_line(f'TaskCheck("{tid}");')
                else:
                    guest.send(f"CMD check_task id={tid}")
                ev = guest.wait_event("task_checked", args.check_timeout)
                if not ev:
                    results[tid] = {"error": "no task_checked reply"}
                    continue
                failed = int(ev["fields"].get("failed", -1))
                cases = int(ev["fields"].get("cases", -1))
                res = {"cases": cases, "failed": failed}
                if failed == 0:
                    done = guest.wait_event("task_done", 10)
                    res["task_done"] = bool(done)
                    if done:
                        res["sig"] = done["fields"].get("sig")
                        res["hinted"] = done["fields"].get("hinted")
                results[tid] = res
                log(f"      cases={cases} failed={failed}")
        finally:
            guest.stop()
        return results
    finally:
        if os.path.exists(work) and not args.keep_images:
            os.unlink(work)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--image", default=os.path.join(ROOT, "build", "temple_disk.raw"),
                    help="an installed raw image; it is copied, never modified")
    ap.add_argument("--task", help="check only this task id")
    ap.add_argument("--accel", default=_default_accel(),
                    help="tcg, kvm, whpx, hvf (default: whatever this host has)")
    ap.add_argument("--qmp-port", type=int, default=4460)
    ap.add_argument("--com-port", type=int, default=4570)
    ap.add_argument("--boot-timeout", type=float, default=240)
    ap.add_argument("--check-timeout", type=float, default=120)
    ap.add_argument("--keep-going", action="store_true",
                    help="run the solution pass even if the template pass is wrong")
    ap.add_argument("--keep-images", action="store_true",
                    help="leave the working copies behind for inspection")
    args = ap.parse_args()

    if not os.path.isfile(args.image):
        log(f"no image at {args.image}")
        log("Install one first: bash tools/run_qemu.sh --install --disk <path>")
        return 2

    tasks = load_tasks(args.task)
    if not tasks:
        log("no tasks to check")
        return 2
    log(f"{len(tasks)} task(s): {', '.join(t['id'] for t in tasks)}")

    templates = run_pass(args.image, tasks, "template", args)

    bad_negative = [t["id"] for t in tasks
                    if templates.get(t["id"], {}).get("failed", 0) == 0
                    or "error" in templates.get(t["id"], {})]
    if bad_negative and not args.keep_going:
        log("\nthe negative test did not hold, so the solution pass is pointless:")
        for tid in bad_negative:
            log(f"  {tid}: {templates.get(tid)}")
        return 1

    solutions = run_pass(args.image, tasks, "solution", args)

    log("\n=== summary ===")
    log(f"{'task':<20} {'template':<22} {'solution':<22} verdict")
    ok = True
    for t in tasks:
        tid = t["id"]
        tmpl = templates.get(tid, {})
        soln = solutions.get(tid, {})
        neg_ok = "error" not in tmpl and tmpl.get("failed", 0) > 0
        pos_ok = "error" not in soln and soln.get("failed", -1) == 0 and soln.get("task_done")
        good = neg_ok and pos_ok
        ok &= good
        tdesc = tmpl.get("error") or f"failed {tmpl.get('failed')}/{tmpl.get('cases')}"
        sdesc = soln.get("error") or f"failed {soln.get('failed')}/{soln.get('cases')}"
        if not soln.get("error") and soln.get("failed") == 0 and not soln.get("task_done"):
            sdesc += " but no task_done"
        log(f"{tid:<20} {tdesc:<22} {sdesc:<22} {'ok' if good else 'BAD'}")

    log("")
    log("all tasks behave" if ok else "SOME TASKS ARE WRONG")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
