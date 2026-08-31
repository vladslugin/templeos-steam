extends RefCounted
class_name KeyMap

## Godot key events to X11 keysyms, which is what RFB carries.
##
## Three paths, in this order:
##
##   1. The event's unicode, when it is printable ASCII. The keysym is then the
##      character code, so this is exact and follows the player's own layout
##      without a table per layout.
##   2. The physical key, through a US layout, when the unicode is something
##      else. This is the case that matters here: with a Russian layout active,
##      Godot reports D as 1042 and ; as 1078, neither of which is ASCII. The
##      old code fell through to a lower-case letter and dropped the punctuation
##      outright, so DocClear; arrived in the guest as docclear and
##      Print("x: %d\n",6*7); as print(x %d\n6*7). Everybody this game is aimed
##      at has that layout installed.
##   3. A table, for everything with no character at all - arrows, function
##      keys, modifiers.
##
## The guest is a US-layout machine and the emulator turns a keysym back into a
## scan code, so what has to be sent is the character a US keyboard would give
## for that physical key. Which is why path 2 is a US table and not a Russian
## one: it is describing the guest's keyboard, not the player's.
##
## F12 is the key that gives the keyboard back to the launcher. It is free to
## take: TempleOS defines a scan code for it (Kernel/KernelA.HH:3528) and the
## keyboard driver knows its name, but nothing binds it - the editor's function
## key handler covers SC_F1 through SC_F10 only (Adam/DolDoc/DocPutKey.HC:215).
## F11 is free as well, if this ever needs a second one.

const RELEASE_CAPTURE_KEY := KEY_F12

# X11 keysym values. The high ones are from keysymdef.h.
const KS := {
	KEY_BACKSPACE: 0xFF08,
	KEY_TAB:       0xFF09,
	KEY_ENTER:     0xFF0D,
	KEY_KP_ENTER:  0xFF8D,
	KEY_ESCAPE:    0xFF1B,
	KEY_INSERT:    0xFF63,
	KEY_DELETE:    0xFFFF,
	KEY_HOME:      0xFF50,
	KEY_END:       0xFF57,
	KEY_PAGEUP:    0xFF55,
	KEY_PAGEDOWN:  0xFF56,
	KEY_LEFT:      0xFF51,
	KEY_UP:        0xFF52,
	KEY_RIGHT:     0xFF53,
	KEY_DOWN:      0xFF54,

	KEY_F1:  0xFFBE, KEY_F2:  0xFFBF, KEY_F3:  0xFFC0, KEY_F4:  0xFFC1,
	KEY_F5:  0xFFC2, KEY_F6:  0xFFC3, KEY_F7:  0xFFC4, KEY_F8:  0xFFC5,
	KEY_F9:  0xFFC6, KEY_F10: 0xFFC7, KEY_F11: 0xFFC8, KEY_F12: 0xFFC9,

	KEY_SHIFT: 0xFFE1,
	KEY_CTRL:  0xFFE3,
	KEY_ALT:   0xFFE9,
	KEY_META:  0xFFEB,
	KEY_CAPSLOCK: 0xFFE5,
}


## What a US keyboard has on each key, plain and with shift.
##
## Letters and digits are worked out rather than listed; these are the rest.
## Needed because a physical key is all there is to go on once the player's
## layout stops producing ASCII.
const US := {
	KEY_SEMICOLON:    [";", ":"],
	KEY_APOSTROPHE:   ["'", "\""],
	KEY_COMMA:        [",", "<"],
	KEY_PERIOD:       [".", ">"],
	KEY_SLASH:        ["/", "?"],
	KEY_MINUS:        ["-", "_"],
	KEY_EQUAL:        ["=", "+"],
	KEY_BRACKETLEFT:  ["[", "{"],
	KEY_BRACKETRIGHT: ["]", "}"],
	KEY_BACKSLASH:    ["\\", "|"],
	KEY_QUOTELEFT:    ["`", "~"],
	KEY_SPACE:        [" ", " "],
}

## The digits row with shift held, in order 0 to 9.
const US_DIGITS_SHIFTED := ")!@#$%^&*("


## The keysym for an event, or 0 if there is nothing sensible to send.
static func keysym_for(ev: InputEventKey) -> int:
	if KS.has(ev.keycode):
		return KS[ev.keycode]

	# Printable ASCII maps to itself. Control characters do not - Ctrl-C arrives
	# as unicode 3, and sending 3 would mean nothing to the guest.
	if ev.unicode >= 0x20 and ev.unicode < 0x7F:
		return ev.unicode

	# No usable character: either Ctrl is held, or the player's layout is not a
	# Latin one. What is left is the key itself, and the guest wants what a US
	# keyboard has on it.
	#
	# keycode first, physical_keycode only as a fallback, and that order is the
	# opposite of what it looks like it should be. keycode already arrives as
	# the Latin key on a Russian layout - D is 68, semicolon is 59 - while
	# physical_keycode is not always filled in at all: every event synthesised
	# through the Windows API arrives with the same 4194313 in it, so preferring
	# it turns every key into nothing.
	var sym := _us_key(ev.keycode, ev.shift_pressed)
	if sym != 0:
		return sym
	return _us_key(ev.physical_keycode, ev.shift_pressed)


## What a US keyboard produces for one key code, or 0 if it is not one.
static func _us_key(code: int, shift: bool) -> int:
	if KS.has(code):
		return KS[code]
	if code >= KEY_A and code <= KEY_Z:
		return (0x41 if shift else 0x61) + (code - KEY_A)
	if code >= KEY_0 and code <= KEY_9:
		if shift:
			return US_DIGITS_SHIFTED.unicode_at(code - KEY_0)
		return 0x30 + (code - KEY_0)
	if US.has(code):
		return (US[code][1] if shift else US[code][0]).unicode_at(0)
	return 0


## Modifier keysyms that should be held down for this event.
##
## RFB has no modifier field: a modifier is an ordinary key that goes down
## before the character and up after it. Godot reports them as flags, so they
## have to be turned back into key events.
static func modifiers_for(ev: InputEventKey) -> Array[int]:
	var out: Array[int] = []
	if ev.shift_pressed:
		out.append(KS[KEY_SHIFT])
	if ev.ctrl_pressed:
		out.append(KS[KEY_CTRL])
	if ev.alt_pressed:
		out.append(KS[KEY_ALT])
	return out


## Is this the key that hands the keyboard back?
static func is_release_capture(ev: InputEventKey) -> bool:
	return ev.keycode == RELEASE_CAPTURE_KEY
