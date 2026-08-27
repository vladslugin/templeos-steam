# font_check.gd - prove that the extracted TempleOS font really renders.
#
# Run headless:
#
#   godot --headless --path host/temple --script theme/font_check.gd \
#         res://theme/font_check.tscn -- <out.png>
#
# The scene on the end is not optional and it is not decoration. A --script
# main loop does not stop Godot instantiating application/run/main_scene, so
# without it this brings up Main.tscn as well, and Main._ready opens an RFB
# connection to the guest and a socket to the bridge before _initialize here
# has run a line. Naming an empty scene instead keeps a font check from
# reaching across to a live VM. Worth knowing too: if anything in here throws,
# _initialize aborts before the quit() at the bottom and the process sits
# there until something kills it - with the launcher attached the whole time.
#
# Then hand the PNG back to the tool that made the font:
#
#   python tools/extract_font.py --check-render <out.png>
#
# which compares every pixel against the U64 literals in
# vendor/TempleOS/Kernel/FontStd.HC. If the atlas were mirrored, or a glyph
# landed in the wrong cell, or the advance were not 8, that comparison fails.
#
# A word on what this does and does not prove. Godot's headless mode runs the
# dummy rendering driver - `--display-driver headless` offers no other - so a
# viewport cannot be read back and there is no GPU to screenshot. What runs
# here instead is the same pipeline a Label uses right up to the final blit:
# the .fnt is imported as a FontFile, the text server shapes a real string
# with it, and every glyph's texture index, atlas rect, offset and advance
# come out of TextServer exactly as they would in TextServer.shaped_text_draw.
# Only the last step - copying those rects onto a canvas - is done here with
# Image.blit_rect instead of by the rasteriser. Everything upstream of that,
# which is where a font goes wrong, is the real thing.

extends SceneTree

const FONT_PATH := "res://theme/font_std.fnt"
const CELL := 8
const PAD := 8

# What to draw, and which TempleOS glyph each character is supposed to reach.
# The point of the list is to exercise both routes into the font at once:
# ASCII and CP437 names resolve through their natural codepoints, while the
# frame glyphs and the solid block have no natural codepoint at all and can
# only be reached through the U+E000 + code aliases.
const SAMPLES := [
	{"code": 0x41, "cp": 0x41,   "why": "'A', plain ASCII"},
	{"code": 0x67, "cp": 0x67,   "why": "'g', the one letter with a descender inside the cell"},
	{"code": 0x30, "cp": 0x30,   "why": "'0', slashed"},
	{"code": 0xDA, "cp": 0x250C, "why": "box drawing, single top left"},
	{"code": 0xC4, "cp": 0x2500, "why": "box drawing, single horizontal"},
	{"code": 0xBF, "cp": 0x2510, "why": "box drawing, single top right"},
	{"code": 0x02, "cp": 0xE002, "why": "window frame horizontal, alias only"},
	{"code": 0x05, "cp": 0xE005, "why": "window frame vertical doubled, alias only"},
	{"code": 0x7F, "cp": 0xE07F, "why": "solid block, alias only"},
]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out_png := args[0] if args.size() > 0 else \
		ProjectSettings.globalize_path("user://font_check.png")

	var font: FontFile = load(FONT_PATH)
	if font == null:
		push_error("could not load " + FONT_PATH)
		quit(1)
		return

	print("font      ", FONT_PATH, "  ", font.get_class())
	print("name      ", font.font_name)
	print("fixed     size=", font.fixed_size, " scale_mode=", font.fixed_size_scale_mode)
	print("height    ", font.get_height(CELL),
		"  ascent=", font.get_ascent(CELL), " descent=", font.get_descent(CELL))
	print("advance   'A' -> ", font.get_string_size("A", HORIZONTAL_ALIGNMENT_LEFT, -1, CELL))
	print("8 chars   ", font.get_string_size("AAAAAAAA", HORIZONTAL_ALIGNMENT_LEFT, -1, CELL))
	print("at 16px   ", font.get_string_size("AAAAAAAA", HORIZONTAL_ALIGNMENT_LEFT, -1, CELL * 2))

	var text := ""
	for s in SAMPLES:
		text += String.chr(s["cp"])

	var ts := TextServerManager.get_primary_interface()
	var shaped := ts.create_shaped_text()
	ts.shaped_text_add_string(shaped, text, font.get_rids(), CELL)
	ts.shaped_text_shape(shaped)
	var glyphs := ts.shaped_text_get_glyphs(shaped)
	var ascent := ts.shaped_text_get_ascent(shaped)
	print("shaped    ", glyphs.size(), " glyph(s), ascent ", ascent,
		", width ", ts.shaped_text_get_size(shaped))

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
			print("atlas     ", src.get_size(), " format ", src.get_format())
			dst = Image.create(width, height, false, src.get_format())

		# "offset" is the shaper's per-glyph nudge, "off" the font's own glyph
		# origin relative to the baseline; a Label adds both the same way.
		var nudge: Vector2 = g["offset"]
		var at := Vector2i(
			int(round(pen + nudge.x + off.x)),
			int(round(PAD + ascent + nudge.y + off.y)))
		dst.blit_rect(src, Rect2i(uv.position, uv.size), at)

		var s: Dictionary = SAMPLES[i]
		print("  0x%02X  U+%04X  index=%d  uv=%s  off=%s  advance=%s  -> %s   %s"
			% [s["code"], s["cp"], int(g["index"]), str(uv), str(off),
			   str(g["advance"]), str(at), s["why"]])
		placements.append("%02X %d %d" % [s["code"], at.x, at.y])
		pen += float(g["advance"])

	ts.free_rid(shaped)

	var err := dst.save_png(out_png)
	if err != OK:
		push_error("could not write " + out_png)
		quit(1)
		return

	var side := FileAccess.open(out_png + ".txt", FileAccess.WRITE)
	if side == null:
		push_error("could not write " + out_png + ".txt")
		quit(1)
		return
	side.store_line("# written by theme/font_check.gd")
	side.store_line("# <templeos code hex> <x> <y> of the 8x8 cell in " +
		out_png.get_file())
	for line in placements:
		side.store_line(line)
	side.close()

	print("wrote     ", out_png)
	print("wrote     ", out_png + ".txt")
	quit(0)
