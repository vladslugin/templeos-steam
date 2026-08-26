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

## Never ask for updates faster than this. Every request makes the server scan
## the whole framebuffer for changes, and that scan competes with emulation on
## the same CPU - measured on this guest, asking every frame took it from 26 FPS
## to 11. The guest paints at 29.97 (WINMGR_FPS), so anything above that rate is
## pure cost. 30ms leaves a little headroom under it.
var min_request_interval_msec := 30
var _last_request_msec := 0

## Everything read from the socket and not yet parsed. Messages are applied only
## once complete, so a half-arrived frame costs nothing but a frame of latency.
var _rx := PackedByteArray()


func connect_to_guest(host: String, port: int) -> Error:
	var err := _peer.connect_to_host(host, port)
	if err != OK:
		state = State.FAILED
		return err
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
	texture.update(_image)
	_pending_request = false
	frame_updated.emit()
	return true


func _be16(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 8) & 0xFF, v & 0xFF])


func _be32_bytes(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF])


func _be32(b: PackedByteArray, off: int) -> int:
	return (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]
