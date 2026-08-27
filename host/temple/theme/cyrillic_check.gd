# cyrillic_check.gd - prove the campaign's Russian reaches TempleOS's own font.
#
# Run headless, and note the scene on the end - it is not optional, for the
# same reason it is not optional in font_check.gd. A --script main loop does
# not stop Godot instantiating application/run/main_scene, and the main scene
# here is the launcher, which opens an RFB connection to the guest and a socket
# to the bridge the moment it enters the tree. Naming an empty scene replaces
# it:
#
#   godot --headless --path host/temple --script theme/cyrillic_check.gd \
#         res://theme/font_check.tscn -- <out.png>
#   python tools/extract_font.py --font aux --check-render <out.png>
#
# WHAT IS BEING CHECKED, AND WHY IT NEEDED CHECKING
#
# TempleOS carries two fonts - Kernel/KMain.HC:67-68 loads sys_font_std and
# sys_font_cyrillic together, and Kernel/KeyDev.HC:148-151 swaps them on
# CTRL-ALT-F. The launcher cannot swap: one line of the campaign panel has a
# Latin task id on it and a Russian title next to it. So instead the std font
# names the aux font as a fallback (set in font_std.fnt.import by
# tools/extract_font.py) and the text server picks per character.
#
# Two things could be wrong with that and neither is visible in a diff:
#
#   - the fallback might not fire at all, in which case Russian comes out as
#     empty boxes. So this prints, for every letter of the alphabet, which of
#     the two font RIDs served it, and fails if any letter reached neither.
#
#   - the code -> letter table in extract_font.py could be off. Nothing in the
#     TempleOS source states that table; it was read off the bitmaps. A table
#     shifted by one position still renders letters - just the wrong ones -
#     and Cyrillic is exactly the alphabet where a reviewer who does not read
#     it cannot tell. So SAMPLES below restates the table independently, by
#     hand, and the tool compares the rendered pixels against FontCyrillic.HC.
#     If the two disagree about which code draws which letter, the comparison
#     fails on the shape.

extends SceneTree

const FONT_PATH := "res://theme/font_std.fnt"
const AUX_PATH := "res://theme/font_cyrillic.fnt"
const CELL := 8
const PAD := 8

## Every letter of the Russian alphabet, for the coverage report.
const ALPHABET := "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя"

## The pixel-compared sample: a letter, and the FontCyrillic.HC code that is
## supposed to draw it. Chosen so that a table shifted anywhere would show up -
## the first and last letter of each of the four runs, the two letters either
## side of the seam where the descenders were lifted out, one letter that
## reuses ASCII, and one glyph that has to keep coming from the std font even
## with the aux font in the chain.
const SAMPLES := [
	{"ch": "Б", "code": 0xA0, "why": "run 1 starts"},
	{"ch": "Ч", "code": 0xAB, "why": "run 1, the letter most easily read as Ц"},
	{"ch": "Я", "code": 0xB1, "why": "run 1 ends"},
	{"ch": "б", "code": 0xB2, "why": "run 2 starts"},
	{"ch": "т", "code": 0xBF, "why": "run 2, before the letters lifted out"},
	{"ch": "ч", "code": 0xC0, "why": "run 2, after them"},
	{"ch": "я", "code": 0xC7, "why": "run 2 ends"},
	{"ch": "Д", "code": 0xE0, "why": "descenders, uppercase, first"},
	{"ch": "Щ", "code": 0xE2, "why": "descenders, uppercase, last"},
	{"ch": "д", "code": 0xE3, "why": "descenders, lowercase, first"},
	{"ch": "щ", "code": 0xE6, "why": "descenders, lowercase, last"},
	{"ch": "Ь", "code": 0x62, "why": "no glyph of its own; lowercase b is its shape"},
	{"ch": "о", "code": 0x6F, "why": "an ASCII reuse: the aux font's own 0x6F, byte-identical to the std font's"},
	{"ch": "─", "code": 0x02, "why": "the rule the em dash is drawn with"},
]

## Read back at the end: if this cannot be seen in the ASCII art the tool
## prints, the mapping is wrong however green the pixel comparison is.
const WORDS := "Фибоначчи Простое число"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out_png: String = args[0] if args.size() > 0 else \
		ProjectSettings.globalize_path("user://cyrillic_check.png")

	var font: FontFile = load(FONT_PATH)
	var aux: FontFile = load(AUX_PATH)
	if font == null or aux == null:
		push_error("could not load the fonts")
		quit(1)
		return

	var rids := font.get_rids()
	print("font      ", FONT_PATH, "  ", font.font_name)
	print("aux       ", AUX_PATH, "  ", aux.font_name)
	print("fallbacks ", font.fallbacks.size(), " -> ", rids.size(), " rid(s) in the chain")
	print("advance   Ф -> ", font.get_string_size("Ф", HORIZONTAL_ALIGNMENT_LEFT, -1, CELL))

	if font.fallbacks.is_empty():
		push_error("the std font has no fallback; Russian would be empty boxes. "
			+ "Run tools/extract_font.py and re-import.")
		quit(1)
		return

	var ts := TextServerManager.get_primary_interface()

	# Coverage first: every letter, and which font in the chain answered for
	# it. A letter served by neither is one the player would see as a box.
	var from_std := ""
	var from_aux := ""
	var lost := ""
	for i in ALPHABET.length():
		var ch := ALPHABET[i]
		var rid := _serving_rid(ts, ch, rids)
		if rid == rids[0]:
			from_std += ch
		elif rid.is_valid():
			from_aux += ch
		else:
			lost += ch
	print("std font  %d letter(s)  %s" % [from_std.length(), from_std])
	print("aux font  %d letter(s)  %s" % [from_aux.length(), from_aux])
	if lost != "":
		push_error("no font in the chain draws: " + lost)
		quit(1)
		return

	# Then the pixels. One shaped run, exactly as a Label would shape it.
	var text := ""
	for s in SAMPLES:
		text += s["ch"]

	var shaped := ts.create_shaped_text()
	ts.shaped_text_add_string(shaped, text, rids, CELL)
	ts.shaped_text_shape(shaped)
	var glyphs := ts.shaped_text_get_glyphs(shaped)
	var ascent := ts.shaped_text_get_ascent(shaped)
	print("shaped    ", glyphs.size(), " glyph(s), width ",
		ts.shaped_text_get_size(shaped))

	if glyphs.size() != SAMPLES.size():
		push_error("text server produced %d glyphs for %d characters"
			% [glyphs.size(), SAMPLES.size()])
		quit(1)
		return

	var width := int(ts.shaped_text_get_size(shaped).x) + PAD * 2
	var height := CELL + PAD * 2
	var dst: Image = null
	var placements: Array[String] = []

	var pen := float(PAD)
	for i in glyphs.size():
		var g: Dictionary = glyphs[i]
		var size := Vector2i(int(g["font_size"]), 0)
		var frid: RID = g["font_rid"]
		var tex_idx := ts.font_get_glyph_texture_idx(frid, size, int(g["index"]))
		var uv := ts.font_get_glyph_uv_rect(frid, size, int(g["index"]))
		var off := ts.font_get_glyph_offset(frid, size, int(g["index"]))
		var src := ts.font_get_texture_image(frid, size, tex_idx)

		if dst == null:
			dst = Image.create(width, height, false, src.get_format())

		var nudge: Vector2 = g["offset"]
		var at := Vector2i(
			int(round(pen + nudge.x + off.x)),
			int(round(PAD + ascent + nudge.y + off.y)))
		dst.blit_rect(src, Rect2i(uv.position, uv.size), at)

		var s: Dictionary = SAMPLES[i]
		print("  %s  0x%02X  %s  advance=%s  -> %s   %s"
			% [s["ch"], s["code"], "aux" if frid != rids[0] else "std",
			   str(g["advance"]), str(at), s["why"]])
		placements.append("%02X %d %d" % [s["code"], at.x, at.y])
		pen += float(g["advance"])

	ts.free_rid(shaped)

	# The words, as art, so the mapping can be read rather than trusted. Both
	# atlases are white on transparent, so ink is any pixel with alpha.
	_print_words(ts, rids, WORDS)

	if dst.save_png(out_png) != OK:
		push_error("could not write " + out_png)
		quit(1)
		return
	var side := FileAccess.open(out_png + ".txt", FileAccess.WRITE)
	if side == null:
		push_error("could not write " + out_png + ".txt")
		quit(1)
		return
	side.store_line("# written by theme/cyrillic_check.gd")
	side.store_line("# <templeos code hex> <x> <y> of the 8x8 cell in "
		+ out_png.get_file())
	for line in placements:
		side.store_line(line)
	side.close()

	print("wrote     ", out_png)
	print("wrote     ", out_png + ".txt")
	quit(0)


## Which font in the chain draws this character, or an invalid RID if none do.
func _serving_rid(ts: TextServer, ch: String, rids: Array[RID]) -> RID:
	for rid in rids:
		if ts.font_has_char(rid, ch.unicode_at(0)):
			return rid
	return RID()


## The sample words, drawn as ASCII art on the console.
func _print_words(ts: TextServer, rids: Array[RID], words: String) -> void:
	var shaped := ts.create_shaped_text()
	ts.shaped_text_add_string(shaped, words, rids, CELL)
	ts.shaped_text_shape(shaped)
	var glyphs := ts.shaped_text_get_glyphs(shaped)
	var width := int(ts.shaped_text_get_size(shaped).x)
	var img := Image.create(width, CELL, false, Image.FORMAT_RGBA8)
	var pen := 0.0
	for g: Dictionary in glyphs:
		var size := Vector2i(int(g["font_size"]), 0)
		var frid: RID = g["font_rid"]
		var idx := int(g["index"])
		var uv := ts.font_get_glyph_uv_rect(frid, size, idx)
		if uv.size.x > 0:
			var tex := ts.font_get_texture_image(
				frid, size, ts.font_get_glyph_texture_idx(frid, size, idx))
			var off := ts.font_get_glyph_offset(frid, size, idx)
			var nudge: Vector2 = g["offset"]
			img.blit_rect(tex, Rect2i(uv.position, uv.size), Vector2i(
				int(round(pen + nudge.x + off.x)),
				int(round(ts.shaped_text_get_ascent(shaped) + nudge.y + off.y))))
		pen += float(g["advance"])
	ts.free_rid(shaped)

	print("\n", words)
	for y in CELL:
		var line := ""
		for x in width:
			line += "#" if img.get_pixel(x, y).a >= 0.5 else " "
		print("  ", line)
	print()
