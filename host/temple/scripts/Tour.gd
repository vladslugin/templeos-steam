extends RefCounted
class_name Tour

## The first five minutes.
##
## Somebody who opens this and is met with a blue screen, a white document and a
## prompt that answers `ls` with "Undefined identifier" will close it again, and
## they will be right to: nothing has told them what they are looking at. The
## campaign cannot do that job, because the campaign is already asking them to
## write something.
##
## So: nine short steps, in the panel, next to the machine they are about to
## use. Each is a paragraph and at most one line of code, and the line of code
## is written into the guest for them rather than quoted at them - the launcher
## has been able to do that since it learned to type, and this is what that was
## for.
##
## Two of the nine are deliberately about things going wrong. One runs a
## nonsense line so the player meets a compiler error while nothing is at stake
## and sees this panel explain it; the next points at the undo. Both exist
## because the reason people stop poking at an unfamiliar machine is not that it
## is hard, it is that they are afraid of breaking it.
##
## The text is data (res://data/tour.json), so it can be rewritten, translated
## or reordered without touching the launcher.

const PATH := "res://data/tour.json"

var steps: Array = []
var at := -1


func load_steps(path: String = PATH) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("no tour at " + path)
		return 0
	var doc: Variant = JSON.parse_string(f.get_as_text())
	if typeof(doc) != TYPE_DICTIONARY or not doc.has("steps"):
		push_warning("the tour at %s is not the expected shape" % path)
		return 0
	steps = doc["steps"]
	return steps.size()


func running() -> bool:
	return at >= 0 and at < steps.size()


func start() -> void:
	at = 0 if not steps.is_empty() else -1


func stop() -> void:
	at = -1


func next() -> void:
	if at >= 0:
		at += 1
		if at >= steps.size():
			at = -1


func back() -> void:
	if at > 0:
		at -= 1


func step() -> Dictionary:
	return steps[at] if running() else {}


## How far along, as "3/9", for the heading.
func position() -> String:
	return "%d/%d" % [at + 1, steps.size()] if running() else ""


static func say(s: Dictionary, field: String, lang: String) -> String:
	if not s.has(field):
		return ""
	var entry: Dictionary = s[field]
	return entry.get(lang, entry.get("en", ""))
