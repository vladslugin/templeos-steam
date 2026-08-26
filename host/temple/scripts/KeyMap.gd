extends RefCounted
class_name KeyMap

## Godot key events to X11 keysyms, which is what RFB carries.
##
## Two paths, in this order:
##
##   1. The event's unicode, when it has one. For printable ASCII the keysym is
##      the character code, so this is exact and it follows the player's own
##      keyboard layout without a table per layout.
##   2. A table, for everything with no character - arrows, function keys,
##      modifiers - and for letters typed with Ctrl held, where Godot reports no
##      unicode at all.
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


## The keysym for an event, or 0 if there is nothing sensible to send.
static func keysym_for(ev: InputEventKey) -> int:
	if KS.has(ev.keycode):
		return KS[ev.keycode]

	# Printable characters map to themselves. Control characters do not - Ctrl-C
	# arrives as unicode 3, and sending 3 would be meaningless to the guest.
	if ev.unicode >= 0x20 and ev.unicode < 0x7F:
		return ev.unicode

	# Ctrl held: Godot gives no usable unicode, so fall back to the key itself.
	# Lower case, because the shift modifier is sent as its own key event and
	# the guest applies it.
	if ev.keycode >= KEY_A and ev.keycode <= KEY_Z:
		return 0x61 + (ev.keycode - KEY_A)
	if ev.keycode >= KEY_0 and ev.keycode <= KEY_9:
		return 0x30 + (ev.keycode - KEY_0)
	if ev.keycode == KEY_SPACE:
		return 0x20

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
