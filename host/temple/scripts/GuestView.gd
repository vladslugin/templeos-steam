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
## escape them is stuck. The pointer is not captured with it - see _gui_input.
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
## An integral can be made exact - the guest halves incoming movement and rounds
## its edge clamp to eight pixels, /Game/Pointer.HC undoes both, sync_pointer
## runs the pointer into a corner so the two ends agree, and _send_rfb_pointer
## breaks up jumps too large for a PS/2 packet. All of that measured zero pixels
## of error across the screen.
##
## And it was still the wrong answer, because an integral only has to be wrong
## once. Lose one packet, or let the player press Ctrl-Alt-Z, and the cursor is
## somewhere else for the rest of the session with nothing to correct it. What
## that feels like is being unable to reach the bottom-left corner of the guest
## because you run out of desk on the way.
##
## So the position now goes down the bridge instead, as a position, and the
## guest puts its pointer there - see /Game/MsBridge.HC for how, and why MsSet
## is the only correct way to do it. Nothing is accumulated, so nothing can
## drift. The relative path below is kept as the fallback for a guest whose
## layer is too old to understand the command, or a bridge that is down.
##
## The host cursor is still hidden over the guest, because two cursors in the
## same place is worse than one and the OS draws a better one than we would.
## Hidden over the guest and nowhere else, though: tying it to keyboard capture
## instead meant the cursor stayed invisible across the whole launcher, so
## reaching the hint button took a keystroke nobody would guess. Hover is the
## honest signal - the pointer is over the guest, so the guest is drawing it.

signal capture_changed(captured: bool)

var rfb: RfbClient

## The preferred way to move the pointer. Null, or a guest whose layer predates
## the command, falls back to RFB.
var bridge: BridgeClient

## Motion arrives faster than the guest can use it - Godot runs well above a
## hundred frames a second and the guest paints thirty. Coalesced to one line
## per interval so the bridge is not flooded with positions nobody will see.
## Button changes ignore this and go at once; a click that waits is a bug.
const POINTER_INTERVAL_MSEC := 16
var _pending_pos := Vector2i(-1, -1)
var _last_pointer_msec := 0

## The last position actually put on the wire, whichever wire that was. Read by
## the launcher's --stats, which asks the guest where its pointer is and prints
## the two side by side. They should never differ.
var last_pointer := Vector2i(-1, -1)

## How long to give the bridge to introduce itself before falling back to the
## relative pointer and its visible corner sweep. HELLO is asked for as soon as
## the socket is up and comes back in a frame or two; this is generous.
const SYNC_GRACE_MSEC := 1500
var _sync_due_msec := 0

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


func attach(client: RfbClient, link: BridgeClient = null) -> void:
	rfb = client
	bridge = link
	rfb.connected.connect(func(w: int, h: int) -> void:
		_native = Vector2i(w, h)
		_recompute()
		# Not synchronised yet. The screen and the bridge come up together and
		# the bridge has not said what it is at this point, so doing the corner
		# sweep here would flick the cursor across the screen every start-up,
		# including the usual case where it is not needed at all.
		_sync_due_msec = Time.get_ticks_msec() + SYNC_GRACE_MSEC
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


## The pointer and the keyboard are separate, and only the keyboard is captured.
##
## They used to be one thing: nothing reached the guest until the player clicked
## it, so the guest's cursor sat still while the hand moved over it, and the
## first click was spent on focus rather than on whatever it was aimed at. But
## the guest draws the only cursor there is - the host's is hidden over this
## view - so a pointer that does not follow the hand is a screen with no cursor
## on it at all.
##
## So motion always goes through. Clicking additionally takes the keyboard, and
## the click itself is passed on rather than swallowed.
func _gui_input(event: InputEvent) -> void:
	if rfb == null:
		return

	if event is InputEventMouseMotion:
		_send_pointer(_guest_pos((event as InputEventMouseMotion).position))
		accept_event()
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and not captured:
			captured = true
			grab_focus()
		# Urgent: a press or a release must reach the guest in the frame it
		# happened, at the position it happened at.
		_send_pointer(_guest_pos(mb.position), true)
		accept_event()
		return

	if not captured:
		return

	if event is InputEventKey:
		var ev := event as InputEventKey
		if ev.pressed and not ev.echo and KeyMap.is_release_capture(ev):
			captured = false
			accept_event()
			return
		_send_key(ev)
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


## Hidden wherever the guest is drawing its own pointer, which is anywhere over
## this view - not, as it used to be, only while the keyboard was captured. The
## guest's cursor follows the hand from the moment it arrives, so showing the
## host's as well would be two cursors in the same place. Off this view the
## launcher is an ordinary window and wants an ordinary cursor.
func _sync_cursor() -> void:
	var hide_it := _hovering
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


## Buttons as the guest wants them: bit 0 left, bit 1 right.
##
## Deliberately not _button_mask(), which is RFB's layout and puts the middle
## button in bit 1 - reusing it here would turn every right-click into a middle
## click the guest has no concept of.
func _guest_buttons() -> int:
	var mask := 0
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		mask |= 1
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		mask |= 2
	return mask


func _send_pointer(p: Vector2i, urgent: bool = false) -> void:
	if bridge != null and bridge.supports_pointer():
		_pending_pos = p
		if urgent:
			_flush_pointer()
		return
	_send_rfb_pointer(p)


func _flush_pointer() -> void:
	if _pending_pos.x < 0 or bridge == null:
		return
	_last_pointer_msec = Time.get_ticks_msec()
	last_pointer = _pending_pos
	bridge.send_pointer(_pending_pos.x, _pending_pos.y, _guest_buttons())
	_pending_pos = Vector2i(-1, -1)


func _process(_delta: float) -> void:
	if _sync_due_msec > 0 and Time.get_ticks_msec() >= _sync_due_msec:
		_sync_due_msec = 0
		sync_pointer()

	if _pending_pos.x >= 0 			and Time.get_ticks_msec() - _last_pointer_msec >= POINTER_INTERVAL_MSEC:
		_flush_pointer()


## The fallback. Tell the guest where the pointer is by moving it there, in
## pieces if it is far from where the guest last heard.
func _send_rfb_pointer(p: Vector2i) -> void:
	if _last_sent.x >= 0:
		var d := p - _last_sent
		var far := maxi(absi(d.x), absi(d.y))
		var steps := (far + MAX_POINTER_STEP - 1) / MAX_POINTER_STEP
		for i in range(1, steps):
			var mid := _last_sent + Vector2i(Vector2(d) * (float(i) / float(steps)))
			rfb.send_pointer(mid.x, mid.y, _button_mask())
	rfb.send_pointer(p.x, p.y, _button_mask())
	_last_sent = p
	last_pointer = p


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
	# Nothing to synchronise when positions are pushed rather than accumulated,
	# and the sweep is visible - the cursor flicks across the screen - so it is
	# not done for free.
	if bridge != null and bridge.supports_pointer():
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
