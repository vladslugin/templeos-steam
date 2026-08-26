extends Control
class_name GuestView

## The guest's screen, and the keyboard when it has focus.
##
## It draws the texture itself rather than leaning on TextureRect's stretch
## modes, for one reason: every one of them will scale by a fraction when the
## space is not an exact multiple. The palette, the font and the 640x480 are the
## author's work, and 640 pixels smeared across 717 is not his work any more -
## it is a blurred approximation of it. So the scale is a whole number, the rest
## is letterbox, and drawing by hand is what makes that certain.
##
## Drawing by hand also fixes the mouse. The pointer position sent to the guest
## is worked out from the same origin and scale used to draw, so what the player
## points at is what the guest is told about. Deriving them separately is how a
## cursor ends up somewhere other than where it appears.
##
## Typing goes to the guest only while capture is on, and F12 always takes it
## back - the OS has Ctrl-Alt combinations of its own, so a player who cannot
## escape them is stuck.

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
		queue_redraw()

var _held: Dictionary = {}
var _scale := 1
var _origin := Vector2.ZERO
var _native := Vector2i(640, 480)


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_recompute)


func attach(client: RfbClient) -> void:
	rfb = client
	rfb.connected.connect(func(w: int, h: int) -> void:
		_native = Vector2i(w, h)
		_recompute()
		queue_redraw())
	rfb.frame_updated.connect(queue_redraw)


func _recompute() -> void:
	_scale = integer_scale(size, _native)
	var shown := Vector2(_native) * _scale
	# Floor the offset so the origin lands on a whole pixel: half a pixel of
	# offset resamples the whole image and undoes the point of integer scaling.
	_origin = ((size - shown) * 0.5).floor()


func _draw() -> void:
	if rfb == null or rfb.texture == null:
		return
	if _scale <= 0:
		_recompute()
	draw_texture_rect(rfb.texture, Rect2(_origin, Vector2(_native) * _scale), false)


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

	# Modifiers are ordinary keys in RFB, not a field, so they are pressed
	# around the character rather than described alongside it.
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


## Where in the guest's 640x480 the pointer is. Same origin and scale as _draw,
## which is the whole point of computing them once.
func _guest_pos(local: Vector2) -> Vector2i:
	if _scale <= 0:
		return Vector2i.ZERO
	var p := (local - _origin) / float(_scale)
	return Vector2i(
		clampi(int(p.x), 0, _native.x - 1),
		clampi(int(p.y), 0, _native.y - 1))


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
