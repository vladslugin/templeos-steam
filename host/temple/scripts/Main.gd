extends Control

## The launcher shell: shows the guest, listens to the bridge, owns the keyboard.
##
## The guest is a texture rather than a window, which is what lets the same view
## be put on a screen in a room later without any of this changing.

@export var vnc_host := "127.0.0.1"
@export var vnc_port := 5909
@export var bridge_host := "127.0.0.1"
@export var bridge_port := 4555

var rfb: RfbClient
var bridge: BridgeClient

@onready var _guest: GuestView = $Guest
@onready var _status: Label = $Bar/Status

var _layer_ver := "-"
var _events := 0
var _frames := 0
var _last := ""


func _ready() -> void:
	rfb = RfbClient.new()
	add_child(rfb)
	rfb.connected.connect(func(w: int, h: int) -> void: _note("guest view %dx%d" % [w, h]))
	rfb.disconnected.connect(func(r: String) -> void: _note("guest view lost: " + r))

	bridge = BridgeClient.new()
	add_child(bridge)
	bridge.hello_received.connect(_on_hello)
	bridge.event_received.connect(_on_event)
	bridge.log_received.connect(_on_log)
	bridge.link_lost.connect(func(r: String) -> void: _note("bridge: " + r))
	# Connecting after boot means HELLO has long gone; a heartbeat is the proof
	# the link is alive, and it is worth saying so once.
	bridge.heartbeat.connect(_on_first_heartbeat)

	_guest.attach(rfb)
	_guest.capture_changed.connect(func(_c: bool) -> void: _refresh())
	rfb.frame_updated.connect(func() -> void: _frames += 1)

	rfb.connect_to_guest(vnc_host, vnc_port)
	bridge.connect_to_guest(bridge_host, bridge_port)
	_refresh()


func _process(_delta: float) -> void:
	# RfbClient drops the request if one is still outstanding, so asking every
	# frame cannot pile up - it simply keeps the pipe full.
	rfb.request_update(true)
	_refresh()


func _refresh() -> void:
	var capture := "keyboard: guest (F12 to leave)" if _guest.captured \
			else "keyboard: launcher (click the screen to type)"
	_status.text = "%s   |   layer %s   frames %d   events %d   %s" % [
		capture, _layer_ver, _frames, _events, _last]


func _on_first_heartbeat(jiffies: int) -> void:
	bridge.heartbeat.disconnect(_on_first_heartbeat)
	_note("bridge alive, guest at %d jiffies" % jiffies)


func _on_hello(proto: String, os_build: String, layer_ver: String) -> void:
	_layer_ver = layer_ver
	_note("guest up: proto %s, %s" % [proto, os_build])


func _on_event(id: String, fields: Dictionary) -> void:
	_events += 1
	_note("%s %s" % [id, fields.get("id", "")])


func _on_log(text: String) -> void:
	# The error translator will read this channel: a compiler message arrives
	# here and gets a plain explanation beside it, never instead of it.
	_note("log: " + text)


func _note(msg: String) -> void:
	_last = msg
	print(msg)
