#!/usr/bin/env python3
"""make_sounds.py - the machine's noises, made rather than found.

Every sample the launcher plays is generated here, from arithmetic, into
host/temple/audio. Nothing is downloaded and nothing is sampled, for two
reasons. The game is sold, and a clip off a sound library with unclear terms is
a liability that lands on whoever ships it - and the sounds this wants are the
easy ones to synthesise honestly. A key click, a mouse button, a transformer
humming and a PC speaker are all a handful of decaying sinusoids and some
filtered noise, which is what they physically are.

    python tools/make_sounds.py

HOW EACH ONE IS BUILT

A struck object rings at a few frequencies at once and each one dies away at
its own rate. That is the whole of modal synthesis, and it is what makes a
keyboard sound like a keyboard rather than like a beep: a sharp noisy transient
where the parts hit, a mid resonance from the keycap, and a lower one from the
plate underneath. Change the three frequencies a little and it is a different
key on the same board, which is why the key sounds come in six variants - a
single sample repeated at typing speed reads as a machine gun.

The PC speaker sounds are square waves, because a PC speaker is a coil pulled
to one of two positions and TempleOS drives it exactly that way
(Kernel/SerialDev/Snd.HC uses the 8254's channel 2 as a square wave gate).
Anything smoother would be a nicer sound and the wrong one.

The room tone is periodic on purpose: fifty hertz and its harmonics for the
transformer, a one-pole low pass over noise for the fan, and a very quiet line
at the flyback frequency of a 15.7kHz CRT. Its length is a whole number of
cycles of every one of those, so the loop point is silent - and the noise, which
has no period, is cross-faded across the seam.
"""

from __future__ import annotations

import argparse
import math
import os
import random
import struct
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "host", "temple", "audio")

RATE = 44100


def write_wav(name: str, samples: list[float], peak: float = 0.9) -> str:
    """One mono 16-bit file, normalised to a stated peak.

    Normalising rather than trusting the arithmetic keeps the mix predictable:
    every sample here is written to sit at a known loudness, and the balance
    between them is set once, in Sound.gd, in decibels.
    """
    hi = max(1e-9, max(abs(s) for s in samples))
    scale = peak / hi
    frames = bytearray()
    for s in samples:
        v = int(max(-1.0, min(1.0, s * scale)) * 32767)
        frames += struct.pack("<h", v)
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(bytes(frames))
    return path


def mode(buf: list[float], freq: float, decay: float, amp: float,
         start: int = 0) -> None:
    """One decaying sinusoid, added in place. A struck object is a few of these.

    decay is the time constant in seconds: the amplitude is down to a third of
    itself after that long, and inaudible after four of them.
    """
    phase = random.uniform(0, math.tau)
    w = math.tau * freq / RATE
    for i in range(start, len(buf)):
        t = (i - start) / RATE
        e = math.exp(-t / decay)
        if e < 1e-4:
            break
        buf[i] += amp * e * math.sin(w * (i - start) + phase)


def noise_burst(buf: list[float], decay: float, amp: float, cut: float,
                start: int = 0) -> None:
    """Filtered noise under an exponential envelope - the transient.

    One-pole low pass, which is the cheapest filter that still sounds like
    something rather than like static. cut is its corner in hertz.
    """
    a = math.exp(-math.tau * cut / RATE)
    y = 0.0
    for i in range(start, len(buf)):
        t = (i - start) / RATE
        e = math.exp(-t / decay)
        if e < 1e-4:
            break
        y = a * y + (1 - a) * random.uniform(-1, 1)
        buf[i] += amp * e * y


def silence(seconds: float) -> list[float]:
    return [0.0] * int(RATE * seconds)


# ---------------------------------------------------------------- keyboard

def key_down(seed: int) -> list[float]:
    """A key bottoming out on a board with a steel plate under it.

    Three things happen at once and this is all three: the click of the switch,
    the keycap ringing, and the plate. The seed moves the frequencies by a few
    percent so that six of these do not sound like one sample six times.
    """
    random.seed(seed)
    j = lambda f: f * random.uniform(0.93, 1.07)   # noqa: E731
    buf = silence(0.09)
    noise_burst(buf, 0.0025, 0.55, j(5200))        # the switch
    mode(buf, j(3400), 0.010, 0.30)                # the cap
    mode(buf, j(1250), 0.018, 0.22)
    mode(buf, j(185), 0.035, 0.30)                 # the plate
    return buf


def key_up(seed: int) -> list[float]:
    """The key coming back up: the same event, smaller and shorter."""
    random.seed(seed + 500)
    j = lambda f: f * random.uniform(0.93, 1.07)   # noqa: E731
    buf = silence(0.05)
    noise_burst(buf, 0.0015, 0.30, j(6000))
    mode(buf, j(2900), 0.007, 0.15)
    mode(buf, j(240), 0.014, 0.10)
    return buf


def key_space(seed: int) -> list[float]:
    """The space bar, which on any board is bigger and duller than the rest."""
    random.seed(seed + 900)
    buf = silence(0.11)
    noise_burst(buf, 0.0035, 0.45, 3800)
    mode(buf, 900, 0.020, 0.25)
    mode(buf, 120, 0.055, 0.45)
    return buf


# ------------------------------------------------------------------- mouse

def mouse_down() -> list[float]:
    """A microswitch. Shorter and higher than a key, and with no plate."""
    random.seed(11)
    buf = silence(0.04)
    noise_burst(buf, 0.0012, 0.5, 7000)
    mode(buf, 2300, 0.004, 0.45)
    mode(buf, 940, 0.008, 0.25)
    return buf


def mouse_up() -> list[float]:
    random.seed(12)
    buf = silence(0.03)
    noise_burst(buf, 0.0009, 0.32, 7500)
    mode(buf, 2600, 0.003, 0.28)
    return buf


# --------------------------------------------------------------- room tone

def room(seconds: float = 4.0) -> list[float]:
    """What a beige box on a desk sounds like when nothing is happening.

    Length chosen so the loop is seamless without a fade: 4 seconds is 200
    cycles of 50Hz, 800 of 200Hz and 62500 of 15625Hz, so every periodic part
    ends exactly where it started. The fan has no period, so its two ends are
    cross-faded into each other across a tenth of a second.
    """
    random.seed(7)
    n = int(RATE * seconds)
    buf = [0.0] * n

    # The transformer. Mains at fifty, and the harmonics a laminated core adds.
    for f, a in ((50, 0.55), (100, 0.30), (150, 0.16), (200, 0.09), (300, 0.04)):
        w = math.tau * f / RATE
        for i in range(n):
            buf[i] += a * math.sin(w * i)

    # The fan: noise through two one-pole low passes, which rolls off fast
    # enough to sound like moving air rather than like hiss.
    a1 = math.exp(-math.tau * 700 / RATE)
    a2 = math.exp(-math.tau * 260 / RATE)
    seam = int(RATE * 0.1)
    y1 = y2 = 0.0
    raw = [0.0] * (n + seam)
    for i in range(n + seam):
        y1 = a1 * y1 + (1 - a1) * random.uniform(-1, 1)
        y2 = a2 * y2 + (1 - a2) * y1
        raw[i] = y2
    # Fold the tail back over the head, which is the way round that works.
    # Noise has no period, so the only way the end can meet the beginning is if
    # the beginning already contains the end: generate a seam's worth extra and
    # cross-fade raw[n+i] into raw[i]. Then the last written sample is followed,
    # on the loop, by what genuinely came after it. Doing it the other way -
    # blending the end into the start in place - leaves the actual final sample
    # untouched and the seam audible, which is what the first version did.
    fan = [0.0] * n
    for i in range(n):
        if i < seam:
            k = i / seam
            fan[i] = raw[i] * k + raw[n + i] * (1 - k)
        else:
            fan[i] = raw[i]
    peak = max(abs(v) for v in fan) or 1.0
    for i in range(n):
        buf[i] += 1.5 * fan[i] / peak

    # The flyback line of a 15.7kHz CRT. Very quiet: half the people who can
    # hear it at all only notice it when it stops.
    w = math.tau * 15625 / RATE
    for i in range(n):
        buf[i] += 0.05 * math.sin(w * i)
    return buf


# ------------------------------------------------------- the PC speaker

def square(buf: list[float], freq: float, start: float, dur: float,
           amp: float = 1.0, duty: float = 0.5) -> None:
    """A gated square wave, which is the only shape a PC speaker makes."""
    a = int(start * RATE)
    b = min(len(buf), a + int(dur * RATE))
    period = RATE / freq
    for i in range(a, b):
        # A couple of milliseconds of taper at each end. A hard gate on a
        # square wave is a click of its own, and two clicks per note is what
        # makes naive beeps sound broken rather than old.
        t = (i - a) / RATE
        left = min(1.0, t / 0.003)
        right = min(1.0, (dur - t) / 0.003)
        env = max(0.0, min(left, right))
        buf[i] += amp * env * (1.0 if (i % period) < period * duty else -1.0)


def boot_beep() -> list[float]:
    """One note, the length a POST beep is. Played when the guest first speaks."""
    buf = silence(0.30)
    square(buf, 880, 0.0, 0.22, 0.8)
    return buf


def task_passed() -> list[float]:
    """Three notes up. Not a fanfare - the machine is not excited, it agrees."""
    buf = silence(0.55)
    square(buf, 523.25, 0.00, 0.10, 0.7)   # C5
    square(buf, 659.25, 0.11, 0.10, 0.7)   # E5
    square(buf, 783.99, 0.22, 0.22, 0.7)   # G5
    return buf


def task_failed() -> list[float]:
    """Two notes down, and no lower than a person can hear comfortably."""
    buf = silence(0.42)
    square(buf, 311.13, 0.00, 0.12, 0.6)   # Eb4
    square(buf, 233.08, 0.13, 0.24, 0.6)   # Bb3
    return buf


def error_thud() -> list[float]:
    """What a compiler message sounds like. Short, low, and not a punishment."""
    buf = silence(0.22)
    square(buf, 146.83, 0.0, 0.09, 0.5, duty=0.25)
    mode(buf, 92, 0.06, 0.5)
    return buf


def ui_click() -> list[float]:
    """A button in the panel. Quieter than the guest's own mouse."""
    random.seed(31)
    buf = silence(0.03)
    noise_burst(buf, 0.0010, 0.35, 6500)
    mode(buf, 1800, 0.004, 0.30)
    return buf


def main() -> int:
    global OUT
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()
    OUT = args.out
    os.makedirs(OUT, exist_ok=True)

    made = []
    for i in range(6):
        made.append(write_wav("key_%d.wav" % i, key_down(i), 0.85))
        made.append(write_wav("key_up_%d.wav" % i, key_up(i), 0.55))
    made.append(write_wav("key_space.wav", key_space(0), 0.9))
    made.append(write_wav("mouse_down.wav", mouse_down(), 0.8))
    made.append(write_wav("mouse_up.wav", mouse_up(), 0.5))
    made.append(write_wav("ui_click.wav", ui_click(), 0.6))
    made.append(write_wav("room.wav", room(), 0.7))
    made.append(write_wav("boot.wav", boot_beep(), 0.8))
    made.append(write_wav("passed.wav", task_passed(), 0.8))
    made.append(write_wav("failed.wav", task_failed(), 0.7))
    made.append(write_wav("error.wav", error_thud(), 0.7))

    total = sum(os.path.getsize(p) for p in made)
    print("%d files, %.0f KB, in %s" % (len(made), total / 1024.0, OUT))
    for p in sorted(made):
        n = os.path.getsize(p)
        print("  %-18s %6.1f KB  %5.0f ms"
              % (os.path.basename(p), n / 1024.0, (n - 44) / 2.0 / RATE * 1000))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
