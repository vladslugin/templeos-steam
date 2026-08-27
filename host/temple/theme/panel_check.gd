# panel_check.gd - read the campaign document back out of the panel.
#
#   godot --headless --path host/temple res://theme/panel_check.tscn
#
# Exits non-zero and says which line is wrong if it ever stops being true.
#
# WHY THIS EXISTS
#
# The panel composes its content as DolDoc and translates it (CampaignPanel.
# _doldoc). Two kinds of mistake in that translator are invisible to review and
# invisible in a headless render: text that silently disappears - an unbalanced
# dollar swallowing the rest of a line, a task title with a '[' in it eaten as
# a BBCode tag - and colours that come out of the wrong nibble. So this asks
# the RichTextLabel what text it actually parsed, which is the string a player
# would read, and compares the translator's output against attribute arithmetic
# done the long way.
#
# HOW IT RUNS WITHOUT WAKING THE GUEST
#
# It loads the real scenes/Main.tscn, because a hand-rebuilt copy is how a
# previous measurement of this same layout came out three times too large. But
# Main._ready opens an RFB connection to the guest's VNC port and a socket to
# the bridge, and a second client on either wire perturbs anything anyone else
# is measuring. Instantiating a PackedScene does not run _ready - that happens
# on entering the tree - so the script is taken off the root in between and
# Main._ready never runs. Every other node's _ready does.

extends Node

var _failures: Array[String] = []

var _panel: CampaignPanel
var _doc: RichTextLabel
var _campaign: Campaign


func _ready() -> void:
	var packed: PackedScene = load("res://scenes/Main.tscn")
	var main: Control = packed.instantiate()
	main.set_script(null)
	add_child(main)

	_panel = main.get_node("Split/CampaignPanel")
	_doc = _panel.get_node("Root/Doc")
	_campaign = Campaign.new()
	var n := _campaign.load_from("res://data/tasks")
	_panel.bind(_campaign)
	await get_tree().process_frame

	print("tasks loaded          %d" % n)
	print("language              %s" % _panel.lang)

	_check_font()
	_check_translator()
	_check_document(n)
	_check_interaction()
	_check_buttons()
	_check_grid()
	_check_complete()

	if _failures.is_empty():
		print("\nOK")
		get_tree().quit(0)
	else:
		print()
		for f in _failures:
			print("FAIL  " + f)
		get_tree().quit(1)


func _expect(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		_failures.append("%s: got %s, wanted %s" % [what, got, want])


func _expect_in(what: String, haystack: String, needle: String) -> void:
	if not haystack.contains(needle):
		_failures.append("%s: %s is not in the document" % [what, needle])


# ---------------------------------------------------------------------------

## The two font facts the panel depends on and cannot see for itself.
func _check_font() -> void:
	var font: FontFile = _panel.get_theme_default_font()
	var ts := TextServerManager.get_primary_interface()
	var rid: RID = font.get_rids()[0]
	print("\nfont                  %s, %d fallback(s)"
			% [font.font_name, font.fallbacks.size()])
	print("underline             pos %s thickness %s"
			% [ts.font_get_underline_position(rid, 8),
			   ts.font_get_underline_thickness(rid, 8)])

	# Russian has to reach a font. Without the fallback every Cyrillic letter
	# in the campaign is an empty box, and nothing else in the launcher would
	# say so.
	_expect("the std font has a fallback", font.fallbacks.size(), 1)
	var served := 0
	for ch in "Задание пройдено щёлкните":
		for r: RID in font.get_rids():
			if ts.font_has_char(r, ch.unicode_at(0)):
				served += 1
				break
	_expect("every character of a Russian sentence has a glyph",
			served, "Задание пройдено щёлкните".length())

	# The rule an em dash is drawn with, and the underline on row 7 of the
	# cell rather than across the join between two rows.
	_expect("the em dash rule is in the std font",
			ts.font_has_char(rid, "─".unicode_at(0)), true)
	_expect("underline thickness", ts.font_get_underline_thickness(rid, 8), 1.0)
	_expect("underline position", ts.font_get_underline_position(rid, 8), -0.5)


## The translator, on the inputs that would quietly lose text.
func _check_translator() -> void:
	print("\ntranslator")
	var body := TemplePalette.ATTR_DOC_TEXT
	var black := TemplePalette.fg(body).to_html(false)
	var white := TemplePalette.bg(body).to_html(false)

	var plain: String = _panel._doldoc("hello", false)
	print("  plain               %s" % plain)
	_expect("a plain run is one colour tag", plain,
			"[color=#%s]hello[/color]" % black)

	# One dollar is the delimiter, so two are one dollar - the rule that makes
	# guest/Game/GameInit.HC:32 write "$$LTBLUE$$" for one escape.
	_expect("$$ is one dollar", _panel._doldoc("a$$b", false),
			"[color=#%s]a[/color][color=#%s]$b[/color]" % [black, black])

	# A '[' in a task title is a BBCode tag if nobody escapes it.
	_expect_in("a bracket in text survives", _panel._doldoc("a[b]c", false),
			"a[lb]b]c")

	# An em dash becomes the rule glyph, because neither font has an em dash.
	_expect_in("an em dash becomes U+2500", _panel._doldoc("a — b", false), "a ─ b")

	# A command nobody knows is printed, not swallowed.
	_expect_in("an unknown command is shown", _panel._doldoc("x$WOBBLE$y", false),
			"<WOBBLE>")

	# Inside a quoted argument the quote delimits, not the dollar, so a dollar
	# there is an ordinary character and must not end the command.
	_expect_in("a dollar in a quoted argument does not end the command",
			_panel._doldoc("$LK,\"a$b\",A=\"task:x\"$", false), "a$b")
	_expect_in("nor does an escaped quote",
			_panel._doldoc("$LK,\"a\\\"b\",A=\"task:x\"$", false), "a\"b")

	# An unterminated one keeps the rest of the line.
	_expect_in("an unterminated command keeps its line",
			_panel._doldoc("x$RED", false), "$RED")

	# Selection is the attribute complemented, per run, whatever the run's own
	# colours are: the document's WHITE on BLACK becomes BLACK on WHITE, and a
	# link's WHITE on RED becomes BLACK on LTCYAN.
	var sel: String = _panel._doldoc("hello", true)
	print("  selected            %s" % sel)
	_expect("selection complements the whole attribute", sel,
			"[bgcolor=#%s][color=#%s]hello[/color][/bgcolor]"
			% [TemplePalette.fg(body).to_html(false),
			   TemplePalette.bg(body).to_html(false)])

	# Invert swaps the nibbles, which is not the same operation.
	var inv: String = _panel._doldoc("$IV,1$hi$IV,0$", false)
	print("  inverted            %s" % inv)
	_expect_in("invert swaps the nibbles", inv, "[bgcolor=#%s]" % black)

	# A tree carries its own prefix as literal characters, and +C is the
	# collapsed state (Adam/DolDoc/DocRecalc.HC:517-544, DocInit.HC:30).
	_expect_in("an open tree is prefixed -]",
			_panel._doldoc("$TR,\"Ch\"$", false), "-] Ch")
	_expect_in("a collapsed tree is prefixed +]",
			_panel._doldoc("$TR+C,\"Ch\"$", false), "+] Ch")
	_expect_in("a tree is the tree colour",
			_panel._doldoc("$TR,\"Ch\"$", false),
			TemplePalette.TREE_FG.to_html(false))
	_expect_in("a link is the link colour and underlined",
			_panel._doldoc("$LK,\"x\",A=\"task:a\"$", false),
			"[url=task:a][color=#%s][u]x[/u]" % TemplePalette.LINK_FG.to_html(false))
	_expect_in("a macro is the macro colour",
			_panel._doldoc("$MA,\"x\",A=\"hint:1\"$", false),
			TemplePalette.MACRO_FG.to_html(false))
	_expect("the paper is not repainted white on white",
			plain.contains("bgcolor"), false)
	_expect("white is still the paper", white, "ffffff")

	# The round trip an author-supplied title takes: doubled on the way into
	# the DolDoc stream, halved on the way out, with the bracket escaped in
	# between. Titles are data out of data/tasks/*.json and nothing stops one
	# from containing either character.
	var t: Campaign.Task = _campaign.tasks[0]
	var was := [t.title_en, t.title_ru]
	# A title lands twice: once as the heading, and once inside a $LK$ argument
	# where a quote would end the argument early and take the rest of the line
	# with it.
	t.title_en = "Cost $5 [beta] \"x\""
	t.title_ru = t.title_en
	_panel.refresh()
	_expect_in("a dollar and a bracket in a title survive",
			_doc.get_parsed_text(), "Cost $5 [beta] \"x\"")
	_expect("the title survives twice - heading and link",
			_doc.get_parsed_text().count("Cost $5 [beta] \"x\""), 2)
	t.title_en = was[0]
	t.title_ru = was[1]
	_panel.refresh()


## The document a player would read, printed in full.
func _check_document(n: int) -> void:
	var text := _doc.get_parsed_text()
	print("\nthe document, as parsed text:")
	for line in text.split("\n"):
		print("  |%s" % line)

	var first: Campaign.Task = _campaign.tasks[0]
	_expect_in("the count is in the heading", text,
			"%d/%d" % [_campaign.passed_count(), n])
	_expect_in("the selected task's title is the second heading", text,
			first.title(_panel.lang))
	_expect_in("the file to edit is named", text, first.start_file)
	for ref: String in first.doc_refs:
		_expect_in("a reference is listed", text, ref)
	# Nothing in the document may still be markup.
	_expect("no unparsed dollar command survives",
			text.contains("$FG$") or text.contains("$IV"), false)


## The four things a player can click, and the two signals that leave here.
func _check_interaction() -> void:
	print("\ninteraction")
	var a: Campaign.Task = _campaign.tasks[0]
	var b: Campaign.Task = _campaign.tasks[_campaign.tasks.size() - 1]

	var asked: Array[String] = []
	_panel.check_requested.connect(func(id: String) -> void: asked.append("check:" + id))
	_panel.hint_requested.connect(func(id: String, lvl: int) -> void:
		asked.append("hint:%s:%d" % [id, lvl]))

	# Clicking a task row selects it. Two tasks in different chapters, so this
	# also proves selecting one opens the chapter it is in.
	_panel._on_meta_clicked("task:" + b.id)
	_expect_in("clicking a task row selects it",
			_doc.get_parsed_text(), b.title(_panel.lang))
	_expect("the selected task's chapter is open", _panel._open.get(b.chapter), true)

	# A chapter branch toggles.
	_panel._on_meta_clicked("ch:%s" % b.chapter)
	_expect("clicking a chapter closes it", _panel._open.get(b.chapter), false)
	_panel._on_meta_clicked("ch:%s" % b.chapter)
	_expect("clicking it again opens it", _panel._open.get(b.chapter), true)

	# A reference answers with the line to type in the guest.
	if not b.doc_refs.is_empty():
		var ref: String = b.doc_refs[0]
		_panel._on_meta_clicked("doc:" + ref)
		_expect_in("clicking a reference says how to open it",
				_doc.get_parsed_text(), "Ed(\"%s\");" % ref)
		_panel._on_meta_clicked("doc:" + ref)
		_expect("clicking it again puts it away",
				_doc.get_parsed_text().contains("Ed(\""), false)

	# A failed check, then the offer that follows it unprompted.
	_panel.select(a.id)
	_campaign.apply_event("task_checked", {"id": a.id, "failed": 3, "cases": 4})
	_panel.refresh()
	_expect_in("a failed check says how many cases", _doc.get_parsed_text(),
			_panel._t("failed") % [3, 4, 1])
	_expect("the campaign offers the first hint",
			_campaign.should_offer_hint(a.id), true)
	_campaign.mark_hint_offered(a.id)
	_panel.offer_hint(a.id)
	_expect_in("the offer is in the document", _doc.get_parsed_text(),
			_panel._t("offer"))

	# Taking it asks for hint 1 and takes the offer away.
	_panel._on_meta_clicked("hint:1")
	_expect("the offer asked for hint 1", asked, ["hint:%s:1" % a.id] as Array[String])
	_expect("the offer is spent", _doc.get_parsed_text().contains(_panel._t("offer")), false)

	# And the hint the guest answers with is shown.
	_campaign.apply_event("hint_asked", {"id": a.id, "level": 1})
	_panel.refresh()
	_expect_in("the hint is shown", _doc.get_parsed_text(), _panel._t("hint_n") % 1)
	var hints: Array = a.hints(_panel.lang)
	if not hints.is_empty():
		_expect_in("the hint's own text is shown", _doc.get_parsed_text(),
				(hints[0] as String).substr(0, 24).replace("—", "─"))

	asked.clear()
	_panel._btn_check.emit_signal("pressed")
	_expect("the check button asks for the selected task", asked,
			["check:" + a.id] as Array[String])

	# Read it. A document that passes every assertion above and still reads
	# badly is the failure this cannot check for, so print it and look.
	var was: String = _panel.lang
	for lang in ["ru", "en"]:
		_panel.lang = lang
		_panel._open[b.chapter] = true
		_panel.refresh()
		print("\na failed task with a hint taken, in %s:" % lang)
		for line in _doc.get_parsed_text().split("\n"):
			print("  |%s" % line)
	_panel.lang = was
	_panel.refresh()


## Every label has to fit the button it is on, in both languages, or it clips.
func _check_buttons() -> void:
	print("\nbuttons")
	var was: String = _panel.lang
	for lang in ["ru", "en"]:
		_panel.lang = lang
		_panel.refresh()
		for b: Button in [_panel._btn_hint, _panel._btn_solution, _panel._btn_check]:
			# The row is 256 pixels less two cells of separation, halved: 120,
			# which is fifteen cells, less one cell of border either side.
			var cells := 30 if b == _panel._btn_check else 13
			print("  %-4s %-12s %2d of %d cell(s)"
					% [lang, b.text, b.text.length(), cells])
			if b.text.length() > cells:
				_failures.append("%s: \"%s\" is %d characters and the button "
						% [lang, b.text, b.text.length()]
						+ "holds %d" % cells)
	_panel.lang = was
	_panel.refresh()

	# And the panel still cannot widen, whatever any of them said.
	_expect("the panel is still 34 cells",
			_panel.get_combined_minimum_size().x, 272.0)


## Everything inside the window is a whole number of cells, on the cell grid.
##
## The guest beside it is a grid of 8x8 cells and the whole canvas is magnified
## by a whole number, so a control that starts on an odd pixel puts every glyph
## in it half a cell away from the guest's for the rest of the column.
func _check_grid() -> void:
	print("\ngrid")
	for c: Control in [_doc, _panel._btn_hint, _panel._btn_solution,
			_panel._btn_check]:
		print("  %-10s %s at %s" % [c.name, c.size, c.global_position])
		_expect("%s is a whole number of cells" % c.name,
				Vector2(fmod(c.size.x, 8.0), fmod(c.size.y, 8.0)), Vector2.ZERO)
		_expect("%s sits on the cell grid" % c.name,
				Vector2(fmod(c.global_position.x, 8.0),
						fmod(c.global_position.y, 8.0)), Vector2.ZERO)


## The end of it. Runs last, because it marks every task passed.
func _check_complete() -> void:
	for t: Campaign.Task in _campaign.tasks:
		_campaign.apply_event("task_done", {"id": t.id})
	_expect("the campaign is complete", _campaign.complete, true)
	_expect("and self-taught, since no solution was opened",
			_campaign.self_taught, true)
	# Rebound rather than refreshed, because binding a finished campaign is
	# what happens on the next launch and it has nothing unfinished to open on.
	_panel.bind(_campaign)
	var text := _doc.get_parsed_text()
	print("\nfinished:")
	for line in text.split("\n"):
		print("  |%s" % line)
	_expect_in("the campaign says so", text, _panel._t("done"))
	_expect_in("and says the achievement was kept", text, _panel._t("solo"))
	_expect_in("and still opens on a task", text,
			(_campaign.tasks[0] as Campaign.Task).title(_panel.lang))
	_expect_in("with everything counted", text,
			_panel._t("tasks") % [_campaign.tasks.size(), _campaign.tasks.size()])
