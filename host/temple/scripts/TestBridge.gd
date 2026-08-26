extends Node

## Headless check that BridgeClient really talks to a running guest.
##
## Proves both directions and the whitelist in one go: wait until the guest is
## audible, ask it to check a task, and require the reply to come back as a
## catalogued event with its fields intact.
##
##   godot --headless --path host/temple res://scenes/TestBridge.tscn -- --port 4555

var _bridge: BridgeClient
var _heard := false
var _asked := false
var _deadline := 0


func _ready() -> void:
	var port := 4555
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			port = args[i + 1].to_int()

	_bridge = BridgeClient.new()
	add_child(_bridge)
	_bridge.hello_received.connect(_on_hello)
	_bridge.heartbeat.connect(_on_heartbeat)
	_bridge.event_received.connect(_on_event)
	_bridge.log_received.connect(func(t: String) -> void: print("guest log: " + t))
	_bridge.link_lost.connect(func(r: String) -> void: print("note: " + r))

	var err := _bridge.connect_to_guest("127.0.0.1", port)
	if err != OK:
		_die("connect failed: %d" % err)
		return
	_deadline = Time.get_ticks_msec() + 60000
	print("listening on 127.0.0.1:%d ..." % port)


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > _deadline:
		_die("timed out waiting for the guest")
	if _heard and not _asked:
		_asked = true
		print("-> CMD check_task id=hc_fib")
		_bridge.send_command("check_task", {"id": "hc_fib"})


func _on_hello(proto: String, os_build: String, layer_ver: String) -> void:
	print("HELLO proto=%s os=%s layer=%s" % [proto, os_build, layer_ver])
	_heard = true


func _on_heartbeat(jiffies: int) -> void:
	# Connecting after boot means HELLO is long gone; a heartbeat proves the
	# link just as well.
	if not _heard:
		print("heartbeat at %d jiffies - guest is alive" % jiffies)
		_heard = true


func _on_event(id: String, fields: Dictionary) -> void:
	print("EV %s %s" % [id, fields])
	if id == "task_checked":
		if not fields.has("cases") or not fields.has("failed"):
			_die("task_checked arrived without its fields")
			return
		print("OK: round trip complete, %s of %s cases failed"
				% [fields["failed"], fields["cases"]])
		get_tree().quit(0)


func _die(msg: String) -> void:
	printerr("FAIL: " + msg)
	get_tree().quit(1)
