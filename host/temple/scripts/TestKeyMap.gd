extends Node

## Keysym mapping, checked without a guest.
##
## These are pure functions, so they get real assertions rather than a live
## round trip. What they are guarding against is a keysym that looks plausible
## and is wrong - the guest would simply do nothing, with no error anywhere.

var _ok := 0
var _bad := 0


func _ready() -> void:
	_check("plain letter", _sym(KEY_A, "a".unicode_at(0)), 0x61)
	_check("capital via unicode", _sym(KEY_A, "A".unicode_at(0), true), 0x41)
	_check("digit", _sym(KEY_7, "7".unicode_at(0)), 0x37)
	_check("space", _sym(KEY_SPACE, " ".unicode_at(0)), 0x20)
	_check("semicolon", _sym(KEY_SEMICOLON, ";".unicode_at(0)), 0x3B)

	# HolyC is full of these and they must survive the trip.
	_check("quote", _sym(KEY_QUOTELEFT, "\"".unicode_at(0)), 0x22)
	_check("brace", _sym(KEY_BRACELEFT, "{".unicode_at(0)), 0x7B)
	_check("asterisk", _sym(KEY_ASTERISK, "*".unicode_at(0)), 0x2A)

	_check("enter", _sym(KEY_ENTER, 0), 0xFF0D)
	_check("escape", _sym(KEY_ESCAPE, 0), 0xFF1B)
	_check("backspace", _sym(KEY_BACKSPACE, 0), 0xFF08)
	_check("up", _sym(KEY_UP, 0), 0xFF52)
	_check("F1", _sym(KEY_F1, 0), 0xFFBE)
	_check("F5", _sym(KEY_F5, 0), 0xFFC2)

	# Ctrl held gives no usable unicode, so the fallback has to catch it -
	# Ctrl-Alt combinations are how the OS kills a runaway task.
	_check("ctrl-c falls back to the key", _sym(KEY_C, 3, false, true), 0x63)

	# A control character on its own is not a keysym and must be refused.
	_check("bare control char refused", _sym(KEY_UNKNOWN, 3), 0)

	var mods := KeyMap.modifiers_for(_ev(KEY_C, 0, false, true, true))
	_check("ctrl+alt both reported", mods.size(), 2)
	_check("ctrl keysym", mods[0], 0xFFE3)

	# A keyboard that is not producing Latin at all.
	#
	# With a Russian layout active Godot reports the character the player would
	# get - D is 1042, ; is 1078 - and none of it is ASCII. The guest is a US
	# machine, so what has to be sent is what a US keyboard has on that physical
	# key. Before this, capitals arrived lower case and punctuation was dropped
	# on the floor: DocClear; reached the guest as docclear.
	_check("cyrillic D is still D", _sym(KEY_D, 1042, true), 0x44)
	_check("cyrillic d is still d", _sym(KEY_D, 1076), 0x64)
	_check("cyrillic key gives ;", _sym(KEY_SEMICOLON, 1078), 0x3B)
	_check("and with shift, :", _sym(KEY_SEMICOLON, 1046, true), 0x3A)
	_check("quote survives", _sym(KEY_APOSTROPHE, 1101), 0x27)
	_check("and shifted, double quote", _sym(KEY_APOSTROPHE, 1069, true), 0x22)
	_check("comma survives", _sym(KEY_COMMA, 1073), 0x2C)
	_check("shifted 5 is percent", _sym(KEY_5, 0, true), 0x25)
	_check("shifted 9 is open paren", _sym(KEY_9, 0, true), 0x28)
	_check("plain 9 is nine", _sym(KEY_9, 0), 0x39)
	_check("backslash survives", _sym(KEY_BACKSLASH, 1100), 0x5C)

	# A physical code that is not filled in must not take over. Every event
	# synthesised through the Windows API arrives with the same value in
	# physical_keycode, and preferring it turned every key into nothing.
	var junk := _ev(KEY_D, 1042, true)
	junk.physical_keycode = 4194313
	_check("a junk physical code is ignored", KeyMap.keysym_for(junk), 0x44)

	_check("F12 releases capture", 1 if KeyMap.is_release_capture(_ev(KEY_F12, 0)) else 0, 1)
	_check("F11 does not", 1 if KeyMap.is_release_capture(_ev(KEY_F11, 0)) else 0, 0)

	# Integer scaling: the author's pixels are never resampled.
	_check("1280x960 fits 2x", GuestView.integer_scale(Vector2(1280, 960), Vector2i(640, 480)), 2)
	_check("1920x1080 fits 2x", GuestView.integer_scale(Vector2(1920, 1080), Vector2i(640, 480)), 2)
	_check("small window still 1x", GuestView.integer_scale(Vector2(320, 200), Vector2i(640, 480)), 1)

	print("\n%d passed, %d failed" % [_ok, _bad])
	get_tree().quit(1 if _bad > 0 else 0)


func _ev(code: Key, uni: int, shift := false, ctrl := false, alt := false) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.unicode = uni
	e.shift_pressed = shift
	e.ctrl_pressed = ctrl
	e.alt_pressed = alt
	e.pressed = true
	return e


func _sym(code: Key, uni: int, shift := false, ctrl := false) -> int:
	return KeyMap.keysym_for(_ev(code, uni, shift, ctrl))


func _check(what: String, got: int, want: int) -> void:
	if got == want:
		_ok += 1
	else:
		_bad += 1
		printerr("FAIL %s: got 0x%X, wanted 0x%X" % [what, got, want])
