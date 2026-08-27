#!/usr/bin/env python3
"""
extract_font.py - pull TempleOS's 8x8 system font out of the OS source.

The launcher's panel sits an inch away from a real 640x480 TempleOS screen, so
it has to be lettered in the same hand. That font is not a file anyone can
copy: it is 256 U64 literals compiled into the kernel, at
vendor/TempleOS/Kernel/FontStd.HC:3 (`U64 sys_font_std[256]= {`). This reads
them and writes out the same 2048 bytes TempleOS itself dumps with
FileWrite("filename.BIN.Z",text.font,256*FONT_HEIGHT)
(vendor/TempleOS/Demo/Graphics/FontEd.HC:4), plus a PNG atlas and a BMFont
descriptor that Godot imports as a Font resource.

Nothing here is transcribed by hand. Re-pin the vendor tree and run it again.

THE FORMAT
    One U64 per glyph, indexed by the raw 8-bit character code with no
    translation table anywhere in between - the renderer loads the glyph with
    `MOV RAX,U64 [RDX+RAX*8]` where RAX is the low byte of the text cell
    (vendor/TempleOS/Adam/Gr/GrAsm.HC:279-281).

    Byte 0 of the U64 is the TOP scanline, byte 7 the bottom; the renderer
    shifts right by 8 once per row. Within a byte, bit 0 - the LSB - is the
    LEFTMOST pixel. That is backwards from most bitmap fonts and it is the one
    thing worth getting right.

    The proof is vendor/TempleOS/Adam/Gr/GrInitB.HC:10-15, which builds the
    expansion table `gr.to_8_bits` so that output byte j of an 8-pixel run is
    set iff bit j of the source byte is set, with the destination walking left
    to right. The cheap check, which this tool runs on every invocation, is
    the letter F: its stem rows put ink in one nibble only, and it has to be
    the low nibble, or F comes out mirrored.

    1 is ink, 0 is paper. No antialiasing, no kerning, no proportional
    metrics - every cell is 8x8 and every advance is 8, because the screen is
    a fixed 80x60 grid of them (vendor/TempleOS/Kernel/KernelA.HH:3551-3556,
    vendor/TempleOS/Kernel/KMain.HC:78-79).

THE CHARACTER SET, AND HOW IT IS MAPPED FOR GODOT
    TempleOS indexes glyphs by byte. Godot indexes them by Unicode codepoint.
    The two do not line up, so every glyph is emitted into the .fnt under a
    private-use alias, and most of them under a second, natural id as well:

      0x00 - 0x1F   NOT control characters. 0x02-0x0D are the window-frame
                    glyphs the graphics-mode chrome is drawn from
                    (vendor/TempleOS/Kernel/KMain.HC:84-85 loads them into
                    text.border_chars as 0x0908070605040302 / 0x0D0C0B0A);
                    0x1F is SHIFT-SPACE, a single dot. The rest are blank.
                    No natural codepoint - see below.
      0x20 - 0x7E   ASCII, conventional shapes. Mapped to themselves.
      0x7F          a solid 8x8 block, not DEL. No natural codepoint.
      0x80 - 0xFF   CP437: accented Latin, the three shade patterns, the
                    single and double box-drawing sets, a Greek/maths tail.
                    Mapped through Python's 'cp437' codec.
      all 256       also mapped to U+E000 + code, in the private use area, so
                    any glyph can be addressed by its TempleOS code even when
                    it has no natural home.

    The 12 frame glyphs are not new artwork - they are byte-for-byte the CP437
    line-draw glyphs (0x02 == 0xC4, 0x03 == 0xCD, 0x04 == 0xB3, 0x05 == 0xBA,
    and so on through the four corners in both weights). This tool asserts
    that equality rather than assuming it, so the frame is reachable at
    U+2500 and its neighbours as well as at U+E002.

WHAT A GODOT LABEL CAN AND CANNOT SHOW
    Can:  everything in 0x20-0x7E as ordinary text; the whole CP437 upper half
          under its Unicode name, so "\\u2500" is the horizontal rule,
          "\\u2588" the solid block, "\\u00e9" e-acute; and every one of the
          256 by alias, "\\ue000" with the code added on.
    Cannot: the C0 codepoints U+0000-U+001F, and U+007F. Those are control
          characters to the text server, which spends them on line breaking
          and layout before a font is ever consulted, so "\\u0002" in a Label
          draws nothing at all. Write "\\ue002" instead, or write "\\u2500"
          and get the identical bitmap under its CP437 name.
    Also worth knowing: TempleOS made 0xFF a solid block where CP437 has a
    non-breaking space, so U+00A0 in a Label draws as a filled cell. That is
    faithful to the font, and surprising the first time.

    Separately, and not this tool's problem but the reason the aliases are
    worth having: inside TempleOS itself DolDoc cannot print 0x00-0x1E or 0x7F
    either - vendor/TempleOS/Adam/DolDoc/DocRecalc.HC:696 rewrites anything
    outside char_bmp_displayable to '.'. Only the text-base layer places frame
    glyphs. Both renderers have the same hole in the same place.

THE SECOND FONT, AND WHY THE CAMPAIGN NEEDS IT
    The kernel carries two fonts, not one. Kernel/KMain.HC:67-68 loads both -
    `text.font=sys_font_std; text.aux_font=sys_font_cyrillic;` - and
    Kernel/KeyDev.HC:148-151 swaps them on CTRL-ALT-F. The second is
    Kernel/FontCyrillic.HC, in exactly the same format, and it is how this
    operating system displays Russian. The campaign panel is bilingual, so it
    is how the launcher displays Russian too.

    The two fonts are byte-identical for codes 0x00-0x9F and 0xFF and differ
    at every one of 0xA0-0xFE - checked here on every run. That is what makes
    the swap safe: the window-frame glyphs 0x02-0x0D and the whole of ASCII
    survive it, and only the CP437 upper half is spent on Cyrillic.

    The mapping is not a standard encoding, and nothing in the source states
    it. It was read off the bitmaps and then read back again by rendering the
    campaign's own Russian text (see the run-order assertion in self_check,
    which would catch a table shifted by one). Two things about it are worth
    knowing before touching CYRILLIC_RUNS:

      - Only the letters whose shape is not already in ASCII got a glyph. A
        is A, K is K, o is o, and Ь is drawn by lowercase b, whose ascender
        and low bowl are exactly its shape. Nineteen of the sixty-six letters
        are ASCII reuses, which is the convention of the character-LCD ROMs
        this table came from.
      - The letters that hang below the baseline - Д Ц Щ д ф ц щ - are not in
        alphabetical position. They sit together at 0xE0-0xE6, out of the two
        runs, because they are the ones that need all eight rows.

    PROVENANCE, which somebody has to decide about before this ships:
    Doc/Credits.DD:7 says the Cyrillic font "is taken from OrientDisplay ...
    without permission" - it is the one part of TempleOS Terry did not put in
    the public domain, because it was not his to put there. It is in the
    vendor tree already; this tool only re-shapes it. Whether it can go into
    a sold build is a question for a person, not for a font tool.

    It also looks like what it is. The Cyrillic glyphs are single-pixel
    strokes five columns wide; Terry's own Latin letters are two-pixel strokes
    six or seven columns wide. So Russian comes out visibly lighter than
    English, and a word like "Простое" mixes the two weights, because о, р, с
    and т are ASCII reuses and П and е are not. That is not an artefact of
    this tool - it is what a TempleOS screen does after CTRL-ALT-F.

OUTPUT (into host/temple/theme by default)
    font_std.bin   the raw 2048 bytes, 8 per glyph, in the kernel's own
                   layout. For a future renderer that wants to blit cells
                   itself instead of going through Godot's text stack.
    font_std.png   128x128 RGBA atlas, 16x16 grid of 8x8 cells, glyph code N
                   at column N%16 row N/16. White, with the shape in alpha.
    font_std.fnt   BMFont descriptor pointing at the atlas. Godot 4 imports
                   this as a FontFile; ask for it at font_size 8, 16, 24 ...
                   and keep the canvas texture filter on Nearest, or the whole
                   point of the exercise is lost.
    font_std.fnt.import
                   Godot writes this itself, but its default scaling_mode is
                   fractional, so the pin to integer-only is set here as well.
                   It also carries the fallback to the aux font, which is what
                   makes a Label with Russian in it work without any control
                   having to know which font a character came from. An
                   existing file is patched a line at a time rather than
                   replaced, because the uid Godot minted in it is what other
                   resources reference the font by.
    font_cyrillic.bin / .png / .fnt / .fnt.import
                   the same four files for the aux font. Its atlas holds all
                   256 glyphs, because that is what the kernel holds, but its
                   descriptor names only the 95 codes that differ from the std
                   font: the other 161 are the std font, already reachable
                   there, and a second copy of them in the fallback chain
                   would only be a second place for them to drift.

    Godot marks font_std.png as importer="skip" on its own once the .fnt
    claims it as a page - the atlas is embedded in the imported font, so there
    is no second copy of it to keep in step.

USAGE
    python tools/extract_font.py                        # both fonts
    python tools/extract_font.py --out host/temple/theme
    python tools/extract_font.py --dump 41 67 30 DA     # ASCII art, to look
    python tools/extract_font.py --font aux --dump A0 B2 E0
    python tools/extract_font.py --check-render build/font_check.png

    --check-render takes a PNG that Godot rendered from the .fnt, plus the
    <png>.txt sidecar naming which glyph landed where, and compares every
    pixel against the bits in the source. See host/temple/theme/font_check.gd
    for the std font and host/temple/theme/cyrillic_check.gd for the aux one;
    both name the font they rendered with --font.
"""

from __future__ import annotations

import argparse
import os
import re
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DEFAULT_SRC = os.path.join(ROOT, "vendor", "TempleOS", "Kernel", "FontStd.HC")
DEFAULT_AUX = os.path.join(ROOT, "vendor", "TempleOS", "Kernel", "FontCyrillic.HC")
DEFAULT_OUT = os.path.join(ROOT, "host", "temple", "theme")

GLYPHS = 256
CELL = 8          # FONT_WIDTH == FONT_HEIGHT == 8, KernelA.HH:3551-3552
COLS = 16         # atlas is square: 16 x 16 cells of 8x8 -> 128 x 128
PUA = 0xE000      # private use area base for the by-code aliases

# The aux font's own range. Everything below 0xA0, and 0xFF, is the std font.
AUX_FIRST, AUX_LAST = 0xA0, 0xFE

# text.border_chars in graphics mode (Kernel/KMain.HC:84-85) against the CP437
# codes the same file uses in text mode (:75-76). The bitmaps have to be equal
# or the frame would not survive a mode switch, and we check that they are.
BORDER_PAIRS = [
    (0x02, 0xC4),  # horizontal, single
    (0x03, 0xCD),  # horizontal, double
    (0x04, 0xB3),  # vertical, single
    (0x05, 0xBA),  # vertical, double
    (0x06, 0xDA),  # top left, single
    (0x07, 0xC9),  # top left, double
    (0x08, 0xBF),  # top right, single
    (0x09, 0xBB),  # top right, double
    (0x0A, 0xC0),  # bottom left, single
    (0x0B, 0xC8),  # bottom left, double
    (0x0C, 0xD9),  # bottom right, single
    (0x0D, 0xBC),  # bottom right, double
]

# The Russian alphabet, in its own order, which is the order the aux font's
# two long runs are laid out in.
ALPHABET = ("АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
            "абвгдеёжзийклмнопрстуфхцчшщъыьэюя")

# Where each letter lives in FontCyrillic.HC. Four runs of consecutive codes,
# each ascending through the alphabet: two for the letters that fit in seven
# rows, two more at 0xE0 for the ones that hang below the baseline and need
# all eight. self_check re-derives the ordering rather than trusting this.
CYRILLIC_RUNS = [
    (0xA0, "БГЁЖЗИЙЛПУФЧШЪЫЭЮЯ"),
    (0xB2, "бвгёжзийклмнптчшъыьэюя"),
    (0xE0, "ДЦЩ"),
    (0xE3, "дфцщ"),
]

# The nineteen letters the font does not draw, because ASCII already does.
# Ь is the interesting one: lowercase b is an ascender over a low bowl, which
# is its shape exactly. The rest are the letters Cyrillic and Latin share.
CYRILLIC_REUSED = {
    "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O",
    "Р": "P", "С": "C", "Т": "T", "Х": "X", "Ь": "b",
    "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x",
}


# ------------------------------------------------------------------ the font

def parse_font(path: str) -> bytes:
    """Read FontStd.HC and return the kernel's own 2048 bytes."""
    # latin-1, never utf-8: every line carries a trailing comment showing the
    # two glyphs on it, written as raw CP437 bytes, and utf-8 chokes on them.
    with open(path, "rb") as fh:
        text = fh.read().decode("latin-1")

    try:
        body = text.split("{", 1)[1].rsplit("}", 1)[0]
    except IndexError:
        raise SystemExit("%s: no braced array body found" % path)

    # The only 16-hex-digit literals in the file are the glyphs. Splitting on
    # commas would be worse - the comments contain high-bit bytes and commas.
    values = [int(v, 16) for v in re.findall(r"0x([0-9A-Fa-f]{16})", body)]
    if len(values) != GLYPHS:
        raise SystemExit(
            "%s: found %d U64 literals, expected %d. The vendor tree may have "
            "been re-exported with different formatting; the parser needs "
            "revisiting." % (path, len(values), GLYPHS))

    data = b"".join(struct.pack("<Q", v) for v in values)
    assert len(data) == GLYPHS * CELL
    return data


def rows(data: bytes, code: int) -> list[int]:
    return list(data[code * CELL:(code + 1) * CELL])


def art(data: bytes, code: int) -> list[str]:
    """ASCII art of one glyph, LSB first so column 0 is the leftmost pixel."""
    out = []
    for r in rows(data, code):
        out.append("".join("#" if (r >> c) & 1 else "." for c in range(CELL)))
    return out


def self_check(data: bytes) -> None:
    """Assertions that would fire if the format ever drifted under us."""
    # Bit order. 'F' has a full top bar and a stem hugging one edge; the stem
    # rows set bits in a single nibble. Under LSB-is-leftmost that nibble is
    # the low one. If this ever fails, every glyph in the atlas is mirrored.
    stem = rows(data, ord("F"))[1]
    if not (stem & 0x0F) or (stem & 0xF0):
        raise SystemExit(
            "bit-order check failed: row 1 of 'F' is 0x%02X, which does not "
            "put the stem in the low nibble. Either the font changed or LSB is "
            "no longer the leftmost pixel (GrInitB.HC:10-15)." % stem)

    # The graphics-mode frame glyphs against their CP437 twins.
    for lo, cp437 in BORDER_PAIRS:
        a = data[lo * CELL:(lo + 1) * CELL]
        b = data[cp437 * CELL:(cp437 + 1) * CELL]
        if a != b:
            raise SystemExit(
                "frame glyph 0x%02X is no longer byte-identical to CP437 "
                "0x%02X; the box-drawing mapping is wrong." % (lo, cp437))


def cyrillic_map() -> dict[str, int]:
    """Every Russian letter to the code that draws it, aux font or ASCII."""
    letters: dict[str, int] = {}
    for first, run in CYRILLIC_RUNS:
        for i, ch in enumerate(run):
            letters[ch] = first + i
    for ch, ascii_ch in CYRILLIC_REUSED.items():
        letters[ch] = ord(ascii_ch)
    return letters


def aux_check(aux: bytes, std: bytes) -> None:
    """Assertions for the second font. See the docstring for what they buy."""
    # What the CTRL-ALT-F swap does and does not disturb. The frame glyphs and
    # the whole of ASCII have to survive it, and the Cyrillic has to be
    # somewhere - a font that differed nowhere would be the std font under
    # another name, which is how a bad --src would show up.
    changed = [c for c in range(GLYPHS)
               if aux[c * CELL:(c + 1) * CELL] != std[c * CELL:(c + 1) * CELL]]
    want = list(range(AUX_FIRST, AUX_LAST + 1))
    if changed != want:
        raise SystemExit(
            "the aux font differs from the std font at %d code(s) (%s...), "
            "not at exactly 0x%02X-0x%02X. Either the fonts moved under us or "
            "--src and --aux are the wrong way round."
            % (len(changed), " ".join("%02X" % c for c in changed[:8]),
               AUX_FIRST, AUX_LAST))

    letters = cyrillic_map()
    missing = [ch for ch in ALPHABET if ch not in letters]
    if missing:
        raise SystemExit("no glyph for %s" % " ".join(missing))

    for ch, code in sorted(letters.items(), key=lambda kv: kv[1]):
        if aux[code * CELL:(code + 1) * CELL] == b"\x00" * CELL:
            raise SystemExit(
                "%s is mapped to 0x%02X, which is blank" % (ch, code))
        if code < 0x80 and ch not in CYRILLIC_REUSED:
            raise SystemExit(
                "%s is mapped into ASCII at 0x%02X but is not listed as a "
                "reuse" % (ch, code))

    # The structural check, and the one that would catch a table read off the
    # bitmaps one position out: within each run of consecutive codes the
    # letters have to climb the alphabet. Getting one wrong shifts every
    # letter after it, and a shifted run cannot stay in order.
    for first, run in CYRILLIC_RUNS:
        order = [ALPHABET.index(ch) for ch in run]
        if order != sorted(order):
            raise SystemExit(
                "the run at 0x%02X is not in alphabetical order: %s"
                % (first, run))
        if not (AUX_FIRST <= first and first + len(run) - 1 <= AUX_LAST):
            raise SystemExit(
                "the run at 0x%02X (%d letters) leaves the aux font's own "
                "range" % (first, len(run)))


# --------------------------------------------------------------- the mapping

def underlined(data: bytes) -> bytes:
    """The same font with every glyph's last scanline filled.

    This is how TempleOS underlines, and it is worth being precise about
    because the obvious alternative is wrong. The blitter does it inside the
    glyph, not under it:

        BT      U64 SF_ARG1[RBP],ATTRf_UNDERLINE
        JNC     @@05
        MOV     RBX,0xFF00000000000000
        OR      RAX,RBX
        vendor/TempleOS/Adam/Gr/GrAsm.HC:282-285

    RAX holds the eight scanline bytes with byte 0 at the top, so the high byte
    is row 7 - the bottom row of the 8x8 cell. The line lands on the character's
    own last row and the cell below is untouched.

    A text renderer that draws its own underline cannot reach that row: it
    measures from the baseline, which here sits at the bottom of the cell, and
    an underline at or below the baseline falls into the next row. Godot also
    clamps a negative underline position to zero, so asking for one row up is
    silently ignored, and what gets drawn is a half-covered line across the
    boundary in a blended colour this palette does not contain. Baking it into
    the glyphs sidesteps all of that: an underlined run is just a different
    font, drawn the same way as any other, one colour, on the grid.
    """
    out = bytearray(data)
    for code in range(256):
        out[code * CELL + CELL - 1] = 0xFF
    return bytes(out)


def natural_codepoint(code: int) -> int | None:
    """The Unicode codepoint a glyph would normally be written as, if any."""
    if 0x20 <= code <= 0x7E:
        return code
    if code >= 0x80:
        return ord(bytes([code]).decode("cp437"))
    # 0x00-0x1F are frame glyphs and blanks, 0x7F is a solid block. None of
    # them mean what the matching C0 control means, so they get no natural id.
    return None


def build_aux_ids() -> list[tuple[int, int]]:
    """The same, for the aux font: Cyrillic plus aliases for what it changes.

    All sixty-six letters get an id here, the nineteen ASCII reuses included,
    even though those nineteen cells are the std font's own bitmaps. They have
    to be: Cyrillic А is U+0410 and Latin A is U+0041, and a fallback chain
    matches on the codepoint, not on the shape. Leaving them out means the
    text server finds no font in the chain that draws U+0410 and the player
    gets an empty box for every А, В, Е, К, М, Н, О, Р, С, Т, Х and Ь - which
    is exactly what happened the first time this was tried.

    What is deliberately not here is Latin. This font is only ever reached as
    a fallback, and one that also carried the Latin alphabet would be a
    second, thinner set of letters standing one text server decision away from
    being used for English.
    """
    ids: dict[int, int] = {}
    for code in range(AUX_FIRST, AUX_LAST + 1):
        ids[PUA + code] = code
    for ch, code in cyrillic_map().items():
        ids[ord(ch)] = code
    return sorted(ids.items())


def build_ids(data: bytes) -> list[tuple[int, int]]:
    """(codepoint, templeos_code) pairs for the .fnt, sorted by codepoint."""
    ids: dict[int, int] = {}
    for code in range(GLYPHS):
        ids[PUA + code] = code
    for code in range(GLYPHS):
        cp = natural_codepoint(code)
        if cp is None:
            continue
        if cp < 0x80 and code >= 0x80:
            raise SystemExit(
                "cp437 mapped 0x%02X down into ASCII (U+%04X); the two halves "
                "of the id space overlap and one glyph would shadow the "
                "other." % (code, cp))
        if cp in ids and ids[cp] != code:
            # Two codes wanting the same codepoint is only harmless when the
            # bitmaps agree, which is the 0x7F/0xDB/0xFF solid-block case.
            other = ids[cp]
            if data[code * CELL:(code + 1) * CELL] != \
               data[other * CELL:(other + 1) * CELL]:
                raise SystemExit(
                    "U+%04X is claimed by both 0x%02X and 0x%02X with "
                    "different bitmaps" % (cp, other, code))
        ids[cp] = code
    return sorted(ids.items())


# ------------------------------------------------------------------- the PNG

def png_write(path: str, width: int, height: int, rgba: bytes) -> None:
    """8-bit RGBA PNG, unfiltered. Hand-rolled to keep this dependency-free."""
    stride = width * 4
    raw = b"".join(b"\x00" + rgba[y * stride:(y + 1) * stride]
                   for y in range(height))

    def chunk(tag: bytes, payload: bytes) -> bytes:
        body = tag + payload
        return (struct.pack(">I", len(payload)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(raw, 9))
    out += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(out)


def png_read(path: str) -> tuple[int, int, bytes]:
    """Read back an 8-bit PNG as (width, height, RGBA bytes).

    Only what Godot's Image.save_png emits: 8 bits per channel, greyscale,
    greyscale+alpha, RGB or RGBA, not interlaced.
    """
    with open(path, "rb") as fh:
        blob = fh.read()
    if blob[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("%s: not a PNG" % path)

    pos = 8
    width = height = ctype = 0
    idat = b""
    while pos + 8 <= len(blob):
        (length,) = struct.unpack_from(">I", blob, pos)
        tag = blob[pos + 4:pos + 8]
        payload = blob[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, depth, ctype, _comp, _filt, interlace = \
                struct.unpack(">IIBBBBB", payload)
            if depth != 8 or interlace:
                raise SystemExit("%s: only 8-bit non-interlaced PNGs" % path)
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            break

    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(ctype)
    if channels is None:
        raise SystemExit("%s: unsupported colour type %d" % (path, ctype))

    raw = zlib.decompress(idat)
    stride = width * channels
    lines: list[bytearray] = []
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        filt = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if filt == 1:
                line[i] = (line[i] + a) & 0xFF
            elif filt == 2:
                line[i] = (line[i] + b) & 0xFF
            elif filt == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
            elif filt != 0:
                raise SystemExit("%s: unknown row filter %d" % (path, filt))
        lines.append(line)
        prev = line

    rgba = bytearray(width * height * 4)
    for y, line in enumerate(lines):
        for x in range(width):
            s = line[x * channels:(x + 1) * channels]
            if channels == 1:
                px = (s[0], s[0], s[0], 255)
            elif channels == 2:
                px = (s[0], s[0], s[0], s[1])
            elif channels == 3:
                px = (s[0], s[1], s[2], 255)
            else:
                px = (s[0], s[1], s[2], s[3])
            rgba[(y * width + x) * 4:(y * width + x) * 4 + 4] = bytes(px)
    return width, height, bytes(rgba)


def build_atlas(data: bytes) -> tuple[int, int, bytes]:
    rows_n = (GLYPHS + COLS - 1) // COLS
    width, height = COLS * CELL, rows_n * CELL
    # White everywhere, shape in alpha. Keeping RGB white in the transparent
    # cells too means a stray filtered sample fades to clear, not to black.
    rgba = bytearray(b"\xFF\xFF\xFF\x00" * (width * height))
    for code in range(GLYPHS):
        gx = (code % COLS) * CELL
        gy = (code // COLS) * CELL
        for ry, bits in enumerate(rows(data, code)):
            for cx in range(CELL):
                if (bits >> cx) & 1:          # LSB is the leftmost pixel
                    rgba[((gy + ry) * width + gx + cx) * 4 + 3] = 0xFF
    return width, height, bytes(rgba)


def build_fnt(ids: list[tuple[int, int]], png_name: str,
              width: int, height: int, face: str = "TempleOS Std") -> str:
    """A BMFont descriptor in the text dialect Godot 4's importer reads."""
    lines = [
        # size 8 is the design size; Godot scales it by whole numbers from
        # there, which is the only scaling TempleOS itself does either
        # (GR_SCRN_ZOOM_MAX 8, Adam/Gr/GrGlbls.HC:36).
        'info face="%s" size=%d bold=0 italic=0 charset="" unicode=1'
        ' stretchH=100 smooth=0 aa=1 padding=0,0,0,0 spacing=0,0 outline=0'
        % (face, CELL),
        # base == lineHeight, because a TempleOS glyph is a whole cell with no
        # baseline: descenders live inside the 8 rows like everything else, so
        # the ascent is the full cell and the descent is zero. That is what
        # keeps a run of Labels on the same 8px rhythm as the guest's grid.
        'common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0'
        ' alphaChnl=0 redChnl=4 greenChnl=4 blueChnl=4'
        % (CELL, CELL, width, height),
        'page id=0 file="%s"' % png_name,
        'chars count=%d' % len(ids),
    ]
    for cp, code in ids:
        gx = (code % COLS) * CELL
        gy = (code // COLS) * CELL
        lines.append(
            'char id=%-6d x=%-4d y=%-4d width=%d height=%d xoffset=0 '
            'yoffset=0 xadvance=%d page=0 chnl=15'
            % (cp, gx, gy, CELL, CELL, CELL))
    lines.append('kernings count=0')
    return "\n".join(lines) + "\n"


# Godot's BMFont import options, as we want them rather than as they default.
# scaling_mode 1 is "Enabled (Integer)": a request for any font_size that is
# not a whole multiple of 8 rounds down to one that is, instead of resampling.
# TempleOS's own display has exactly the same rule - the only scaling anywhere
# in the OS is a whole-screen zoom of 1..8 (vendor/TempleOS/Adam/Gr/GrGlbls.HC:36
# `#define GR_SCRN_ZOOM_MAX 8`). Godot's own default here is 2, fractional.
IMPORT_PARAMS = [
    ("fallbacks", "[]"),
    ("compress", "true"),
    ("scaling_mode", "1"),
]


def import_params(fallbacks: list[str]) -> list[tuple[str, str]]:
    """IMPORT_PARAMS with the fallback chain filled in.

    A fallback is how a Label with Russian in it works without any control
    knowing that half of its letters came from a different file: the text
    server asks the std font for a character, and only when it has none does
    it walk the chain. Which is the same arrangement the kernel has
    (Kernel/KMain.HC:67-68, text.font and text.aux_font), minus the part where
    you have to press CTRL-ALT-F.
    """
    if not fallbacks:
        return IMPORT_PARAMS
    value = "[%s]" % ", ".join('Resource("%s")' % p for p in fallbacks)
    return [(k, value if k == "fallbacks" else v) for k, v in IMPORT_PARAMS]


def _same_fallbacks(line: str, want: str) -> bool:
    """Do these two `fallbacks=` values name the same res:// paths?"""
    paths = re.compile(r'"(res://[^"]+)"')
    return paths.findall(line) == paths.findall(want)


def pin_import(fnt_path: str, params: list[tuple[str, str]]) -> tuple[str, bool]:
    """Set the import options on the .fnt, without disturbing the rest.

    Godot writes the .import file itself on first import and mints a uid in
    it that other resources reference the font by, so an existing file is
    patched key by key. A missing one is written as [params] only; Godot
    fills in [remap] and [deps] the first time it scans.
    """
    path = fnt_path + ".import"
    body = "".join("%s=%s\n" % kv for kv in params)

    if not os.path.exists(path):
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("[params]\n\n" + body)
        return path, True

    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    changed = False
    for key, val in params:
        pat = re.compile(r"^%s=.*$" % re.escape(key), re.M)
        hit = pat.search(text)
        if hit and key == "fallbacks" and _same_fallbacks(hit.group(0), val):
            # Godot rewrites the fallback list on import, adding the uid it
            # minted for the font next to the path. That is more information
            # than this tool has, not less, so leave it alone rather than
            # trading it back and forth on every run.
            continue
        if hit:
            new = pat.sub("%s=%s" % (key, val), text)
        else:
            # [params] is the last section Godot writes, so the end of the
            # file is inside it.
            new = text.rstrip("\n") + "\n%s=%s\n" % (key, val)
        changed = changed or new != text
        text = new
    if changed:
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
    return path, changed


# --------------------------------------------------------------- the reports

def coverage(data: bytes) -> tuple[list[int], list[int]]:
    blank = [c for c in range(GLYPHS)
             if data[c * CELL:(c + 1) * CELL] == b"\x00" * CELL]
    inked = [c for c in range(GLYPHS) if c not in set(blank)]
    return blank, inked


def check_render(data: bytes, png_path: str, src: str) -> int:
    """Compare a Godot-rendered PNG against the bits in the source font.

    The sidecar is <png>.txt, written by host/temple/theme/font_check.gd: one
    `<templeos_code_hex> <x> <y>` line per glyph the text server placed, so
    this checks the shape, the bit order and the advance in one pass.
    """
    side = png_path + ".txt"
    if not os.path.exists(side):
        raise SystemExit("%s not found; run font_check.gd first" % side)

    placements = []
    with open(side, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            code, x, y = line.split()
            placements.append((int(code, 16), int(x), int(y)))
    if not placements:
        raise SystemExit("%s named no glyphs" % side)

    width, height, rgba = png_read(png_path)
    print("%s: %dx%d, %d glyph(s) placed" % (png_path, width, height,
                                             len(placements)))

    bad = 0
    for code, gx, gy in placements:
        want = art(data, code)
        got = []
        for ry in range(CELL):
            line = ""
            for cx in range(CELL):
                px, py = gx + cx, gy + ry
                if not (0 <= px < width and 0 <= py < height):
                    line += "?"
                    continue
                line += "#" if rgba[(py * width + px) * 4 + 3] >= 128 else "."
            got.append(line)
        ok = got == want
        if not ok:
            bad += 1
        print("\n  0x%02X at (%d,%d)  %s"
              % (code, gx, gy, "ok" if ok else "MISMATCH"))
        print("     %-12s rendered" % os.path.basename(src))
        for w, g in zip(want, got):
            print("     %s   %s%s" % (w, g, "" if w == g else "   <-"))

    print("\n%d/%d glyph(s) matched" % (len(placements) - bad, len(placements)))
    return 1 if bad else 0


def res_path(out: str, name: str) -> str:
    """The res:// path of an output, or "" if it lands outside the project."""
    rel = os.path.relpath(os.path.join(out, name + ".fnt"),
                          os.path.join(ROOT, "host", "temple"))
    if rel.startswith(os.pardir):
        return ""
    return "res://" + rel.replace(os.sep, "/")


def emit(data: bytes, out: str, name: str, ids: list[tuple[int, int]],
         face: str, fallbacks: list[str]) -> None:
    """Write one font's four files and say what went where."""
    bin_path = os.path.join(out, name + ".bin")
    png_path = os.path.join(out, name + ".png")
    fnt_path = os.path.join(out, name + ".fnt")

    with open(bin_path, "wb") as fh:
        fh.write(data)

    width, height, rgba = build_atlas(data)
    png_write(png_path, width, height, rgba)

    with open(fnt_path, "w", encoding="ascii", newline="\n") as fh:
        fh.write(build_fnt(ids, os.path.basename(png_path), width, height, face))
    params = import_params(fallbacks)
    imp_path, imp_changed = pin_import(fnt_path, params)

    blank, inked = coverage(data)
    aliases = sum(1 for cp, _ in ids if PUA <= cp < PUA + GLYPHS)
    print("glyphs   %d, %d with ink, %d blank (%s)"
          % (GLYPHS, len(inked), len(blank),
             " ".join("%02X" % c for c in blank)))
    print("ids      %d (%d natural codepoints + %d U+E0xx aliases)"
          % (len(ids), len(ids) - aliases, aliases))
    print("wrote    %s  %d bytes" % (os.path.relpath(bin_path, ROOT), len(data)))
    print("wrote    %s  %dx%d" % (os.path.relpath(png_path, ROOT), width, height))
    print("wrote    %s" % os.path.relpath(fnt_path, ROOT))
    print("%s %s  (%s)"
          % ("wrote   " if imp_changed else "kept    ",
             os.path.relpath(imp_path, ROOT),
             ", ".join("%s=%s" % kv for kv in params)))


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=DEFAULT_SRC, help="path to FontStd.HC")
    ap.add_argument("--aux", default=DEFAULT_AUX,
                    help="path to FontCyrillic.HC; empty to skip the aux font")
    ap.add_argument("--out", default=DEFAULT_OUT, help="directory to write into")
    ap.add_argument("--name", default="font_std", help="basename for the outputs")
    ap.add_argument("--aux-name", default="font_cyrillic",
                    help="basename for the aux font's outputs")
    ap.add_argument("--no-underline", action="store_true",
                    help="skip the underlined variants")
    ap.add_argument("--font", choices=["std", "aux"], default="std",
                    help="which font --dump and --check-render read")
    ap.add_argument("--dump", nargs="*", metavar="HEX",
                    help="print ASCII art for these character codes and exit")
    ap.add_argument("--check-render", metavar="PNG",
                    help="compare a Godot render against the source bits and exit")
    args = ap.parse_args()

    data = parse_font(args.src)
    self_check(data)
    aux = parse_font(args.aux) if args.aux else None
    if aux is not None:
        aux_check(aux, data)

    chosen, chosen_src = (data, args.src)
    if args.font == "aux":
        if aux is None:
            raise SystemExit("--font aux needs an --aux path")
        chosen, chosen_src = aux, args.aux

    if args.dump is not None:
        letters = {code: ch for ch, code in cyrillic_map().items()}
        for tok in args.dump:
            code = int(tok, 16)
            if args.font == "aux":
                where = letters.get(code, "not a letter this table names")
            else:
                cp = natural_codepoint(code)
                where = "U+%04X" % cp if cp is not None else "no natural codepoint"
            print("\n0x%02X   alias U+%04X   %s" % (code, PUA + code, where))
            for line in art(chosen, code):
                print("   ", line)
        return 0

    if args.check_render:
        return check_render(chosen, args.check_render, chosen_src)

    os.makedirs(args.out, exist_ok=True)

    # The std font names the aux font as its fallback, so the aux font has to
    # be on disk first or the first import resolves the reference to nothing.
    aux_res = ""
    if aux is not None:
        print("read     %s" % os.path.relpath(args.aux, ROOT))
        emit(aux, args.out, args.aux_name, build_aux_ids(),
             "TempleOS Cyrillic", [])
        aux_res = res_path(args.out, args.aux_name)
        if not aux_res:
            print("note     --out is outside the Godot project, so the std "
                  "font gets no fallback")
        print()

    print("read     %s" % os.path.relpath(args.src, ROOT))
    emit(data, args.out, args.name, build_ids(data), "TempleOS Std",
         [aux_res] if aux_res else [])

    # And the underlined pair. Links in a DolDoc are underlined, and the only
    # faithful way to draw that here is as a font - see underlined() for why.
    if not args.no_underline:
        print()
        aux_u_res = ""
        if aux is not None:
            emit(underlined(aux), args.out, args.aux_name + "_u",
                 build_aux_ids(), "TempleOS Cyrillic Underlined", [])
            aux_u_res = res_path(args.out, args.aux_name + "_u")
        print()
        emit(underlined(data), args.out, args.name + "_u", build_ids(data),
             "TempleOS Std Underlined", [aux_u_res] if aux_u_res else [])

    print("\nrun the project's importer next, then the render checks:")
    print("  godot --headless --path host/temple --import")
    print("  godot --headless --path host/temple --script theme/font_check.gd "
          "res://theme/font_check.tscn -- <out.png>")
    print("  python tools/extract_font.py --check-render <out.png>")
    print("  godot --headless --path host/temple --script theme/cyrillic_check.gd "
          "res://theme/font_check.tscn -- <ru.png>")
    print("  python tools/extract_font.py --font aux --check-render <ru.png>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
