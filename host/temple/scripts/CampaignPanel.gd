extends PanelContainer
class_name CampaignPanel

## The campaign, written as a DolDoc.
##
## It draws what Campaign decides and holds no rules of its own. What it does
## hold is a decision about form: the campaign is not a form with a list widget
## and a detail pane, it is a document. TempleOS has one way of showing a
## structured thing - a stream of text with commands in it - and everything the
## player clicks in that operating system is a word in a document that happened
## to be a link, a macro or a tree. So the body of this panel is one document,
## composed as DolDoc source and translated to what a RichTextLabel understands
## by _doldoc below. The three buttons stay real buttons because a $BT,"..."$
## is a real button in a DolDoc too (Adam/DolDoc/DocRecalc.HC:1050-1052), and
## theme/temple.tres already dresses them as one.
##
## Writing the content as DolDoc rather than as colour calls buys two things.
## The commands are the OS's own, so a reader who knows TempleOS knows what
## $LK$ and $TR$ will look like without reading this file; and the strings
## would print inside the guest unchanged, which is where the task briefs
## already live (guest/Game/GameInit.HC:32 writes the same escapes).
##
## WHAT THE DOCUMENT SAYS, AND WHY IN THOSE COLOURS
##
## Nothing here picks a colour because it looks good. Every one is a DolDoc
## define from Kernel/KernelA.HH:1138-1155 or a use the OS makes of it:
##
##   the document's own text   BLACK on a WHITE ground - DOC_ATTR_DFT_TEXT,
##                             KernelA.HH:1138, set on every new doc at
##                             DocNew.HC:294. Not the same as the window body,
##                             which is BLUE on WHITE (KTask.HC:222): text a
##                             task prints and text a document lays down are
##                             different colours, and both appear in one
##                             TempleOS frame.
##   a task's title            DOC_COLOR_LINK, RED and underlined (:1140 with
##                             the +UL default at DocInit.HC:29)
##   a chapter                 DOC_COLOR_TREE, PURPLE and underlined, with the
##                             literal "-] " or "+] " prefix DolDoc gives a
##                             tree (:1143, DocRecalc.HC:517-544). Chapters
##                             start collapsed because +C is a tree's default
##                             (DocInit.HC:30) - all but the one holding the
##                             task in hand, which would be an odd way to open
##                             a campaign.
##   the hint offer            DOC_COLOR_MACRO, LTBLUE and underlined (:1141).
##                             A macro is the OS's word for text that does
##                             something when clicked, which is what it is.
##   a failed check            RED, which is what this OS prints failures in -
##                             Adam/Opt/Utils/LinkChk.HC:30 " Doc Error",
##                             Adam/Opt/Utils/Diff.HC:300, ACFill.HC:157.
##   a passed task             GREEN, the prompt and comment colour (:1144,
##                             :1145), used as the affirmative in the OS's own
##                             colour key at Apps/Psalmody/JukeBox.HC:127.
##   a task under way          BROWN, which is the colour the wallpaper prints
##                             one line per running task in
##                             (Adam/WallPaper.HC:76).
##   anything secondary        DOC_COLOR_ALT_TEXT, LTGRAY (:1139).
##   the selected row          no colour of its own. Selection is the row's own
##                             attribute complemented - ATTRF_SEL,
##                             KernelA.HH:895, acted on at GrScrn.HC:225-226 as
##                             `cur_ch.u8[1]^0xFF`. On the document's WHITE and
##                             BLACK that lands on BLACK and WHITE; on a link's
##                             RED it lands on LTCYAN. Which is the point: it
##                             stays right whatever the row is made of.
##
## Marks are characters as well as colours, because that is how this OS marks
## things - "[X]" and "[ ]" are what a DolDoc check box renders as
## (DocRecalc.HC:517-544), and a task's four states are those two characters in
## four colours: passed GREEN [X], failing RED [ ], opened BROWN [ ], untouched
## plain [ ].
##
## RUSSIAN
##
## The 8x8 font in theme/ has no Cyrillic in it, but the kernel does: it
## carries two fonts and swaps them on CTRL-ALT-F (Kernel/KMain.HC:67-68,
## Kernel/KeyDev.HC:148-151). So Russian here is Kernel/FontCyrillic.HC, pulled
## out by tools/extract_font.py and named as a fallback on the std font, and
## nothing in this file has to know which font a letter came from.
##
## Two consequences worth stating rather than discovering. Russian comes out
## visibly lighter than English, because Terry's Latin letters are two-pixel
## strokes and the Cyrillic ones are single-pixel strokes five columns wide;
## that is not a bug in the extraction, it is what a TempleOS screen looks like
## after CTRL-ALT-F, and a word like "Простое" mixes the two weights because о,
## р, с and т are drawn by the ASCII cells and П and е are not. And the aux
## font is the one part of the OS Terry did not own - Doc/Credits.DD:7 says it
## was taken from OrientDisplay without permission - which is a question for a
## person before this ships, not for a panel.
##
## THE WINDOW IT IS DRAWN AS
##
## This panel sits an inch from a real TempleOS screen, so it is drawn as one
## of that screen's windows. Most of that is theme/temple.tres. Three things
## cannot be a theme and are done here instead:
##
##   - the title. TempleOS has no title bar. The top row of the border ring IS
##     the title, drawn as a DolDoc border doc with the title field centred and
##     inverted (Adam/DolDoc/DocTerm.HC:28-35, `$CM+H+TY+NC,0,-1$` then a
##     `+CX+IV` data field). The real one marquee-scrolls at 8 characters a
##     second (Adam/DolDoc/DocRecalc.HC:546-553); ours does not, because a
##     sidebar that never stops moving is a different thing from an OS demo.
##
##   - the four-character description down the left border column. A terminal
##     window reads "Term" down its left edge; this one reads "Task".
##     Adam/DolDoc/DocRecalcLib.HC:43-71 walks the doc's `desc` upward from row
##     StrLen-1 to row 0 at column -1, so it lands on the first four rows of
##     the client area, reading downward. It overwrites the border glyph in
##     those cells, which is why the paper is painted before the letter.
##
##   - which ring to use. Adam/Gr/GrScrn.HC:25-26 passes `task==sys_focus_task`
##     to TextBorder and that decides single line or double line. The
##     launcher's equivalent of the focus task is whether the focus owner is
##     one of this panel's controls - if it is not, the player has clicked into
##     the guest and the keyboard has gone with them.
##
## Everything is on the 8-pixel cell grid, because the guest beside it is.

signal check_requested(task_id: String)
signal hint_requested(task_id: String, level: int)
## A command the player asked to have written for them. The launcher types it
## into the guest a character at a time, which is the difference between being
## handed an answer and being shown one.
signal type_requested(text: String)
## Something that changes the machine rather than the campaign: put a task's
## file back, put all of them back, or restart. Each is asked about first,
## because each throws away work the player may not have meant to lose.
signal machine_requested(what: String, task_id: String)

## Which language the campaign is read in. Russian by default: it is the
## author's language, and the tasks are written in it first.
@export_enum("ru", "en") var lang := "ru"

## The window's four-character description, written down the left border
## column. Four characters because TempleOS packs it into a U64 and reads it
## back a byte at a time (Adam/DolDoc/DocRecalcLib.HC:59-66). It stays "Task"
## in both languages: a desc is a device code, not prose, and the OS's own are
## "Term" and "Ed".
const DESC := "Task"

## The cell, in pixels. Kernel/KernelA.HH:3551-3552 FONT_WIDTH, FONT_HEIGHT.
## The same font with every glyph's last scanline filled, which is how the OS
## underlines. See _run().
const UNDERLINED_FONT := "res://theme/font_std_u.fnt"

const CELL := 8

## The status line's right-hand field is filled by whoever is in this group.
## Adam/WallPaper.HC:114 right-justifies its own last field in 18 columns.
const STATUS_PROGRESS_GROUP := "status_progress"

## Hints 1 and 2 are hints; 3 is the whole solution and has its own button.
const HINT_SOLUTION := 3

## The DolDoc colour defines, by name. Kernel/KernelA.HH:1138-1155. Names
## rather than numbers so they resolve through TemplePalette.NAMES, which is
## the OS's own list (Kernel/KDefine.HC:115-117) - LTGRAY with an A, and no
## second copy of the sixteen anywhere in this file.
const COLOR_LINK := "RED"        # DOC_COLOR_LINK, :1140
const COLOR_MACRO := "LTBLUE"    # DOC_COLOR_MACRO, :1141
const COLOR_TREE := "PURPLE"     # DOC_COLOR_TREE, :1143
const COLOR_ALT := "LTGRAY"      # DOC_COLOR_ALT_TEXT, :1139
const COLOR_STR := "BROWN"       # DOC_COLOR_STR, :1147
const COLOR_FUN := "PURPLE"      # DOC_COLOR_FUN, :1153

var campaign: Campaign

var _doc: RichTextLabel
var _btn_hint: Button
var _btn_solution: Button
var _btn_check: Button

var _selected := ""
## Chapter number -> true while its tree branch is open.
var _open: Dictionary = {}
## The task the unprompted hint offer is currently showing for, if any.
var _offered := ""
## The reference whose "open it with this" line is showing, if any.
var _shown_ref := ""

## The compiler message the guest last printed, and the catalogue entry for it.
##
## Kept here rather than in a window of its own because the panel is already
## beside the terminal the message appeared in, and a beginner reading an error
## should not have to look in a third place. Cleared by the player, or by the
## next message - never on a timer, since the whole point is that it stays put
## while they read it.
var _err_raw := ""
var _err: Dictionary = {}

## Which machine action is waiting to be confirmed, if any. One click arms it
## and a second one does it - there is no dialog, because a dialog over a
## picture of another operating system looks like the other operating system
## put it there.
var _confirm := ""


func _ready() -> void:
	_build()
	get_viewport().gui_focus_changed.connect(_on_focus_changed)


## What is inside the window: one document and three buttons.
##
## Made here rather than in a scene of its own. The document's shape is decided
## a line at a time in _lines(), so a .tscn holding two containers around a
## RichTextLabel would say less than this does and would be a second place for
## the panel's structure to live.
func _build() -> void:
	var root := VBoxContainer.new()
	root.name = "Root"
	add_child(root)

	_doc = RichTextLabel.new()
	_doc.name = "Doc"
	_doc.bbcode_enabled = true
	# The document scrolls rather than growing. A third hint in Russian is
	# several times the height of the panel, and with fit_content on it would
	# push the buttons off the bottom of something that cannot get taller. The
	# scrollbar is already dressed for it: temple.tres draws the grabber as the
	# 8x8 square TempleOS slides along a window's border ring
	# (Adam/Ctrls/CtrlsA.HC:106-123).
	_doc.fit_content = false
	_doc.scroll_active = true
	# The underline on links, macros and trees is emitted by _doldoc, so Godot
	# must not add a second one of its own under every [url].
	_doc.meta_underlined = false
	_doc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# A document's default text, which is not the window body's. See the note
	# at the top: DOC_ATTR_DFT_TEXT is WHITE<<4+BLACK (KernelA.HH:1138) while a
	# task prints in WHITE<<4+BLUE (KTask.HC:222), and the theme sets the
	# second because most Labels in the launcher are the task talking.
	_doc.add_theme_color_override("default_color", TemplePalette.DOC_TEXT_FG)
	_doc.meta_clicked.connect(_on_meta_clicked)
	root.add_child(_doc)

	# Nothing is done here about underline metrics, and an earlier version that
	# tried was worse than doing nothing. See _run() for what replaced it.

	# Two rows rather than three across. Thirty-two columns will not hold
	# "Подсказка 1", "Решение" and "Проверить" side by side, and the check is
	# the one the player reaches for, so it gets a row.
	var top := HBoxContainer.new()
	top.name = "Buttons"
	# Two cells between them, not one: 256 pixels less one cell is 248, which
	# is fifteen and a half cells each, and half a cell of button is how a
	# panel stops sitting on the grid.
	top.add_theme_constant_override("separation", CELL * 2)
	root.add_child(top)

	_btn_hint = _button("Hint", _t("btn_hint") % 1)
	top.add_child(_btn_hint)
	_btn_solution = _button("Solution", _t("btn_solution"))
	top.add_child(_btn_solution)

	_btn_check = _button("Check", _t("btn_check"))
	root.add_child(_btn_check)

	_btn_check.pressed.connect(func() -> void:
		if _selected != "":
			check_requested.emit(_selected))
	_btn_hint.pressed.connect(func() -> void: _ask_hint(_next_hint_level()))
	# The solution is a plain button next to the others, not something hidden
	# behind a warning. Reading it costs a single campaign-wide achievement and
	# nothing else, and pretending otherwise would only make people feel bad
	# for being stuck.
	_btn_solution.pressed.connect(func() -> void: _ask_hint(HINT_SOLUTION))


func _button(node_name: String, text: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	# Clipped, and expanding to share the row equally, so a longer label can
	# only ever lose its own ends. It can never widen the panel, and the panel's
	# width is what decides where the guest's left edge is - see scenes/
	# Main.tscn. A control that grows with its own text drags that edge
	# sideways mid-session, which is the picture moving under the player's hand.
	b.clip_text = true
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(Sound.ui_click)
	return b


func bind(c: Campaign) -> void:
	campaign = c
	# The task in hand, or the first one when there is nothing left to finish -
	# a completed campaign should still open on something to read rather than
	# on an empty pane.
	var first := campaign.next_unfinished()
	if first == null and not campaign.tasks.is_empty():
		first = campaign.tasks[0]
	if first != null:
		select(first.id)
	else:
		refresh()


func refresh() -> void:
	if campaign == null:
		return
	# bind() can arrive before the tree is ready - Main builds the campaign in
	# its own _ready - and then none of these nodes exist yet. _ready calls
	# refresh() again once they do.
	if _doc == null:
		return
	_doc.text = _render()
	_btn_hint.text = _t("btn_hint") % _next_hint_level()
	_btn_solution.text = _t("btn_solution")
	_btn_check.text = _t("btn_check")
	_btn_hint.disabled = _selected == "" or _next_hint_level() >= HINT_SOLUTION
	_btn_solution.disabled = _selected == ""
	_btn_check.disabled = _selected == ""
	# The desktop's status line carries the same count in its right-hand field.
	# Sent by group rather than by node path so this panel does not have to
	# know where the launcher put its status line.
	get_tree().call_group(STATUS_PROGRESS_GROUP, "set_text",
			"%d/%d" % [campaign.passed_count(), campaign.tasks.size()])
	queue_redraw()


func select(task_id: String) -> void:
	if campaign == null or not campaign.by_id.has(task_id):
		return
	if task_id != _selected:
		# Both of these belong to the task that was showing, not to this one.
		_offered = ""
		_shown_ref = ""
	_selected = task_id
	# Open the chapter the task is in. A tree starts collapsed by default
	# (Adam/DolDoc/DocInit.HC:30, "TR+TR+C+CA+UL+T"), which is right for the
	# chapters the player is not in the middle of and wrong for the one they
	# are.
	_open[(campaign.by_id[task_id] as Campaign.Task).chapter] = true
	refresh()


## Called when the player has just failed and has not been offered help yet.
## Campaign.should_offer_hint decides when; this only presents it.
func offer_hint(task_id: String) -> void:
	if task_id != _selected:
		select(task_id)
	_offered = task_id
	refresh()


# ---------------------------------------------------------------------------
# The document.

## Every line of it, as DolDoc source, in order.
##
## A line is a dictionary of the source and whether the row is selected,
## because selection is not a DolDoc command - it is bit 30 of every cell in
## the row (Doc/TextBase.DD) and the renderer, not the markup, applies it.
func _lines() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append_array(_error_lines())
	if campaign == null:
		return out

	# The heading bar, with the count in it. Inverted rather than ruled off,
	# the way the OS emphasises without a second font: $IV,1$ swaps the two
	# attribute nibbles (Adam/Gr/GrScrn.HC:227-228). There is no bold in
	# TempleOS - one font, one weight.
	out.append(_line("$IV,1$ %s $IV,0$" % _dd(_t("tasks") % [
			campaign.passed_count(), campaign.tasks.size()])))
	if campaign.complete:
		# The one achievement the campaign keeps for itself. Campaign.
		# self_taught is false the moment any task's hint level reaches the
		# solution, in this session or a previous one - the guest reports it
		# back, so reading the answer in the player's own shell counts too.
		var done := _t("done")
		if campaign.self_taught:
			done += " " + _t("solo")
		out.append(_line("$GREEN$%s$FG$" % _dd(done)))
	out.append(_line(""))

	# NAN so that the first task always opens a branch: it compares equal to
	# nothing, including itself.
	var chapter := NAN
	for t: Campaign.Task in campaign.tasks:
		if t.chapter != chapter:
			chapter = t.chapter
			var open: bool = _open.get(chapter, false)
			# The branch carries its chapter's own count, because a collapsed
			# branch is otherwise the one place in the panel where a task's
			# state is not visible at all.
			out.append(_line("$TR%s,\"%s\",A=\"ch:%s\"$" % [
					"" if open else "+C",
					_ddq("%s  %s" % [_chapter(chapter), _count(chapter)]),
					chapter]))
		if _open.get(t.chapter, false):
			out.append(_line("  %s $LK,\"%s\",A=\"task:%s\"$" % [
					_mark(t), _ddq(t.title(lang)), t.id], t.id == _selected))

	out.append(_line(""))
	if _selected == "" or not campaign.by_id.has(_selected):
		out.append(_line("$%s$%s$FG$" % [COLOR_ALT, _dd(_t("pick"))]))
		return out

	var t: Campaign.Task = campaign.by_id[_selected]
	out.append(_line("$IV,1$ %s $IV,0$" % _dd(t.title(lang))))
	out.append(_line(_dd(_t("edit") % t.start_file)))
	out.append(_line("  " + _call("Ed", t.start_file)))
	var state := _state(t)
	if state != "":
		out.append(_line(state))

	# A printing task is checked in the player's own shell: capturing output
	# needs a terminal and the bridge pump is not one. Said here rather than on
	# the Check button, where it used to make the button - and with it the
	# panel, and with that the guest's left edge - move as tasks were selected.
	if t.kind == "stdout":
		out.append(_line(_dd(_t("check_here"))))
		out.append(_line("  " + _call("TaskCheck", t.id)))

	# The references, as links, because that is what a path to a document is in
	# a DolDoc. Clicking one cannot open it: there is no bridge command for
	# "show me this document" and the panel has no bridge to send one down if
	# there were. So the one thing a click can honestly do is answer the
	# question the player is about to ask, which is what to type in the guest.
	# If BridgeClient ever grows an open_doc, this is the line that becomes a
	# real link.
	if not t.doc_refs.is_empty():
		out.append(_line(""))
		out.append(_line(_dd(_t("refs"))))
		for ref: String in t.doc_refs:
			out.append(_line("  $LK,\"%s\",A=\"doc:%s\"$" % [_ddq(ref), ref]))
			if _shown_ref == ref:
				out.append(_line("    " + _call("Ed", ref)))

	if _offered == t.id and t.status != Campaign.Status.PASSED:
		out.append(_line(""))
		out.append(_line("$MA,\"%s\",A=\"hint:1\"$" % _ddq(_t("offer"))))

	var hints := t.hints(lang)
	if t.hint_level > 0 and t.hint_level <= hints.size():
		out.append(_line(""))
		out.append(_line("$IV,1$ %s $IV,0$" % _dd(_t("hint_n") % t.hint_level)))
		out.append(_line(_dd(hints[t.hint_level - 1])))

	out.append_array(_machine_lines())
	return out


## Undo, at three sizes.
##
## The reason this exists at all: TempleOS has no undo across a save and no bin
## to fish a file back out of, so one wrong keystroke on the fourth task ruins
## it and there is nothing to be done. That is an excellent reason never to
## touch anything, which is the opposite of what this game wants.
func _machine_lines() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append(_line(""))
	out.append(_line("$IV,1$ %s $IV,0$" % _dd(_t("machine"))))
	for what: String in ["task", "home", "reboot"]:
		if what == "task" and _selected == "":
			continue
		if _confirm == what:
			out.append(_line("  %s $LK,\"%s\",A=\"do:%s\"$  $LK,\"%s\",A=\"no:\"$"
					% [_dd(_t("sure")), _ddq(_t("yes")), what, _ddq(_t("no"))]))
		else:
			out.append(_line("  $LK,\"%s\",A=\"mach:%s\"$"
					% [_ddq(_t("mach_" + what)), what]))
	return out


## What the compiler just said, and what it means, above everything else.
##
## The original message is repeated here in the colour the guest printed it in,
## so the two can be matched by eye - the explanation is an annotation and the
## player should always be able to see which line it is annotating.
func _error_lines() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _err_raw == "":
		return out

	out.append(_line("$IV,1$ %s $IV,0$" % _dd(_t("err_head"))))
	out.append(_line("$LTRED$%s$FG$" % _dd(_err_raw)))
	if _err.is_empty():
		# Not in the catalogue. Say so rather than saying nothing: a blank
		# where an explanation usually is reads as "this one is your fault".
		out.append(_line("$%s$%s$FG$" % [COLOR_ALT, _dd(_t("err_unknown"))]))
	else:
		var explain := ErrorBook.say(_err, "explain", lang)
		var cause := ErrorBook.say(_err, "common_cause", lang)
		if explain != "":
			out.append(_line(_dd(explain)))
		if cause != "":
			out.append(_line(""))
			out.append(_line("$%s$%s$FG$ %s" % [COLOR_MACRO, _dd(_t("err_cause")),
					_dd(cause)]))
	out.append(_line("$LK,\"%s\",A=\"err:hide\"$" % _dd(_t("err_hide"))))
	out.append(_line(""))
	return out


func _line(src: String, selected := false) -> Dictionary:
	return {"src": src, "sel": selected}


func _render() -> String:
	var out := PackedStringArray()
	for l: Dictionary in _lines():
		out.append(_doldoc(l["src"], l["sel"]))
	return "\n".join(out)


## A task's state, as one line.
func _state(t: Campaign.Task) -> String:
	if t.status == Campaign.Status.PASSED:
		return "$GREEN$%s$FG$" % _dd(_t("passed"))
	if t.last_failed > 0:
		return "$%s$%s$FG$" % [COLOR_LINK,
				_dd(_t("failed") % [t.last_failed, t.last_cases, t.attempts])]
	if t.attempts > 0:
		return "$%s$%s$FG$" % [COLOR_STR, _dd(_t("attempt") % t.attempts)]
	if t.est_minutes > 0:
		return "$%s$%s$FG$" % [COLOR_ALT, _dd(_t("minutes") % t.est_minutes)]
	return ""


## The check box, in the colour of the state it is in. See the note at the top.
func _mark(t: Campaign.Task) -> String:
	if t.status == Campaign.Status.PASSED:
		return "$GREEN$[X]$FG$"
	if t.last_failed > 0:
		return "$%s$[ ]$FG$" % COLOR_LINK
	if t.status == Campaign.Status.ATTEMPTED:
		return "$%s$[ ]$FG$" % COLOR_STR
	return "[ ]"


## One line of HolyC to type in the guest, coloured the way the guest's own
## syntax highlighter would colour it: the function PURPLE, the string BROWN
## (Kernel/KernelA.HH:1147,1153, applied at Adam/DolDoc/DocRecalc.HC:231-243).
func _call(fn: String, arg: String) -> String:
	# Coloured the way the guest's own highlighter would colour it, and clickable
	# rather than only readable. The panel used to say, in a comment right here,
	# that the one honest thing a click could do was answer the question the
	# player was about to ask - what do I type. The launcher can type it now.
	var code := "%s(\"%s\");" % [fn, arg]
	return "$LK,\"%s\",A=\"type:%s\"$" % [_ddq(code), code]


## How many of one chapter's tasks have passed.
func _count(c: float) -> String:
	var passed := 0
	var total := 0
	for t: Campaign.Task in campaign.tasks:
		if t.chapter == c:
			total += 1
			if t.status == Campaign.Status.PASSED:
				passed += 1
	return "%d/%d" % [passed, total]


func _chapter(c: float) -> String:
	# Chapter 1.5 is a real chapter in the campaign, so this cannot be an int.
	var n := "%d" % int(c) if c == floor(c) else str(c)
	return _t("chapter") % n


## Show what the guest's compiler just printed, with the catalogue's entry for
## it when there is one.
func show_compiler_error(raw: String, entry: Dictionary) -> void:
	_err_raw = raw
	_err = entry
	refresh()


func _next_hint_level() -> int:
	if _selected == "" or not campaign.by_id.has(_selected):
		return 1
	return mini((campaign.by_id[_selected] as Campaign.Task).hint_level + 1,
			HINT_SOLUTION)


func _ask_hint(level: int) -> void:
	if _selected == "":
		return
	# The offer is spent whether or not the guest ever answers. It came from
	# Campaign.should_offer_hint, which only ever says yes once.
	_offered = ""
	refresh()
	hint_requested.emit(_selected, level)


func _on_meta_clicked(meta: Variant) -> void:
	Sound.ui_click()
	var s := str(meta)
	var kind := s.get_slice(":", 0)
	var rest := s.substr(kind.length() + 1)
	match kind:
		"task":
			select(rest)
		"ch":
			var c := rest.to_float()
			_open[c] = not _open.get(c, false)
			refresh()
		"doc":
			_shown_ref = "" if _shown_ref == rest else rest
			refresh()
		"hint":
			_ask_hint(maxi(1, rest.to_int()))
		"err":
			_err_raw = ""
			_err = {}
			refresh()
		"type":
			type_requested.emit(rest)
		"mach":
			_confirm = rest
			refresh()
		"do":
			_confirm = ""
			machine_requested.emit(rest, _selected)
			refresh()
		"no":
			_confirm = ""
			refresh()


# ---------------------------------------------------------------------------
# DolDoc.

## Translate one line of DolDoc source into BBCode.
##
## Not a DolDoc parser - a translator for the subset this panel writes, which
## is worth being exact about so nobody assumes more of it:
##
##   $$                    one literal dollar (Adam/DolDoc/DocPutS.HC:85-106)
##   $FG,n$ $FG$           foreground to colour n, or back to the default
##   $BG,n$ $BG$           background, the same way
##   $RED$ ... $FG$        a bare colour name is a foreground change
##                         (Adam/DolDoc/DocPlain.HC:228-234)
##   $UL,1$ $UL,0$         underline on and off
##   $IV,1$ $IV,0$         invert: swap the two attribute nibbles
##   $LK,"text",A="meta"$  link, RED and underlined
##   $MA,"text",A="meta"$  macro, LTBLUE and underlined
##   $TR[+C],"text",A=..$  tree branch, PURPLE and underlined, prefixed "-] "
##                         or, with +C, "+] " (Adam/DolDoc/DocRecalc.HC:517-544)
##
## Colour arguments take a name or a number. Every other command, flag and
## argument DolDoc has is not here; an unknown one is printed rather than
## swallowed, so a typo shows up in the panel instead of quietly losing a line.
##
## `selected` is not a command because selection is not markup: it is bit 30 of
## every cell in the row, and the renderer complements the whole attribute byte
## (Doc/TextBase.DD, Adam/Gr/GrScrn.HC:225-226). Applied here per run, before
## the invert, in the order GrScrn does it - :225 sel, then :227 invert.
func _doldoc(src: String, selected: bool) -> String:
	var bg := (TemplePalette.ATTR_DOC_TEXT >> 4) & 0xF
	var fg := TemplePalette.ATTR_DOC_TEXT & 0xF
	var dft_fg := fg
	var dft_bg := bg
	var ul := false
	var iv := false

	var out := ""
	var run := ""
	var i := 0
	while i < src.length():
		if src[i] != "$":
			run += src[i]
			i += 1
			continue
		var end := _command_end(src, i + 1)
		if end < 0:
			# Unterminated. Print what is there; losing the rest of a line
			# silently is how a missing dollar becomes a mystery.
			run += src.substr(i)
			break
		out += _run(run, bg, fg, ul, iv, selected)
		run = ""
		var body := src.substr(i + 1, end - i - 1)
		i = end + 1

		if body == "":
			run += "$"
			continue
		# NAME[+FLAG|-FLAG...][,arg,ARG=expr...] - the shape every DolDoc
		# command has (Adam/DolDoc/DocPlain.HC:217-).
		var comma := body.find(",")
		var head := body if comma < 0 else body.substr(0, comma)
		var args := _args("" if comma < 0 else body.substr(comma + 1))
		var plus := head.find("+")
		var flags := "" if plus < 0 else head.substr(plus)
		var cmd := head if plus < 0 else head.substr(0, plus)

		match cmd:
			"FG":
				fg = _color(args[0]) if args.size() > 0 else dft_fg
			"BG":
				bg = _color(args[0]) if args.size() > 0 else dft_bg
			"UL":
				ul = args.size() > 0 and args[0] == "1"
			"IV":
				iv = args.size() > 0 and args[0] == "1"
			"LK", "MA", "TR":
				var text: String = _unquote(args[0]) if args.size() > 0 else ""
				var meta := ""
				for a in args:
					if a.strip_edges().begins_with("A="):
						meta = _unquote(a.strip_edges().substr(2))
				var colour := COLOR_LINK
				if cmd == "MA":
					colour = COLOR_MACRO
				elif cmd == "TR":
					colour = COLOR_TREE
					# The prefix is literal characters in the document, not a
					# glyph and not an icon: '+' or '-', then ']', then a space.
					text = ("+] " if flags.contains("C") else "-] ") + text
				var body_bb := _run(text, bg, _color(colour), true, iv, selected)
				out += body_bb if meta == "" else "[url=%s]%s[/url]" % [meta, body_bb]
			_:
				var named := TemplePalette.NAMES.find(cmd)
				if named >= 0:
					# A bare colour name is a foreground change - the OS's own
					# shorthand, resolved out of the same list of sixteen
					# (Adam/DolDoc/DocPlain.HC:228-234).
					fg = named
				else:
					# Not a command this knows. Show it.
					out += _run("<%s>" % body, bg, _color(COLOR_LINK), false,
							iv, selected)
	out += _run(run, bg, fg, ul, iv, selected)
	return out


## One run of text at one attribute.
func _run(text: String, bg: int, fg: int, ul: bool, iv: bool,
		selected: bool) -> String:
	if text == "":
		return ""
	var attr := TemplePalette.attr(bg, fg)
	if selected:
		attr = TemplePalette.selected(attr)
	if iv:
		attr = TemplePalette.inverted(attr)
	var body := _esc(text)
	if ul:
		# An underlined run is a different font, not a rule drawn over the same
		# one. TempleOS underlines by forcing the glyph's own bottom scanline
		# solid - the high byte of the eight, which is row 7 of the 8x8 cell:
		#
		#     MOV  RBX,0xFF00000000000000
		#     OR   RAX,RBX
		#     Adam/Gr/GrAsm.HC:284-285
		#
		# so the line is inside the character, tight against it, with the row
		# below untouched. A text renderer cannot put it there: it measures
		# from the baseline, which for this font is the bottom edge of the
		# cell, so its underline lands in the next row. Asking for one pixel
		# higher does not work either - Godot clamps a negative underline
		# position to zero and says nothing - and what gets drawn is a
		# half-covered rule straddling two rows in a blended colour this
		# palette does not contain.
		#
		# tools/extract_font.py emits the underlined variant by doing to every
		# glyph exactly what those two instructions do to one. Then an
		# underlined run is just text in another font: one colour, on the grid,
		# with nothing to blend.
		body = "[font=%s]%s[/font]" % [UNDERLINED_FONT, body]
	body = "[color=#%s]%s[/color]" % [TemplePalette.fg(attr).to_html(false), body]
	# Only when it is not the paper the panel is already painted in. A bgcolor
	# run draws a rectangle, and one that repaints white on white is a seam
	# waiting to appear at a rounding boundary.
	if (attr >> 4) & 0xF != (TemplePalette.ATTR_DOC_TEXT >> 4) & 0xF:
		body = "[bgcolor=#%s]%s[/bgcolor]" % [
				TemplePalette.bg(attr).to_html(false), body]
	return body


## A colour argument: a name from the OS's own list, or an index.
func _color(arg: String) -> int:
	var i := TemplePalette.NAMES.find(arg.to_upper())
	return i if i >= 0 else clampi(arg.to_int(), 0, 15)


## Where the command that started at `from` ends: the next '$' that is not
## inside one of its quoted arguments.
##
## Scanned rather than searched for, because a task title is data and can
## contain a dollar. Inside a quoted argument the quote is what delimits, so a
## dollar there is an ordinary character and needs no doubling - which is why
## _ddq does not double it and _dd, for text out in the open, does.
func _command_end(src: String, from: int) -> int:
	var quoted := false
	var escaped := false
	var i := from
	while i < src.length():
		var ch := src[i]
		if escaped:
			escaped = false
		elif ch == "\\":
			escaped = true
		elif ch == "\"":
			quoted = not quoted
		elif ch == "$" and not quoted:
			return i
		i += 1
	return -1


## Split a command's arguments on commas that are not inside quotes.
func _args(rest: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	var quoted := false
	var escaped := false
	for i in rest.length():
		var ch := rest[i]
		if escaped:
			escaped = false
			cur += ch
			continue
		if ch == "\\":
			escaped = true
			cur += ch
			continue
		if ch == "\"":
			quoted = not quoted
		if ch == "," and not quoted:
			out.append(cur)
			cur = ""
			continue
		cur += ch
	if cur != "":
		out.append(cur)
	return out


func _unquote(s: String) -> String:
	var t := s.strip_edges()
	if t.length() >= 2 and t.begins_with("\"") and t.ends_with("\""):
		t = t.substr(1, t.length() - 2)
		return t.replace("\\\"", "\"").replace("\\\\", "\\")
	return t


## Escape a string on its way into a DolDoc stream. One dollar is the
## delimiter, so a dollar in text out in the open has to be doubled - the same
## rule that makes guest/Game/GameInit.HC:32 write "$$LTBLUE$$" for one escape.
func _dd(text: String) -> String:
	return text.replace("$", "$$")


## The same, for a string going into a command's quoted argument.
##
## A quote is what has to be escaped there - an unescaped one ends the argument
## early and takes the rest of the line with it - and a dollar is what does
## not, because inside the quotes it is an ordinary character. Backslash first,
## or the backslashes this adds are doubled by the pass that was meant to
## escape the ones already in the text.
func _ddq(text: String) -> String:
	return text.replace("\\", "\\\\").replace("\"", "\\\"")


## Escape a run on its way out to BBCode, where '[' opens a tag.
##
## The em dash is not an escape but a substitution, and it belongs here because
## the campaign's Russian is full of them. There is no em dash in either
## TempleOS font; the character that draws one is 0xC4, the single horizontal
## rule the frames are made of - a full-width line on row 4 of the cell
## (FontStd.HC 0xC4 == 0x000000FF00000000), which at this size is exactly what
## an em dash is. Written as U+2500 because that is the codepoint the std font
## carries it under, and the std font is the only one of the two that has it -
## in the Cyrillic font 0xC4 is the letter ь.
func _esc(text: String) -> String:
	return text.replace("[", "[lb]").replace("—", "─")


# ---------------------------------------------------------------------------
# Words.

## Everything the panel says, in both languages.
##
## Kept as one table rather than scattered through the document builder so that
## the two languages can be read against each other, and so a string that is
## too long for the button it lands on is obvious. Hint and Solution are
## fifteen cells wide, Check is thirty-two, and all three clip; theme/
## panel_check.gd measures every label against that in both languages.
const TEXT := {
	"title": {"en": "Campaign", "ru": "Кампания"},
	"err_head": {"en": "What that error means", "ru": "Что означает эта ошибка"},
	# Not "Usually:" - the catalogue's own text tends to start with the same
	# word, and the panel read "Usually: Usually a typo".
	"err_cause": {"en": "Where it comes from:", "ru": "Откуда это берётся:"},
	"err_unknown": {"en": "This one is not in the book yet. The message above is "
			+ "the compiler's own and is exact.",
			"ru": "Этого сообщения ещё нет в справочнике. То, что выше, — "
			+ "слова самого компилятора, и они точны."},
	"err_hide": {"en": "hide", "ru": "скрыть"},
	"machine": {"en": "Machine", "ru": "Машина"},
	"mach_task": {"en": "put this task's file back",
			"ru": "вернуть файл этого задания"},
	"mach_home": {"en": "put every task's file back",
			"ru": "вернуть файлы всех заданий"},
	"mach_reboot": {"en": "restart the machine", "ru": "перезапустить машину"},
	"sure": {"en": "sure?", "ru": "точно?"},
	"yes": {"en": "yes", "ru": "да"},
	"no": {"en": "no", "ru": "нет"},
	"type_hint": {"en": "Click a line of code and the machine types it for you.",
			"ru": "Нажмите на строку кода — машина наберёт её за вас."},
	"tasks": {"en": "Tasks %d/%d", "ru": "Задания %d/%d"},
	"chapter": {"en": "Chapter %s", "ru": "Глава %s"},
	"pick": {"en": "Pick a task.", "ru": "Выберите задание."},
	"edit": {"en": "edit %s", "ru": "править %s"},
	"passed": {"en": "passed", "ru": "пройдено"},
	"failed": {"en": "%d of %d cases failed, attempt %d",
			"ru": "не пройдено %d из %d, попытка %d"},
	"attempt": {"en": "attempt %d", "ru": "попытка %d"},
	"minutes": {"en": "about %d minutes", "ru": "около %d минут"},
	"check_here": {"en": "check it in the guest:", "ru": "проверьте в TempleOS:"},
	"refs": {"en": "Reference:", "ru": "Справка:"},
	"offer": {"en": "Stuck? Take the first hint - it costs nothing.",
			"ru": "Застряли? Возьмите подсказку, это ничего не стоит."},
	"hint_n": {"en": "Hint %d", "ru": "Подсказка %d"},
	"done": {"en": "Campaign complete.", "ru": "Кампания пройдена."},
	"solo": {"en": "Not one solution opened.",
			"ru": "Ни одного открытого решения."},
	"btn_hint": {"en": "Hint %d", "ru": "Подсказка %d"},
	"btn_solution": {"en": "Solution", "ru": "Решение"},
	"btn_check": {"en": "Check", "ru": "Проверить"},
}


func _t(key: String) -> String:
	var entry: Dictionary = TEXT[key]
	return entry.get(lang, entry["en"])


# ---------------------------------------------------------------------------
# The window.

## The border ring's two hand-drawn parts: the title and the description.
##
## PanelContainer has already drawn its stylebox by the time this runs, so both
## of these land on top of the ring - which is what they do in the OS as well,
## since TextChar writes the border cell outright.
func _draw() -> void:
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size()
	# The frame's own attribute is 0xF1 for a C: ATA boot disk - WHITE ground,
	# BLUE line (Kernel/KTask.HC:224 through Kernel/BlkDev/DskDrv.HC:318-329,
	# measured on build/shots/B1_booted.png). The title field carries +IV, and
	# inverted means the two nibbles swapped, not complemented: 0xF1 -> 0x1F.
	var paper := TemplePalette.FRAME_BG
	var ink := TemplePalette.FRAME_FG
	var title_attr := TemplePalette.inverted(TemplePalette.ATTR_FRAME_ATA_C)
	var title_paper := TemplePalette.bg(title_attr)
	var title_ink := TemplePalette.fg(title_attr)

	# Padded by a space either side, the way the OS's own title field is padded
	# by the width it was given.
	var title := " %s " % _t("title")
	var w := title.length() * CELL
	# Centred, then dropped onto the cell grid. Half a cell of offset here is
	# the difference between a tribute and an imitation of one.
	var x := int(floor((size.x - w) * 0.5 / CELL)) * CELL
	if w <= size.x:
		draw_rect(Rect2(x, 0, w, CELL), title_paper)
		draw_string(font, Vector2(x, CELL), title,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, title_ink)

	# The description, top to bottom, in the left border column, starting at
	# the first row of the client area.
	for i in DESC.length():
		var y := (1 + i) * CELL
		if y + CELL > size.y:
			break
		draw_rect(Rect2(0, y, CELL, CELL), paper)
		draw_char(font, Vector2(0, y + CELL), DESC[i], fs, ink)


## Single line or double line, exactly as Adam/Gr/GrScrn.HC:25-26 decides it.
func _on_focus_changed(node: Control) -> void:
	var ours := node != null and is_ancestor_of(node)
	theme_type_variation = &"TempleWindowFocused" if ours else &""
