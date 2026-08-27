#!/usr/bin/env python3
"""
make_chrome.py - cut the window-frame textures out of TempleOS's own font.

A TempleOS window frame is not a stroke. It is a ring of characters, one cell
thick, drawn outside the window rect with the ordinary text renderer:

    TextChar(task,,l-1,t-1,text.border_chars[6+solid]+attr);
    for (i=l;i<=r;i++) TextChar(task,,i,t-1,text.border_chars[2+solid]+attr);
    vendor/TempleOS/Adam/Gr/GrTextBase.HC:329-348

and `solid` is `task==sys_focus_task` (vendor/TempleOS/Adam/Gr/GrScrn.HC:25-26),
which is the whole of the focus indication: the glyphs change from single line
to double line, and nothing else moves. The twelve glyphs are named in
vendor/TempleOS/Kernel/KMain.HC:84-85,

    text.border_chars[2] (I64)=0x0908070605040302;
    text.border_chars[10](U32)=0x0D0C0B0A;

i.e. codes 0x02..0x0D, unfocused first and focused second in each pair.

So the frame this launcher draws is made of the same bytes. Nothing here is
drawn by hand: the ink comes from theme/font_std.bin, which is the kernel's own
2048-byte font as dumped by tools/extract_font.py, and the shapes are what
they are. Hand-rolling a one-pixel rectangle instead would put the line on the
edge of the cell, and TempleOS puts it at row 4 of 8 - four pixels of paper
outside the line - which is most of why its windows look the way they do.

The result is three 24x24 nine-patch textures and one 8x8 tile. Godot's
StyleBoxTexture tiles the edges rather than stretching them, so an 8-pixel
glyph repeats along an edge of any length; the edge glyphs are uniform down
their length, so a partial tile at the end of a run is invisible.

COLOURS. Baked in, because a StyleBoxTexture has no separate ground colour and
the ring needs one - the border cell's background is opaque, and a window is a
white rectangle with a blue line inset four pixels, not a line floating on the
desktop. The two attributes used here are:

    0xF1  WHITE on BLUE   the window body and, for a C: ATA boot disk, its
                          frame: Kernel/KTask.HC:222 text_attr=WHITE<<4+BLUE,
                          :224 border_attr=DrvTextAttrGet(':') resolved
                          through Kernel/BlkDev/DskDrv.HC:318-329. Measured on
                          this repo's own capture: the left border column of
                          build/shots/B1_booted.png is half WHITE, half BLUE.
    0x0E  BLACK on YELLOW  0xF1 complemented. TempleOS has no highlight colour;
                          selected, pressed and hovered are all attr ^ 0xFF
                          (ATTRF_SEL, Kernel/KernelA.HH:895, acted on at
                          Adam/Gr/GrScrn.HC:225-226).

The eight-bit values are QEMU's, not the palette literals' - see the long note
at the top of theme/palette.gd. If those are ever re-measured, they have to be
changed here too; this file is the one place in the theme where they are
duplicated, and it is duplicated because Python cannot read a GDScript const.

WHY THIS LIVES BESIDE THE THEME AND NOT IN tools/. It produces theme assets and
nothing else, from a file that is itself already in theme/. Running it needs
Pillow and nothing from the rest of the repo:

    python host/temple/theme/make_chrome.py

then re-import the project so Godot picks the PNGs up.
"""

import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.path.join(HERE, "font_std.bin")

CELL = 8

# vendor/TempleOS/Kernel/KMain.HC:84-85, in the order TextBorder indexes them
# (vendor/TempleOS/Adam/Gr/GrTextBase.HC:337-348): horizontal, vertical, then
# the four corners top-left, top-right, bottom-left, bottom-right. Unfocused is
# the even code of each pair and focused the odd one - `6+solid`, `2+solid`.
BORDER = {
    "horiz": (0x02, 0x03),
    "vert": (0x04, 0x05),
    "tl": (0x06, 0x07),
    "tr": (0x08, 0x09),
    "bl": (0x0A, 0x0B),
    "br": (0x0C, 0x0D),
}
BLANK = 0x20

# Measured off the guest, not derived from the palette literals. See
# theme/palette.gd for why 0xA8 rather than 0xAA.
WHITE = (0xFF, 0xFF, 0xFF)
BLUE = (0x00, 0x00, 0xA8)
BLACK = (0x00, 0x00, 0x00)
YELLOW = (0xFF, 0xFF, 0x57)

ATTR_F1 = (WHITE, BLUE)   # paper, ink
ATTR_0E = (BLACK, YELLOW)


def load_font(path: str) -> bytes:
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) != 256 * CELL:
        raise SystemExit("%s is %d bytes, expected %d - run tools/extract_font.py"
                         % (path, len(data), 256 * CELL))
    return data


def blit(img: Image.Image, font: bytes, code: int, gx: int, gy: int,
         paper: tuple, ink: tuple) -> None:
    """One glyph, one cell. Bit 0 of a row byte is the LEFTMOST pixel."""
    px = img.load()
    for row in range(CELL):
        bits = font[code * CELL + row]
        for col in range(CELL):
            px[gx + col, gy + row] = ink if (bits >> col) & 1 else paper


def ring(font: bytes, solid: int, attr: tuple) -> Image.Image:
    """A 3x3 cell nine-patch: four corners, four edges, and a cell of paper."""
    paper, ink = attr
    img = Image.new("RGB", (3 * CELL, 3 * CELL), paper)
    cells = [
        [BORDER["tl"][solid], BORDER["horiz"][solid], BORDER["tr"][solid]],
        [BORDER["vert"][solid], BLANK, BORDER["vert"][solid]],
        [BORDER["bl"][solid], BORDER["horiz"][solid], BORDER["br"][solid]],
    ]
    for row, line in enumerate(cells):
        for col, code in enumerate(line):
            blit(img, font, code, col * CELL, row * CELL, paper, ink)
    return img


def tile(font: bytes, code: int, attr: tuple) -> Image.Image:
    paper, ink = attr
    img = Image.new("RGB", (CELL, CELL), paper)
    blit(img, font, code, 0, 0, paper, ink)
    return img


def scroll_square() -> Image.Image:
    """The one thing in the chrome that is not a character.

    A window's scroll indicator is a single WIN_SCROLL_SIZE square that rides
    the border ring, drawn as two filled rectangles:

        GrRect(dc,c->left,c->top,8,8);            // outer, colour A
        GrRect(dc,c->left+2,c->top+2,4,4);        // inner, colour B
        vendor/TempleOS/Adam/Ctrls/CtrlsA.HC:106-123

    with A and B taken from `s->color=border_attr&0xF^0xF+(border_attr&0xF)<<4`
    at CtrlsA.HC:132-133. `^` binds tighter than `+` in HolyC
    (vendor/TempleOS/Compiler/CompilerA.HH:346,348), so for a frame attribute of
    0xF1 that is (1^0xF) + (1<<4) = 0x1E: A = the low nibble = YELLOW, B = the
    high nibble = BLUE. The two swap while it is dragged.
    """
    img = Image.new("RGB", (CELL, CELL), YELLOW)
    px = img.load()
    for y in range(2, 6):
        for x in range(2, 6):
            px[x, y] = BLUE
    return img


def self_check(font: bytes) -> None:
    """The two things that would be silently wrong: bit order and glyph choice.

    0x06 is the unfocused top-left corner. Under LSB-is-leftmost its row 4 is
    0xF8 = ink in columns 3..7, running RIGHT from the vertical bar; read the
    other way round it would run left and the corner would be a top-right. The
    same byte therefore settles both questions at once.
    """
    tl = font[0x06 * CELL: 0x06 * CELL + CELL]
    if tl[4] != 0xF8 or tl[7] != 0x18:
        raise SystemExit("glyph 0x06 is not the top-left corner this expects: %s"
                         % " ".join("%02X" % b for b in tl))
    horiz = font[0x02 * CELL: 0x02 * CELL + CELL]
    if horiz[4] != 0xFF or any(horiz[r] for r in (0, 1, 2, 3, 5, 6, 7)):
        raise SystemExit("glyph 0x02 is not a single rule on row 4: %s"
                         % " ".join("%02X" % b for b in horiz))


def main() -> int:
    font = load_font(FONT)
    self_check(font)

    written = []
    for name, img in (
        # Unfocused and focused, in the window body's own attribute.
        ("frame.png", ring(font, 0, ATTR_F1)),
        ("frame_focus.png", ring(font, 1, ATTR_F1)),
        # The same unfocused ring with the attribute complemented, which is the
        # only highlight this operating system has.
        ("frame_sel.png", ring(font, 0, ATTR_0E)),
        # A single horizontal rule, for a separator. Same glyph the top and
        # bottom edges are made of, so a rule inside a window and the frame
        # around it are the same line.
        ("rule.png", tile(font, BORDER["horiz"][0], ATTR_F1)),
        # The 8x8 square a window's scroll and split controls are made of.
        ("scroll.png", scroll_square()),
        # Nothing at all, for the places Godot wants a decoration TempleOS does
        # not have - the soft gradient it fades the edge of a scrollable list
        # with. A theme cannot say "draw no icon here"; it can only be handed
        # one pixel of nothing.
        ("blank.png", Image.new("RGBA", (1, 1), (0, 0, 0, 0))),
    ):
        path = os.path.join(HERE, name)
        img.save(path)
        written.append((name, img.size))

    for name, size in written:
        print("%-18s %dx%d" % (name, size[0], size[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
