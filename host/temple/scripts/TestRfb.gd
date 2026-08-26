extends Node

## Headless check that RfbClient really talks to a running guest.
##
## Not a unit test - it needs QEMU up with -vnc, and it proves the one thing
## unit tests cannot: that the handshake, the pixel format we asked for and the
## blit path all agree with what QEMU actually sends.
##
##   godot --headless --path host/temple res://scenes/TestRfb.tscn -- --port 5909

const DEFAULT_PORT := 5909

var _rfb: RfbClient
var _frames := 0
var _deadline_msec := 0


func _ready() -> void:
	var port := DEFAULT_PORT
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			port = args[i + 1].to_int()

	_rfb = RfbClient.new()
	add_child(_rfb)
	_rfb.connected.connect(_on_connected)
	_rfb.frame_updated.connect(_on_frame)
	_rfb.disconnected.connect(_on_lost)

	var err := _rfb.connect_to_guest("127.0.0.1", port)
	if err != OK:
		_die("connect_to_guest failed: %d" % err)
		return
	_deadline_msec = Time.get_ticks_msec() + 30000
	print("connecting to 127.0.0.1:%d ..." % port)


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > _deadline_msec:
		_die("timed out; is QEMU running with -vnc 127.0.0.1:9 ?")


func _on_connected(w: int, h: int) -> void:
	print("connected: %dx%d" % [w, h])
	if w != 640 or h != 480:
		print("NOTE: expected 640x480, the guest reports %dx%d" % [w, h])


func _on_frame() -> void:
	_frames += 1
	if _frames == 1:
		var img := _rfb.get_frame_image()
		var out := "user://rfb_gdscript.png"
		img.save_png(out)
		print("frame 1 saved to %s (%s)" % [ProjectSettings.globalize_path(out), img.get_size()])
		# A frame that is entirely one colour means the blit or the pixel format
		# is wrong even though nothing errored, so check before declaring success.
		var seen := {}
		for y in range(0, img.get_height(), 16):
			for x in range(0, img.get_width(), 16):
				seen[img.get_pixel(x, y).to_rgba32()] = true
		print("first bytes: %s" % [_rfb.debug_first_bytes])
		print("distinct colours sampled: %d" % seen.size())
		if seen.size() < 2:
			_die("the frame is a single colour - pixel format or blit is wrong")
			return
	if _frames >= 8:
		print("OK: %d frames" % _frames)
		get_tree().quit(0)
	else:
		_rfb.request_update(true)


func _on_lost(reason: String) -> void:
	_die("link lost: " + reason)


func _die(msg: String) -> void:
	printerr("FAIL: " + msg)
	get_tree().quit(1)
