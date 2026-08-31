#!/usr/bin/env python3
"""make_textures.py - the room's surfaces, generated rather than found.

Same reasoning as tools/make_sounds.py: this is sold, a texture off an asset
site with terms nobody read is a liability that lands on whoever ships it, and
these particular surfaces are ones arithmetic is good at. Plaster, carpet, wood
and beige computer plastic are all noise with a bias.

    python tools/make_textures.py

WHY THEY LOOK LIKE THAT

The console this is imitating had a quarter of a megabyte for textures and no
floating point in its rasteriser, so everything on it was small, palettised and
dithered. All three are done here rather than in the shader:

  small        128 pixels square, and stretched over a whole wall. The blur of
               a texture used far past its resolution is half the look.
  palettised   quantised to sixteen colours chosen from the image itself. A
               gradient in sixteen steps bands, and banding is the other half.
  dithered     ordered, 4x4, applied before quantising, so the bands break up
               into the cross-hatch that console did rather than into stripes.

The rest of it - the texture swimming on a big polygon, the vertices wobbling as
the camera moves - is in the shader, because it is a property of how the
triangle is drawn and not of the picture on it.
"""

from __future__ import annotations

import argparse
import math
import os
import random

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "host", "temple", "textures")

SIZE = 128

# The 4x4 ordered matrix. Values 0..15, used as a fraction of one quantisation
# step, so a colour halfway between two levels lands on a checker of both.
BAYER = [
    [0, 8, 2, 10],
    [12, 4, 14, 6],
    [3, 11, 1, 9],
    [15, 7, 13, 5],
]


def value_noise(w: int, h: int, cells: int, seed: int) -> list[list[float]]:
    """Smooth noise on a grid, wrapping at the edges so the texture tiles."""
    rnd = random.Random(seed)
    g = [[rnd.random() for _ in range(cells)] for _ in range(cells)]

    def at(x: int, y: int) -> float:
        return g[y % cells][x % cells]

    out = [[0.0] * w for _ in range(h)]
    for y in range(h):
        fy = y * cells / h
        y0 = int(fy)
        ty = fy - y0
        ty = ty * ty * (3 - 2 * ty)
        for x in range(w):
            fx = x * cells / w
            x0 = int(fx)
            tx = fx - x0
            tx = tx * tx * (3 - 2 * tx)
            a = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
            b = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
            out[y][x] = a * (1 - ty) + b * ty
    return out


def fbm(w: int, h: int, seed: int, octaves: int = 4, base: int = 4):
    """Several octaves of value noise, each finer and quieter than the last."""
    out = [[0.0] * w for _ in range(h)]
    amp, total = 1.0, 0.0
    for o in range(octaves):
        n = value_noise(w, h, base * (2 ** o), seed + o * 977)
        for y in range(h):
            row = out[y]
            src = n[y]
            for x in range(w):
                row[x] += src[x] * amp
        total += amp
        amp *= 0.5
    for y in range(h):
        for x in range(w):
            out[y][x] /= total
    return out


def dither_quantise(im: Image.Image, colours: int = 16) -> Image.Image:
    """Ordered dither, then a palette of `colours` taken from the image.

    In that order. Dithering after quantising only stipples between palette
    entries; dithering before it is what makes the quantiser choose the
    checkerboard, which is what the hardware did.
    """
    px = im.load()
    w, h = im.size
    step = 256.0 / colours
    for y in range(h):
        for x in range(w):
            bump = (BAYER[y & 3][x & 3] / 16.0 - 0.5) * step
            r, g, b = px[x, y]
            px[x, y] = (
                max(0, min(255, int(r + bump))),
                max(0, min(255, int(g + bump))),
                max(0, min(255, int(b + bump))),
            )
    return im.quantize(colors=colours, method=Image.MEDIANCUT).convert("RGB")


def shade(base: tuple[int, int, int], amount: float, t: float) -> tuple[int, int, int]:
    """base, darkened or lightened by t in [0,1] scaled by amount."""
    k = 1.0 + (t - 0.5) * 2.0 * amount
    return tuple(max(0, min(255, int(c * k))) for c in base)


# ------------------------------------------------------------------ surfaces

def plaster(base, seed, amount=0.14):
    n = fbm(SIZE, SIZE, seed, octaves=4, base=3)
    im = Image.new("RGB", (SIZE, SIZE))
    px = im.load()
    for y in range(SIZE):
        for x in range(SIZE):
            px[x, y] = shade(base, amount, n[y][x])
    return im


def carpet(base, seed):
    """Noise with a short-range twist, which is what a loop pile looks like."""
    n = fbm(SIZE, SIZE, seed, octaves=3, base=8)
    fine = fbm(SIZE, SIZE, seed + 31, octaves=2, base=32)
    im = Image.new("RGB", (SIZE, SIZE))
    px = im.load()
    for y in range(SIZE):
        for x in range(SIZE):
            t = 0.65 * n[y][x] + 0.35 * fine[y][x]
            px[x, y] = shade(base, 0.22, t)
    return im


def wood(base, seed):
    """Rings, bent by noise, with a darker line where each ring closes."""
    n = fbm(SIZE, SIZE, seed, octaves=3, base=3)
    grain = fbm(SIZE, SIZE, seed + 7, octaves=2, base=24)
    im = Image.new("RGB", (SIZE, SIZE))
    px = im.load()
    for y in range(SIZE):
        for x in range(SIZE):
            # Bands across the plank, wandering with the noise.
            v = (y / SIZE) * 7.0 + n[y][x] * 2.6
            ring = 0.5 + 0.5 * math.sin(v * math.tau)
            ring = ring ** 2.2                      # sharpen the dark line
            t = 0.55 + 0.30 * ring + 0.15 * grain[y][x]
            px[x, y] = shade(base, 0.30, t)
    return im


def plastic(base, seed):
    """Injection-moulded beige: almost flat, with the faintest orange peel."""
    n = fbm(SIZE, SIZE, seed, octaves=2, base=20)
    im = Image.new("RGB", (SIZE, SIZE))
    px = im.load()
    for y in range(SIZE):
        for x in range(SIZE):
            px[x, y] = shade(base, 0.07, n[y][x])
    return im


def fabric(base, seed):
    """A weave: two sets of threads crossing, one lit and one in shadow."""
    n = fbm(SIZE, SIZE, seed, octaves=2, base=16)
    im = Image.new("RGB", (SIZE, SIZE))
    px = im.load()
    for y in range(SIZE):
        for x in range(SIZE):
            warp = 0.5 + 0.5 * math.sin(x * math.tau / 4.0)
            weft = 0.5 + 0.5 * math.sin(y * math.tau / 4.0)
            over = warp if ((x // 4 + y // 4) & 1) else weft
            t = 0.45 + 0.35 * over + 0.20 * n[y][x]
            px[x, y] = shade(base, 0.26, t)
    return im


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()
    out_dir = args.out
    os.makedirs(out_dir, exist_ok=True)

    made = {
        "wall": plaster((128, 122, 110), 11),
        "ceiling": plaster((140, 136, 128), 23, amount=0.10),
        "floor": carpet((74, 66, 58), 37),
        "desk": wood((150, 108, 66), 53),
        "plastic": plastic((208, 200, 176), 71),
        "chair": fabric((78, 76, 84), 89),
        "case": plastic((196, 190, 168), 103),
    }
    for name, im in made.items():
        im = dither_quantise(im, 16)
        path = os.path.join(out_dir, name + ".png")
        im.save(path)
        print("  %-10s %s  %d bytes" % (name, im.size, os.path.getsize(path)))
    print("%d textures in %s" % (len(made), out_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
