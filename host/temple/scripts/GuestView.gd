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
## Typing goes to the guest while this view has focus, and clicking anything in
## the launcher takes it back. F12 does too, for the times there is nothing to
## click: the OS has Ctrl-Alt combinations of its own, so a player who cannot
## escape them is stuck.
##
## THE MOUSE, and why the host cursor disappears over the guest.
##
## TempleOS drives a PS/2 mouse, which is a relative device: the driver adds
## whatever the hardware reports to its own position and scales it on the way in
##
##     ms.presnap.x = ToI64(ms.scale.x * x) + ms.offset.x
##     Kernel/SerialDev/Mouse.HC:11
##
## RFB, meanwhile, carries absolute coordinates, which QEMU converts back into
## PS/2 movement. So the guest's pointer is an integral of movement, and the
## usual way out - attaching a USB tablet, which is absolute - is not open to
## us: there is no USB stack in this OS at all, by design.
##
## An integral can still be made exact, and here it is, in three parts. The
## guest halves incoming movement by default and rounds its edge clamp to eight
## pixels; /Game/Pointer.HC undoes both, and says why. sync_pointer below runs
## the pointer into a corner once so the two ends agree where it is. And
## _send_pointer breaks up any jump too large for a PS/2 packet, which is the
## only way movement gets lost once the first two are done.
##
## Measured against a running guest, at eight positions across the screen: zero
## pixels of error at every one of them.
##
## The host cursor is still hidden over the guest, because two cursors in the
## same place is worse than one and the OS draws a better one than we would.
## Hidden over the guest and nowhere else, though: tying it to keyboard capture
## instead meant the cursor stayed invisible across the whole launcher, so
## reaching the hint button took a keystroke nobody would guess. Hover is the
## honest signal - the pointer is over the guest, so the guest is drawing it.

signal capture_changed(captured: bool)

var rfb: RfbClient

var captured := false:
	set(value):
		if captured == value:
			return
		captured = value
		if not captured:
			_release_held_keys()
		_sync_cursor()
		capture_changed.emit(captured)
		queue_redraw()

var _held: Dictionary = {}
var _hovering := false
## The last position the guest was told about, so a long jump can be
## broken into pieces it can actually receive. Negative until the first.
var _last_sent := Vector2i(-1, -1)
var _scale := 1
var _origin := Vector2.ZERO
var _native := Vector2i(640, 480)


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_recompute)
	mouse_entered.connect(_on_hover_changed.bind(true))
	mouse_exited.connect(_on_hover_changed.bind(false))
	# Clicking a button in the launcher moves focus, and that is the clearest
	# statement a player can make that they are done typing at the guest.
	focus_exited.connect(func() -> void: captured = false)


func attach(client: RfbClient) -> void:
	rfb = client
	rfb.connected.connect(func(w: int, h: int) -> void:
		_native = Vector2i(w, h)
		_recompute()
		sync_pointer()
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
		_send_pointer(_guest_pos((event as InputEventMouseMotion).position))
		accept_event()

	elif event is InputEventMouseButton:
		_send_pointer(_guest_pos((event as InputEventMouseButton).position))
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


func _on_hover_changed(inside: bool) -> void:
	_hovering = inside
	_sync_cursor()


## Hidden only where the guest draws its own pointer: over this view, while it
## is the thing taking keystrokes. Anywhere else the launcher is an ordinary
## window and wants an ordinary cursor.
func _sync_cursor() -> void:
	var hide_it := captured and _hovering
	# Hidden rather than Godot's captured mode: captured reports only relative
	# motion, and RFB needs a position to send.
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN if hide_it
			else Input.MOUSE_MODE_VISIBLE)


func _exit_tree() -> void:
	# Leaving with the cursor hidden would hide it everywhere.
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _release_held_keys() -> void:
	# Losing capture with keys still down would leave the guest holding them -
	# a stuck Ctrl is indistinguishable from a broken keyboard.
	if rfb == null:
		return
	for sym: int in _held.keys():
		rfb.send_key(sym, false)
	_held.clear()


## The furthest the guest can be moved by one report.
##
## RFB carries a position, but the guest has a PS/2 mouse, which carries
## movement - nine signed bits of it per axis. The emulator turns consecutive
## positions into movement, so a jump of more than about 255 pixels arrives
## clipped, and the pointer is then out of step for good: nothing downstream
## ever gets told where it was supposed to be.
##
## Moving a hand never does this - it is a few pixels per report. Coming back
## onto the guest's screen from the panel beside it does, every time.
const MAX_POINTER_STEP := 200


## Tell the guest where the pointer is, in pieces if it is far from where it
## last heard. The steps are sent in the same frame; nothing waits.
func _send_pointer(p: Vector2i) -> void:
	if _last_sent.x >= 0:
		var d := p - _last_sent
		var far := maxi(absi(d.x), absi(d.y))
		var steps := (far + MAX_POINTER_STEP - 1) / MAX_POINTER_STEP
		for i in range(1, steps):
			var mid := _last_sent + Vector2i(Vector2(d) * (float(i) / float(steps)))
			rfb.send_pointer(mid.x, mid.y, _button_mask())
	rfb.send_pointer(p.x, p.y, _button_mask())
	_last_sent = p


## Put the guest's pointer somewhere both ends agree on.
##
## The launcher knows where the player is pointing. The guest only knows how far
## it has been told to move, and it started wherever it started - the middle of
## the screen, as it happens. Nothing connects the two until they are made to
## meet, and until then the guest draws its cursor at a fixed offset from the
## player's hand, which is precisely what "the cursor is not where it really is"
## looks like.
##
## Sweeping to the far corner and back pins it. The guest clamps at its own
## edges, so a sweep wider than the screen leaves the pointer in the corner
## wherever it began, and counting can start from there. It costs one flick
## across the screen, once, before anybody is looking.
func sync_pointer() -> void:
	if rfb == null:
		return
	# Anchor the launcher's end first: the emulator works in differences, and
	# the first one is measured from whatever it happens to remember.
	rfb.send_pointer(0, 0, 0)
	_last_sent = Vector2i.ZERO
	_send_pointer(Vector2i(_native.x - 1, _native.y - 1))
	_send_pointer(Vector2i.ZERO)


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
