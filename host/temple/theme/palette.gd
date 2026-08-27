extends RefCounted
class_name TemplePalette

## The sixteen colours, as the guest's pixels actually arrive.
##
## TempleOS keeps its palette as sixteen CBGR48 literals:
##
##     Adam/Gr/GrPalette.HC:64-68
##     Kernel/KernelA.HH:2950-2953    public I64 class CBGR48 {U16 b,g,r,pad;};
##
## CBGR48 is four U16 fields packed into one I64 - blue in the low sixteen bits,
## then green, then red, then padding - so a literal written out reads
## 0xRRRRGGGGBBBB, and BLUE at index 1 is 0x00000000AAAA. Only four channel
## values are ever used: 0x0000, 0x5555, 0xAAAA, 0xFFFF.
##
## Those sixteen bits per channel never leave the machine. The VGA DAC takes
## six, and TempleOS hands it the top six:
##
##     OutU8(VGAP_PALETTE_DATA,bgr48.r>>10);
##     Adam/Gr/GrPalette.HC:39-41
##
## so the four channel values arrive at the DAC as 0x00, 0x15, 0x2A, 0x3F, and
## the eight-bit colour the player sees is whatever the display puts back. That
## reconstruction belongs to QEMU, not to TempleOS, and it is not the obvious
## v*255/63. QEMU shifts the six bits up by two and fills both new low bits with
## the old bit 0:
##
##     0x00 -> 0x00     0x15 -> 0x57     0x2A -> 0xA8     0x3F -> 0xFF
##
## and not 0x00 / 0x55 / 0xAA / 0xFF. Fourteen of the sixteen colours therefore
## differ from a source-only reading by exactly 2/255 on one or more channels.
##
## The values below are measured, not derived. Every 640x480 PNG in build/shots
## plus build/whpx_now.png - eighty frames of the running guest, taken through
## both QMP screendump and the launcher's own RFB path - contains fourteen
## distinct RGB values between them, and every channel byte in all of them is
## one of 0x00, 0x57, 0xA8, 0xFF. build/shots/godot_rfb.png came in through the
## 24-bit true-colour format RfbClient asks for rather than through screendump
## and carries the same bytes, so this is what the launcher holds in memory and
## not an artefact of how the screenshots were written.
##
## CYAN and LTPURPLE are the two exceptions: no capture contains either one.
## They are filled in from the per-channel mapping above, which the other
## fourteen exercise at all four of its input values, so they are as safe as
## anything derived can be - but they are the only two entries here that were
## not read off a real frame.
##
## Why this was worth measuring: the panel sits against the guest's framebuffer
## with no gutter between them. A field of 0x0000AA butted against the guest's
## 0x0000A8 is a visible edge on a flat background, and a pixel comparison
## against a captured frame fails on almost every non-black, non-white pixel.
## If the guest is ever drawn through something other than QEMU's VGA path,
## re-measure - the six-to-eight rule is the display's, not the OS's.
##
## The names are TempleOS's own, from Kernel/KernelA.HH:2914-2929, with their
## string forms at Kernel/KDefine.HC:115-117. Note the spelling: LTGRAY and
## DKGRAY, with an A. LTGREY is not a colour in this operating system, and
## $LTGREY$ in a DolDoc string yields an error entry rather than a colour.
##
## This is a script and not a .tres because the citations are half the point.
## A saved resource keeps values and drops comments, and it would have to be
## indexed by number where a script can be indexed by name.

#                                          idx  GrPalette.HC:64-68  DAC r,g,b  measured
const BLACK    := Color8(0x00, 0x00, 0x00)  #  0  0x000000000000     00 00 00   #000000
const BLUE     := Color8(0x00, 0x00, 0xA8)  #  1  0x00000000AAAA     00 00 2A   #0000A8
const GREEN    := Color8(0x00, 0xA8, 0x00)  #  2  0x0000AAAA0000     00 2A 00   #00A800
const CYAN     := Color8(0x00, 0xA8, 0xA8)  #  3  0x0000AAAAAAAA     00 2A 2A   derived
const RED      := Color8(0xA8, 0x00, 0x00)  #  4  0xAAAA00000000     2A 00 00   #A80000
const PURPLE   := Color8(0xA8, 0x00, 0xA8)  #  5  0xAAAA0000AAAA     2A 00 2A   #A800A8
const BROWN    := Color8(0xA8, 0x57, 0x00)  #  6  0xAAAA55550000     2A 15 00   #A85700
const LTGRAY   := Color8(0xA8, 0xA8, 0xA8)  #  7  0xAAAAAAAAAAAA     2A 2A 2A   #A8A8A8
const DKGRAY   := Color8(0x57, 0x57, 0x57)  #  8  0x555555555555     15 15 15   #575757
const LTBLUE   := Color8(0x57, 0x57, 0xFF)  #  9  0x55555555FFFF     15 15 3F   #5757FF
const LTGREEN  := Color8(0x57, 0xFF, 0x57)  # 10  0x5555FFFF5555     15 3F 15   #57FF57
const LTCYAN   := Color8(0x57, 0xFF, 0xFF)  # 11  0x5555FFFFFFFF     15 3F 3F   #57FFFF
const LTRED    := Color8(0xFF, 0x57, 0x57)  # 12  0xFFFF55555555     3F 15 15   #FF5757
const LTPURPLE := Color8(0xFF, 0x57, 0xFF)  # 13  0xFFFF5555FFFF     3F 15 3F   derived
const YELLOW   := Color8(0xFF, 0xFF, 0x57)  # 14  0xFFFFFFFF5555     3F 3F 15   #FFFF57
const WHITE    := Color8(0xFF, 0xFF, 0xFF)  # 15  0xFFFFFFFFFFFF     3F 3F 3F   #FFFFFF

## The same sixteen in index order, for turning an attribute nibble into a
## colour. A PackedColorArray will not fold into a const in GDScript, so this is
## a typed Array; it is read-only in practice and nothing here writes to it.
const INDEX: Array[Color] = [
	BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY,
	DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE,
]

## Index order again, spelled the way the OS spells them - Kernel/KDefine.HC:115-117.
const NAMES: Array[String] = [
	"BLACK", "BLUE", "GREEN", "CYAN", "RED", "PURPLE", "BROWN", "LTGRAY",
	"DKGRAY", "LTBLUE", "LTGREEN", "LTCYAN", "LTRED", "LTPURPLE", "YELLOW", "WHITE",
]


# ---------------------------------------------------------------------------
# Roles.
#
# An attribute byte is background in the high nibble and foreground in the low,
# so WHITE<<4+BLUE is 0xF1. The OS quotes attribute bytes, so this file does
# too, with the two colours spelled out beside each for direct use.

## The desktop. Adam/WallPaper.HC:26 forces the window manager's own task to
## BLUE<<4+WHITE every frame, and Adam/Gr/GrScrn.HC:27-28 fills the whole screen
## rect with it. Measured: pixel (0,0) of build/shots/B1_booted.png is #0000A8,
## and row 0 of every 640x480 capture is about 80% BLUE with WHITE text on it.
##
## It is not a flat field, though. The wallpaper prints a live report over that
## blue in two more foregrounds - YELLOW counters at Adam/WallPaper.HC:28 and
## :68, one BROWN line per task at :76 - so anything imitating the desktop that
## stops at "blue with a status line" will read as empty next to the real thing.
const ATTR_DESKTOP := 0x1F
const DESKTOP_BG := BLUE
const DESKTOP_FG := WHITE
const DESKTOP_ACCENT_FG := YELLOW
const DESKTOP_TASK_FG := BROWN

## A window's interior. Kernel/KTask.HC:222 `task->text_attr=WHITE<<4+BLUE;`,
## painted at Adam/Gr/GrScrn.HC:27-28.
const ATTR_WINDOW_BODY := 0xF1
const BODY_BG := WHITE
const BODY_FG := BLUE

## A document's own default, which is not the same thing. DOC_ATTR_DFT_TEXT is
## WHITE<<4+BLACK at Kernel/KernelA.HH:1138, set on every new doc at
## Adam/DolDoc/DocNew.HC:294 and by the editor at Adam/DolDoc/DocEd.HC:159. So
## text that the task prints comes out BLUE and text a document lays down comes
## out BLACK, and both appear in one frame - build/shots/B1_booted.png has blue
## "Public Domain Operating System" above black "Linux is a trademark".
const ATTR_DOC_TEXT := 0xF0
const DOC_TEXT_BG := WHITE
const DOC_TEXT_FG := BLACK

## The window frame is not a fixed colour, and treating it as one is a trap.
## Kernel/KTask.HC:224 sets border_attr=DrvTextAttrGet(':') once at task
## creation, but a terminal immediately sets border_src=BDS_CUR_DRV
## (Adam/DolDoc/DocTerm.HC:44) and Adam/DolDoc/DocRecalcLib.HC:197-198
## recomputes the attribute from the task's *current* drive on every 30fps
## update; an editor recomputes it from the edited file's drive letter at
## :202-203. The recipe is Kernel/BlkDev/DskDrv.HC:321-329,
## blkdev_text_attr[device type]<<4 | drv_text_attr[letter%3], with the two
## tables at :318-319.
##
## Both cases are in this repo's own captures. The left border column of
## build/shots/B1_booted.png (installed, current drive C:, an ATA disk) is
## exactly half WHITE and half BLUE - attr 0xF1. The same column of
## build/shots/11_shell.png and 30_shell.png (live CD, current drive T:, ATAPI)
## is half LTBLUE and half BLACK - attr 0x90. Half rather than a quarter because
## a focused window's vertical border glyph is the double bar 0x05, four ink
## columns of eight.
##
## Focus does not change the colour. Adam/Gr/GrScrn.HC:25-26 passes
## `task==sys_focus_task` to TextBorder, and Adam/Gr/GrTextBase.HC:337-348 uses
## it only to pick a different border character - single line to double line.
## Some windows override the frame outright:
## Adam/AutoComplete/ACTask.HC:26 forces an LTGRAY ground, which is the grey
## panel visible on the right of build/shots/B1_booted.png.
const ATTR_FRAME_ATA_C := 0xF1     # installed, current drive C:
const ATTR_FRAME_ATAPI_T := 0x90   # live CD, current drive T:
const FRAME_BG := WHITE            # the C: case; see above before relying on it
const FRAME_FG := BLUE

## DolDoc's semantic colours, all from Kernel/KernelA.HH:1138-1155. The type
## defaults that go with them are the string at Adam/DolDoc/DocInit.HC:29-31:
## links and macros carry +UL, and trees carry +UL and +C, so a tree is
## underlined and starts collapsed.
const LINK_FG := RED               # DOC_COLOR_LINK, KernelA.HH:1140, underlined
const MACRO_FG := LTBLUE           # DOC_COLOR_MACRO, KernelA.HH:1141, underlined
const ANCHOR_FG := DKGRAY          # DOC_COLOR_ANCHOR, KernelA.HH:1142
const TREE_FG := PURPLE            # DOC_COLOR_TREE, KernelA.HH:1143, underlined
const PROMPT_FG := GREEN           # DOC_COLOR_PMT, KernelA.HH:1144
const ALT_TEXT_FG := LTGRAY        # DOC_COLOR_ALT_TEXT, KernelA.HH:1139

## The hover-only menu strip. Adam/Menu.HC:95 sets m->attr=BLUE<<4+YELLOW, and
## Adam/Menu.HC:185-198 fills the strip with attr>>4 and draws each item's text
## in attr&15 - so yellow on blue, with the hovered item swapped.
const ATTR_MENU := 0x1E
const MENU_BG := BLUE
const MENU_FG := YELLOW

## Progress bars: a BLACK rect with an LTGREEN fill inset two pixels
## (Adam/Win.HC:27-49) and a GREEN caption centred above it (Adam/Win.HC:67-83).
const PROGRESS_BG := BLACK
const PROGRESS_FILL := LTGREEN
const PROGRESS_LABEL_FG := GREEN


# ---------------------------------------------------------------------------
# Selection.
#
# There is no highlight colour in TempleOS, and inventing one is the single
# quickest way to make a tribute look like an imitation. Selection is bit 30 of
# a text cell - "Bit 30  Sel (XOR colors with FF)", Doc/TextBase.DD, with
# ATTRF_SEL defined as 0x40000000 at Kernel/KernelA.HH:895 - and the renderer
# acts on it at Adam/Gr/GrScrn.HC:225-226:
#
#     if (cur_ch & ATTRF_SEL)
#       cur_ch.u8[1]=cur_ch.u8[1]^0xFF;
#
# u8[1] is the attribute byte, so both nibbles complement at once: background
# n becomes 15-n and foreground n becomes 15-n. Focus and the pressed state use
# the same trick, and so does the caret - Adam/DolDoc/DocRecalc.HC:1273-1275
# ORs in DOCET_BLINK and XORs 0xFF00, and blink swaps the two nibbles at
# Adam/Gr/GrScrn.HC:229-230, so on a space the caret alternates a solid BLACK
# cell and a solid YELLOW one at 2.5Hz. That is measurable: scanning
# build/shots/B1_booted.png cell by cell turns up exactly two 8x8 cells that are
# solid YELLOW and nothing else, which is 0xF1 complemented to 0x0E and caught
# on the bright half of the blink.
#
# What this means for a selected row in the panel: do not reach for an accent
# colour. Complement the attribute the row already has. On the window body that
# lands on BLACK ground with YELLOW text, which is why TempleOS selections look
# the way they do - and it stays correct if the row's own colours change.
const ATTR_SELECTED_BODY := 0x0E   # ATTR_WINDOW_BODY ^ 0xFF
const SELECTED_BODY_BG := BLACK
const SELECTED_BODY_FG := YELLOW


## Build an attribute byte the way the OS writes one: WHITE<<4+BLUE is 0xF1.
static func attr(background: int, foreground: int) -> int:
	return ((background & 0xF) << 4) | (foreground & 0xF)


## The background colour of an attribute byte - its high nibble.
static func bg(a: int) -> Color:
	return INDEX[(a >> 4) & 0xF]


## The foreground colour of an attribute byte - its low nibble.
static func fg(a: int) -> Color:
	return INDEX[a & 0xF]


## Selected, focused or pressed: the whole attribute byte complemented.
## Adam/Gr/GrScrn.HC:225-226.
static func selected(a: int) -> int:
	return a ^ 0xFF


## Inverted ($IV,1$ in a DolDoc, ATTRF_INVERT): the two nibbles swapped, which
## is not the same as complemented. Adam/Gr/GrScrn.HC:227-228.
static func inverted(a: int) -> int:
	return ((a & 0x0F) << 4) | ((a >> 4) & 0x0F)
