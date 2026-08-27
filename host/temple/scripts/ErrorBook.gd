extends RefCounted
class_name ErrorBook

## The 149 messages the guest's compiler can print, and what each one means.
##
## The catalogue in data/errors/compiler_messages.json was built by reading
## every LexExcept, PrintErr and PrintWarn call site in the compiler, so each
## entry carries the file and line that emits it. What matters here are three
## fields: the raw text the compiler prints, an explanation, and the cause that
## is usually behind it.
##
## The guest sends the message verbatim over the log channel and this side does
## the looking up, for two reasons. The catalogue is 135KB of JSON and the guest
## has no JSON parser; and the explanation belongs beside the original rather
## than on top of it, which means it belongs in the launcher's panel and not in
## the player's terminal. The message TempleOS printed stays exactly as Terry
## wrote it, on the screen where it appeared.
##
## Matching is by prefix, because every message ends in a position the compiler
## fills in - "Undefined identifier at " and then the token, the file and the
## line. Longest variant first, so a specific message is never shadowed by a
## shorter one that happens to start the same way.

const PATH := "res://data/errors/compiler_messages.json"

## Prefix, and the message it belongs to. Sorted longest first.
var _index: Array[Dictionary] = []

## How many messages were read. Zero means the catalogue is missing, which is
## not fatal - an unexplained error still reaches the player unchanged.
var count: int = 0


func load_book(path: String = PATH) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("no compiler message catalogue at " + path)
		return 0
	var doc: Variant = JSON.parse_string(f.get_as_text())
	if typeof(doc) != TYPE_DICTIONARY or not doc.has("messages"):
		push_warning("catalogue at %s is not the expected shape" % path)
		return 0

	for m: Dictionary in doc["messages"]:
		count += 1
		for variant: String in m.get("raw_variants", []):
			var p := variant.strip_edges()
			if p != "":
				_index.append({"prefix": p, "msg": m})
	_index.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["prefix"] as String).length() > (b["prefix"] as String).length())
	return count


## What the guest just printed, explained. An empty dictionary when the message
## is not one of the catalogued ones.
##
## Case is compared exactly. The compiler's strings are literals in its own
## source, so a message that differs in case is a different message, and
## matching loosely would hand the player a confident explanation of something
## else.
func look_up(raw: String) -> Dictionary:
	var text := raw.strip_edges()
	for e: Dictionary in _index:
		if text.begins_with(e["prefix"]):
			return e["msg"]
	return {}


## One field of a message in the player's language, falling back to English.
##
## The Russian text is a translation of the explanation and not of the compiler
## message: the message itself is never translated, because the player has to be
## able to search for it and to recognise it on the screen it is printed on.
static func say(msg: Dictionary, field: String, lang: String) -> String:
	if not msg.has(field):
		return ""
	var entry: Dictionary = msg[field]
	return entry.get(lang, entry.get("en", ""))
