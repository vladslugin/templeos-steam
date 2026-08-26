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

@onready var _guest: GuestView = $Split/Guest
@onready var _panel: CampaignPanel = $Split/CampaignPanel
@onready var _status: Label = $Bar/Status

var campaign: Campaign

var _layer_ver := "-"
var _events := 0
var _frames := 0
var _last := ""

## Run one check as soon as the guest is audible, then report and quit. Not a
## test hook - a launcher that can be driven from the command line is what CI
## needs to exercise the whole path rather than the pieces.
var _auto_check := ""
var _auto_done := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--check" and i + 1 < args.size():
			_auto_check = args[i + 1]

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

	campaign = Campaign.new()
	var n := campaign.load_from("res://data/tasks")
	_panel.bind(campaign)
	_panel.check_requested.connect(_on_check_requested)
	_panel.hint_requested.connect(_on_hint_requested)
	_note("%d task(s) loaded" % n)

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
	if _auto_check != "":
		_on_check_requested(_auto_check)


func _on_hello(proto: String, os_build: String, layer_ver: String) -> void:
	_layer_ver = layer_ver
	_note("guest up: proto %s, %s" % [proto, os_build])


func _on_event(id: String, fields: Dictionary) -> void:
	_events += 1
	campaign.apply_event(id, fields)
	_panel.refresh()

	var task_id: String = fields.get("id", "")
	# Offer the first hint after a first failure, without being asked. Nobody
	# has to admit to being stuck.
	if id == "task_checked" and campaign.should_offer_hint(task_id):
		campaign.mark_hint_offered(task_id)
		_panel.offer_hint(task_id)

	_note("%s %s" % [id, task_id])

	# A passing check is followed by task_done, and that is what marks the task
	# passed. Reporting on task_checked alone would print "0 of 4 failed" beside
	# a status of not-started, which is true for about a millisecond and
	# misleading for anyone reading the log.
	if _auto_check != "" and not _auto_done and task_id == _auto_check:
		var t: Campaign.Task = campaign.by_id[task_id]
		if id == "task_checked" and t.last_failed > 0:
			_auto_done = true
			_report_auto(t)
			get_tree().quit(1)
		elif id == "task_done":
			_auto_done = true
			_report_auto(t)
			get_tree().quit(0)


func _report_auto(t: Campaign.Task) -> void:
	var names := ["not started", "attempted", "passed"]
	print("RESULT %s: %d of %d failed, %s, %d/%d passed, self-taught %s"
			% [t.id, t.last_failed, t.last_cases, names[t.status],
			   campaign.passed_count(), campaign.tasks.size(),
			   "yes" if campaign.self_taught else "no"])


func _on_check_requested(task_id: String) -> void:
	bridge.send_command("check_task", {"id": task_id})
	_note("check " + task_id)


func _on_hint_requested(task_id: String, level: int) -> void:
	bridge.send_command("hint", {"id": task_id, "level": level})
	# The guest echoes hint_asked back over the bridge, and that is what moves
	# the model - so a hint taken in the player's own shell counts the same.
	_note("hint %d for %s" % [level, task_id])


func _on_log(text: String) -> void:
	# The error translator will read this channel: a compiler message arrives
	# here and gets a plain explanation beside it, never instead of it.
	_note("log: " + text)


func _note(msg: String) -> void:
	_last = msg
	print(msg)
