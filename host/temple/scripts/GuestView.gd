extends TextureRect
class_name GuestView

## The guest's screen, and the keyboard when it has focus.
##
## Two things this deliberately does not do.
##
## It never scales by a fraction. The palette, the font and the 640x480 are the
## author's, and a non-integer scale resamples his pixels into mush. The texture
## filter is nearest and the size is a whole multiple, letterboxed.
##
## It never swallows the keyboard silently. Typing goes to the guest only while
## capture is on, and F12 always takes it back - the OS uses Ctrl-Alt combinations
## of its own, so a player who cannot escape them is stuck.

signal capture_changed(captured: bool)

var rfb: RfbClient

var captured := false:
	set(value):
		if captured == value:
			return
		captured = value
		if not captured:
			_release_held_keys()
		capture_changed.emit(captured)

var _held: Dictionary = {}


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP


func attach(client: RfbClient) -> void:
	rfb = client
	rfb.connected.connect(func(_w: int, _h: int) -> void: texture = rfb.texture)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and not captured:
		captured = true
		grab_focus()
		accept_event()
		return

	if not captured or rfb == null:
		return

	if event is InputEventKey:
		var ev := event as InputEventKey
		if ev.pressed and not ev.echo and KeyMap.is_release_capture(ev):
			captured = false
			accept_event()
			return
		_send_key(ev)
		accept_event()

	elif event is InputEventMouseMotion:
		var p := _guest_pos((event as InputEventMouseMotion).position)
		rfb.send_pointer(p.x, p.y, _button_mask())
		accept_event()

	elif event is InputEventMouseButton:
		var p := _guest_pos((event as InputEventMouseButton).position)
		rfb.send_pointer(p.x, p.y, _button_mask())
		accept_event()


func _send_key(ev: InputEventKey) -> void:
	var sym := KeyMap.keysym_for(ev)
	if sym == 0:
		return

	# Modifiers are ordinary keys in RFB, so they are pressed around the
	# character rather than described alongside it.
	var mods: Array[int] = KeyMap.modifiers_for(ev)

	if ev.pressed:
		for m: int in mods:
			if not _held.has(m):
				_held[m] = true
				rfb.send_key(m, true)
		rfb.send_key(sym, true)
		_held[sym] = true
	else:
		rfb.send_key(sym, false)
		_held.erase(sym)
		# Let a modifier go only once the event says it is no longer held.
		# Releasing it with every character would break Shift held down across
		# several capitals, and Ctrl held across a chord.
		if not ev.shift_pressed:
			_release_modifier(KeyMap.KS[KEY_SHIFT])
		if not ev.ctrl_pressed:
			_release_modifier(KeyMap.KS[KEY_CTRL])
		if not ev.alt_pressed:
			_release_modifier(KeyMap.KS[KEY_ALT])


func _release_modifier(sym: int) -> void:
	if _held.has(sym):
		rfb.send_key(sym, false)
		_held.erase(sym)


func _release_held_keys() -> void:
	# Losing capture with keys still down would leave the guest holding them -
	# a stuck Ctrl is indistinguishable from a broken keyboard.
	if rfb == null:
		return
	for sym: int in _held.keys():
		rfb.send_key(sym, false)
	_held.clear()


func _guest_pos(local: Vector2) -> Vector2i:
	if rfb == null or rfb.width == 0:
		return Vector2i.ZERO
	var scale_x := size.x / float(rfb.width)
	var scale_y := size.y / float(rfb.height)
	var s: float = maxf(minf(scale_x, scale_y), 0.001)
	var shown := Vector2(rfb.width, rfb.height) * s
	var origin := (size - shown) * 0.5
	var p := (local - origin) / s
	return Vector2i(int(p.x), int(p.y))


func _button_mask() -> int:
	var mask := 0
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		mask |= 1
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		mask |= 2
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		mask |= 4
	return mask


## Largest whole-number scale that fits, so pixels stay pixels.
static func integer_scale(available: Vector2, native: Vector2i) -> int:
	if native.x <= 0 or native.y <= 0:
		return 1
	return maxi(1, int(minf(available.x / native.x, available.y / native.y)))
