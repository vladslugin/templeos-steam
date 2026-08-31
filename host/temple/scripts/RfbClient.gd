extends Node
class_name RfbClient

## Reads the guest's screen over RFB and hands it back as a texture.
##
## QEMU serves its framebuffer over VNC, so showing the guest inside the
## launcher means being a VNC client - no second window, no screen scraping.
## Only what QEMU needs on loopback is implemented: RFB 3.8, security type
## None, raw encoding.
##
## The one decision that matters for speed is in _negotiate(): we tell the
## server which byte order to send, and we ask for exactly what Image wants for
## FORMAT_RGBA8. That way a rectangle arrives ready to blit and no per-pixel
## work happens anywhere. Asking for the server's preferred format instead would
## mean swizzling every pixel in GDScript, which is the difference between
## comfortable and unusable.
##
## Raw encoding is wasteful on the wire - a full 640x480 frame is 1.2 MB - but
## after the first frame the server sends only the rectangles that changed, and
## in practice those are small and few.

signal connected(width: int, height: int)
signal frame_updated
signal disconnected(reason: String)
## One character of an injected line has gone out. The launcher hangs a keyboard
## sound on this, so a command it writes for the player sounds like one.
signal typed_character

## First bytes of the most recent rectangle. Only for diagnosing a wrong pixel
## format, which shows up as a frame that is uniform rather than as an error.
var debug_first_bytes: PackedByteArray = PackedByteArray()

const RFB_VERSION := "RFB 003.008\n"

# Client-to-server message types
const MSG_SET_PIXEL_FORMAT := 0
const MSG_SET_ENCODINGS := 2
const MSG_FB_UPDATE_REQUEST := 3
const MSG_KEY_EVENT := 4
const MSG_POINTER_EVENT := 5

# Server-to-client message types
const SRV_FB_UPDATE := 0
const SRV_SET_COLOUR_MAP := 1
const SRV_BELL := 2
const SRV_CUT_TEXT := 3

enum State { IDLE, HANDSHAKE, READY, FAILED }

var state: State = State.IDLE
var width: int = 0
var height: int = 0
var texture: ImageTexture

var _peer := StreamPeerTCP.new()
var _image: Image
var _pending_request := false
## Whether the outstanding request asks for changes only, so the client
## can renew it without being told the mode again.
var _incremental := true

## A floor between update requests, in milliseconds. Zero, and that is the
## measured answer rather than a shrug.
##
## It was 30, on the reasoning that the guest paints at 29.97 and asking faster
## buys nothing. The arithmetic is right and the conclusion was wrong, because
## the two clocks are not aligned: the emulator scans the framebuffer for
## changes on a timer of its own, and a request that arrives just after a scan
## waits for the next one. A floor of 30ms against a scan of 30ms is two
## periods beating against each other, and what falls out is dropped frames.
##
## Measured on this guest with the pointer moving continuously, so every frame
## the guest draws is a frame with something new in it:
##
##     floor 30ms   22.7 frames a second delivered
##     floor 0      27.1
##
## against a compositor producing 29-30. So the floor was losing roughly one
## frame in six, and what that looks like is a marquee that advances smoothly
## and then skips - which is exactly what it was reported as.
##
## Asking as soon as the last answer lands costs the guest nothing measurable:
## the emulator holds the request open until pixels change, so there is no
## polling here to be paid for.
var min_request_interval_msec := 0
var _last_request_msec := 0

## Timing of the frames as they land, kept because "it still stutters" needs
## a number before it can be argued with. A gap is the wall-clock time
## between one finished frame and the next; work is what this client spent
## turning the bytes into a texture. Read and reset by the launcher's
## --stats, which is the only caller.
var stat_frames := 0
var stat_gap_sum := 0
var stat_gap_max := 0
var stat_over_60 := 0
var stat_over_100 := 0
var stat_work_usec := 0
var _last_frame_msec := 0


func stats_take() -> Dictionary:
	var out := {
		"frames": stat_frames,
		"gap_avg": (float(stat_gap_sum) / stat_frames) if stat_frames > 0 else 0.0,
		"gap_max": stat_gap_max,
		"over60": stat_over_60,
		"over100": stat_over_100,
		"work_ms": stat_work_usec / 1000.0,
	}
	stat_frames = 0
	stat_gap_sum = 0
	stat_gap_max = 0
	stat_over_60 = 0
	stat_over_100 = 0
	stat_work_usec = 0
	return out


## Everything read from the socket and not yet parsed. Messages are applied only
## once complete, so a half-arrived frame costs nothing but a frame of latency.
var _rx := PackedByteArray()


func connect_to_guest(host: String, port: int) -> Error:
	var err := _peer.connect_to_host(host, port)
	if err != OK:
		state = State.FAILED
		return err
	# Nagle off, and this is not a micro-optimisation - it was the stutter.
	#
	# Every frame costs one ten-byte request from this end, and Nagle holds
	# a small write until the previous one has been acknowledged. The other
	# end has nothing to say in between, so the acknowledgement waits on
	# Windows' delayed-ACK timer, which is 200ms. Most requests go out at
	# once because an acknowledgement happens to be in flight; the ones that
	# do not wait out the timer, and that is the freeze - the picture holds
	# still for a fifth of a second and then jumps.
	#
	# The emulator's own window has no socket in the path at all, which is
	# why nothing like this was ever visible there.
	_peer.set_no_delay(true)
	state = State.HANDSHAKE
	return OK


func close() -> void:
	_peer.disconnect_from_host()
	state = State.IDLE


## The current frame as an Image.
##
## Read this rather than texture.get_image(): under --headless the renderer is a
## stub and the texture hands back nothing, which makes a working client look
## broken. It is also what a 3D screen material would sample.
func get_frame_image() -> Image:
	return _image


func _process(_delta: float) -> void:
	_type_tick()
	if state == State.IDLE or state == State.FAILED:
		return

	_peer.poll()
	var status := _peer.get_status()
	if status == StreamPeerTCP.STATUS_ERROR:
		_fail("socket error")
		return
	if status != StreamPeerTCP.STATUS_CONNECTED:
		return

	if state == State.HANDSHAKE:
		# The handshake is short and strictly ordered, so it is done in one
		# blocking pass rather than as a state machine. Anything longer than a
		# frame here means the server is not QEMU and we want to know.
		if _peer.get_available_bytes() >= 12:
			_negotiate()
		return

	_pump()


## Blocking reads, used only during the handshake.
func _take(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	var deadline := Time.get_ticks_msec() + 5000
	while out.size() < n:
		if Time.get_ticks_msec() > deadline:
			_fail("timed out waiting for %d bytes" % n)
			return PackedByteArray()
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_fail("closed mid-handshake")
			return PackedByteArray()
		var avail := _peer.get_available_bytes()
		if avail <= 0:
			OS.delay_msec(1)
			continue
		var res: Array = _peer.get_data(mini(avail, n - out.size()))
		if res[0] != OK:
			_fail("read failed")
			return PackedByteArray()
		out.append_array(res[1])
	return out


func _fail(reason: String) -> void:
	state = State.FAILED
	_peer.disconnect_from_host()
	disconnected.emit(reason)


func _negotiate() -> void:
	var version := _take(12)
	if version.is_empty():
		return
	if version.slice(0, 4).get_string_from_ascii() != "RFB ":
		_fail("not an RFB server")
		return
	_peer.put_data(RFB_VERSION.to_ascii_buffer())

	var count := _take(1)
	if count.is_empty():
		return
	if count[0] == 0:
		var len_bytes := _take(4)
		var n := _be32(len_bytes, 0)
		_fail("server refused: " + _take(n).get_string_from_ascii())
		return
	var types := _take(count[0])
	if types.is_empty():
		return
	if not types.has(1):
		_fail("server wants authentication; start QEMU without a VNC password")
		return
	_peer.put_data(PackedByteArray([1]))

	var result := _take(4)
	if result.is_empty():
		return
	if _be32(result, 0) != 0:
		_fail("security handshake rejected")
		return

	_peer.put_data(PackedByteArray([1]))  # shared session

	var init := _take(24)
	if init.is_empty():
		return
	width = (init[0] << 8) | init[1]
	height = (init[2] << 8) | init[3]
	var name_len := _be32(init, 20)
	if name_len > 0 and _take(name_len).is_empty():
		return

	_set_pixel_format()
	_set_encodings()

	# RGB8, not RGBA8. RFB has no alpha: the fourth byte of every pixel is
	# unused and arrives as zero, so an RGBA8 frame is perfectly correct and
	# completely transparent. Converting each rectangle down to RGB8 drops that
	# byte in engine code rather than in a GDScript loop.
	_image = Image.create_empty(width, height, false, Image.FORMAT_RGB8)
	texture = ImageTexture.create_from_image(_image)

	state = State.READY
	connected.emit(width, height)
	request_update(false)


func _set_pixel_format() -> void:
	# 32 bits per pixel, 8 per channel, and the shifts chosen so the bytes land
	# in memory as R,G,B,X - exactly what FORMAT_RGBA8 reads. That is the whole
	# reason a rectangle can be blitted without touching a pixel.
	#
	# Little-endian, so byte 0 carries bits 7..0: red_shift 0 puts red first,
	# green 8 second, blue 16 third. The big-endian spelling of the same layout
	# was tried first and produced a uniform frame, so this is the one that
	# matches what QEMU sends.
	var msg := PackedByteArray()
	msg.append(MSG_SET_PIXEL_FORMAT)
	msg.append_array([0, 0, 0])              # padding
	msg.append(32)                           # bits-per-pixel
	msg.append(24)                           # depth
	msg.append(0)                            # little-endian
	msg.append(1)                            # true colour
	msg.append_array(_be16(255))             # red max
	msg.append_array(_be16(255))             # green max
	msg.append_array(_be16(255))             # blue max
	msg.append(0)                            # red shift
	msg.append(8)                            # green shift
	msg.append(16)                           # blue shift
	msg.append_array([0, 0, 0])              # padding
	_peer.put_data(msg)


func _set_encodings() -> void:
	var msg := PackedByteArray()
	msg.append(MSG_SET_ENCODINGS)
	msg.append(0)
	msg.append_array(_be16(1))
	msg.append_array([0, 0, 0, 0])           # raw
	_peer.put_data(msg)


func request_update(incremental: bool = true) -> void:
	_incremental = incremental
	if state != State.READY or _pending_request:
		return
	var now := Time.get_ticks_msec()
	if incremental and now - _last_request_msec < min_request_interval_msec:
		return
	_last_request_msec = now
	var msg := PackedByteArray()
	msg.append(MSG_FB_UPDATE_REQUEST)
	msg.append(1 if incremental else 0)
	msg.append_array(_be16(0))
	msg.append_array(_be16(0))
	msg.append_array(_be16(width))
	msg.append_array(_be16(height))
	_peer.put_data(msg)
	_pending_request = true


## Send a key. `down` false releases it. Keysyms are X11 values; see InputMap.gd.
func send_key(keysym: int, down: bool) -> void:
	if state != State.READY:
		return
	var msg := PackedByteArray()
	msg.append(MSG_KEY_EVENT)
	msg.append(1 if down else 0)
	msg.append_array([0, 0])
	msg.append_array(_be32_bytes(keysym))
	_peer.put_data(msg)


## Characters the server will not shift for us.
##
## QEMU turns a keysym into a key but not always into the modifier that key
## needs. A capital letter arrives right; every symbol on the top half of a US
## key arrives as the character on the bottom half, so
##
##     Print("Hi %d\n",2+2);
##
## lands in the guest as
##
##     Print9'Hi 5d\n',2=20;
##
## which is a very confusing thing to watch a computer type for you. These are
## the characters that need Shift held around them.
const NEEDS_SHIFT := "~!@#$%^&*()_+{}|:\"<>?"
const SHIFT_L := 0xFFE1

## One character per tick, near enough to a fast typist.
##
## Not as fast as the wire allows, and deliberately. The guest is a real machine
## with a keyboard controller and a receive FIFO, and a burst of forty
## characters in one frame is a burst of forty interrupts; more to the point,
## text appearing instantly reads as a paste, and the point of this is that the
## player watches the command being written and reads it on the way past.
const TYPE_INTERVAL_MSEC := 28

## Longest thing that may be typed in one go. A command line, not a file.
const TYPE_MAX := 240

var _typing: Array = []
var _type_next_msec := 0


## Type a line into the guest, as if it had been keyed in.
##
## It goes wherever the guest's focus is, exactly as a person's typing would.
## That is the honest behaviour: if the player has an editor open, the text
## lands in the editor, which is where they were looking.
func type_text(text: String, press_enter: bool = true) -> void:
	if state != State.READY or text.length() > TYPE_MAX:
		return
	for ch in text:
		var sym := ch.unicode_at(0)
		if sym < 0x20 or sym > 0x7E:
			continue
		var shifted := NEEDS_SHIFT.contains(ch)
		var step: Array = []
		if shifted:
			step.append([SHIFT_L, true])
		step.append([sym, true])
		step.append([sym, false])
		if shifted:
			step.append([SHIFT_L, false])
		_typing.append(step)
	if press_enter:
		_typing.append([[0xFF0D, true], [0xFF0D, false]])


## True while there is still something being typed, so a caller can avoid
## queueing two commands on top of each other.
func is_typing() -> bool:
	return not _typing.is_empty()


func _type_tick() -> void:
	if _typing.is_empty() or state != State.READY:
		return
	var now := Time.get_ticks_msec()
	if now < _type_next_msec:
		return
	_type_next_msec = now + TYPE_INTERVAL_MSEC
	var step: Array = _typing.pop_front()
	for ev: Array in step:
		send_key(ev[0], ev[1])
	typed_character.emit()


## Which keysyms this connection currently believes are down.
##
## The guest is a real machine with a real keyboard controller: a key it was
## told about and never told again stays down. So the state has to live with the
## connection rather than with whatever is drawing the guest at the time - the
## flat view and the room both send keys down this same socket, and if each kept
## its own idea of what was held they would disagree the moment the player moved
## between them.
var _held: Dictionary = {}


## One key event, with its modifiers handled the way RFB wants them.
##
## Modifiers are ordinary keys here rather than a field, so they are pressed
## around the character. The part that matters is that they are pressed ONCE and
## released only when the event says they are no longer held: toggling shift
## either side of every character sends four scancodes where two would do, and
## under this emulator the extra ones get lost - capitals arrive lowercase and
## every shifted symbol arrives as the character on the bottom of the key.
## DocClear; came through as docclear. It is the same lossy interrupt delivery
## that had the timer running at a fifteenth speed.
func send_key_event(ev: InputEventKey) -> void:
	var sym := KeyMap.keysym_for(ev)
	if sym == 0:
		return
	if ev.pressed:
		for m: int in KeyMap.modifiers_for(ev):
			if not _held.has(m):
				_held[m] = true
				send_key(m, true)
		send_key(sym, true)
		_held[sym] = true
	else:
		send_key(sym, false)
		_held.erase(sym)
		if not ev.shift_pressed:
			release_modifier(KeyMap.KS[KEY_SHIFT])
		if not ev.ctrl_pressed:
			release_modifier(KeyMap.KS[KEY_CTRL])
		if not ev.alt_pressed:
			release_modifier(KeyMap.KS[KEY_ALT])


func release_modifier(sym: int) -> void:
	if _held.has(sym):
		send_key(sym, false)
		_held.erase(sym)


## Let go of everything. Losing the keyboard with keys still down leaves the
## guest holding them, and a stuck Ctrl is indistinguishable from a broken
## keyboard.
func release_held_keys() -> void:
	for sym: int in _held.keys():
		send_key(sym, false)
	_held.clear()


func send_pointer(x: int, y: int, buttons: int) -> void:
	if state != State.READY:
		return
	var msg := PackedByteArray()
	msg.append(MSG_POINTER_EVENT)
	msg.append(buttons)
	msg.append_array(_be16(clampi(x, 0, width - 1)))
	msg.append_array(_be16(clampi(y, 0, height - 1)))
	_peer.put_data(msg)


func _pump() -> void:
	# Nothing here may wait. This runs on the frame thread, so a read that blocks
	# is a frame that does not happen - and to a player that is not "the network
	# is slow", it is the keyboard being slow. The whole update is buffered
	# before any of it is applied, and if the last rectangle has not arrived yet
	# we simply come back next frame.
	_soak()
	while _try_one_message():
		pass


func _soak() -> void:
	var avail := _peer.get_available_bytes()
	if avail <= 0:
		return
	var res: Array = _peer.get_data(avail)
	if res[0] == OK:
		_rx.append_array(res[1])


func _drop(n: int) -> void:
	_rx = _rx.slice(n)


## Parse one server message if all of it has arrived. False means wait.
func _try_one_message() -> bool:
	if _rx.is_empty():
		return false

	match _rx[0]:
		SRV_FB_UPDATE:
			return _try_fb_update()
		SRV_BELL:
			_drop(1)
			return true
		SRV_CUT_TEXT:
			if _rx.size() < 8:
				return false
			var n := _be32(_rx, 4)
			if _rx.size() < 8 + n:
				return false
			_drop(8 + n)
			return true
		SRV_SET_COLOUR_MAP:
			if _rx.size() < 6:
				return false
			var count := (_rx[4] << 8) | _rx[5]
			if _rx.size() < 6 + count * 6:
				return false
			_drop(6 + count * 6)
			return true
		_:
			_fail("unexpected server message %d" % _rx[0])
			return false


func _try_fb_update() -> bool:
	var t_start := Time.get_ticks_usec()
	# Walk the rectangle headers first to learn how long the whole message is.
	# Raw encoding makes that arithmetic exact, which is the one virtue it has.
	if _rx.size() < 4:
		return false
	var nrects := (_rx[2] << 8) | _rx[3]
	var off := 4
	for _i in nrects:
		if _rx.size() < off + 12:
			return false
		var w := (_rx[off + 4] << 8) | _rx[off + 5]
		var h := (_rx[off + 6] << 8) | _rx[off + 7]
		off += 12 + w * h * 4
		if _rx.size() < off:
			return false

	off = 4
	for _i in nrects:
		var x := (_rx[off] << 8) | _rx[off + 1]
		var y := (_rx[off + 2] << 8) | _rx[off + 3]
		var w := (_rx[off + 4] << 8) | _rx[off + 5]
		var h := (_rx[off + 6] << 8) | _rx[off + 7]
		var enc := _be32(_rx, off + 8)
		off += 12
		if enc != 0:
			_fail("rectangle encoded as %d; only raw was requested" % enc)
			return false
		var n := w * h * 4
		if w > 0 and h > 0:
			var data := _rx.slice(off, off + n)
			if debug_first_bytes.is_empty():
				debug_first_bytes = data.slice(0, mini(16, data.size()))
			# The wire bytes are already R,G,B in the right order; convert()
			# only discards the unused fourth byte, and does it in engine code.
			var rect := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)
			rect.convert(Image.FORMAT_RGB8)
			_image.blit_rect(rect, Rect2i(0, 0, w, h), Vector2i(x, y))
		off += n

	_drop(off)
	_pending_request = false
	# Ask for the next one here, not from the launcher's own _process.
	#
	# Nodes are processed parent first, and the launcher is this node's
	# parent - so a request issued there goes out a whole engine frame
	# after the reply was parsed here, and for those few milliseconds the
	# server has nobody waiting on it. Renewing here closes that window.
	#
	# It did not move the number it was written to move, and the comment
	# should say so: the stalls this was aimed at are still there,
	# unchanged, and they turned out to be the server going quiet rather
	# than anything this end was doing. Kept because a client with no
	# outstanding request is wrong on its own terms, not because it was
	# shown to help. The launcher still calls request_update, which is a
	# harmless primer for the first frame and after a reconnection.
	request_update(_incremental)
	texture.update(_image)
	
	var now := Time.get_ticks_msec()
	if _last_frame_msec > 0:
		var gap := now - _last_frame_msec
		stat_gap_sum += gap
		stat_gap_max = maxi(stat_gap_max, gap)
		if gap > 60:
			stat_over_60 += 1
		if gap > 100:
			stat_over_100 += 1
	_last_frame_msec = now
	stat_frames += 1
	stat_work_usec += Time.get_ticks_usec() - t_start
	
	frame_updated.emit()
	return true


func _be16(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 8) & 0xFF, v & 0xFF])


func _be32_bytes(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF])


func _be32(b: PackedByteArray, off: int) -> int:
	return (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]
