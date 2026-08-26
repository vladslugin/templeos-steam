extends Control

## The launcher shell: shows the guest, listens to the bridge.
##
## The guest is a texture, not a window. That is what lets the same view be
## dropped onto a screen in a 3D room later without any of this changing.

@export var vnc_host := "127.0.0.1"
@export var vnc_port := 5909
@export var bridge_host := "127.0.0.1"
@export var bridge_port := 4555

var rfb: RfbClient
var bridge: BridgeClient

@onready var _guest: TextureRect = $Guest
@onready var _status: Label = $Status

var _layer_ver := "-"
var _events := 0
var _frames := 0


func _ready() -> void:
	rfb = RfbClient.new()
	add_child(rfb)
	rfb.connected.connect(_on_rfb_connected)
	rfb.frame_updated.connect(_on_frame)
	rfb.disconnected.connect(func(r: String) -> void: _note("guest view lost: " + r))

	bridge = BridgeClient.new()
	add_child(bridge)
	bridge.hello_received.connect(_on_hello)
	bridge.event_received.connect(_on_event)
	bridge.log_received.connect(_on_log)
	bridge.link_lost.connect(func(r: String) -> void: _note("bridge: " + r))

	rfb.connect_to_guest(vnc_host, vnc_port)
	bridge.connect_to_guest(bridge_host, bridge_port)


func _process(_delta: float) -> void:
	# Ask for the next frame only once the last one landed; RfbClient drops the
	# request if one is already outstanding, so this cannot pile up.
	rfb.request_update(true)
	_status.text = "layer %s\nframes %d\nevents %d" % [_layer_ver, _frames, _events]


func _on_rfb_connected(w: int, h: int) -> void:
	_guest.texture = rfb.texture
	_note("guest view %dx%d" % [w, h])


func _on_frame() -> void:
	_frames += 1


func _on_hello(proto: String, os_build: String, layer_ver: String) -> void:
	_layer_ver = layer_ver
	_note("guest up: proto %s, %s, layer %s" % [proto, os_build, layer_ver])


func _on_event(id: String, fields: Dictionary) -> void:
	_events += 1
	_note("event %s %s" % [id, fields])


func _on_log(text: String) -> void:
	# The error translator will read this channel: compiler messages arrive
	# here and get a plain explanation beside them, never instead of them.
	_note("guest log: " + text)


func _note(msg: String) -> void:
	print(msg)
