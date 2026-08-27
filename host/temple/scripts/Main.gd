extends Control

## The launcher shell: shows the guest, listens to the bridge, owns the keyboard.
##
## The guest is a texture rather than a window, which is what lets the same view
## be put on a screen in a room later without any of this changing.

@export var vnc_host := "127.0.0.1"
@export var vnc_port := 5909
@export var bridge_host := "127.0.0.1"
## combridge's client port, not the one the guest dials out to.
@export var bridge_port := 4556

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

## Once-a-second timing report, so "it lags" can be turned into numbers.
##
## Read frames/s carefully: it counts updates that arrived, and the server holds
## an incremental request open until pixels actually change, so a still desktop
## honestly produces two or three a second and that is not a fault. It is worth
## looking at only next to what the guest thinks it is painting - its own status
## line prints an FPS - and the two should be close while anything is moving.
## What a player feels is the delay between a keystroke and seeing it, which
## this cannot see; that is measured against the guest from outside.
## How wide the status field is, in characters.
##
## The bar spans the window's 920 logical pixels, but it is shared: the
## progress meter beside it takes 144 and the layout puts a cell between them,
## leaving 768, which on an 8-pixel grid is 96 columns.
const STATUS_COLS := 96

var _stats := false
var _stat_msec := 0
var _stat_frames := 0
var _proc_usec := 0
## Where the guest last said its pointer is, in answer to CMD ms_report.
var _guest_ms := Vector2i(-1, -1)
var _guest_ms_cnt := -1
## Where the pointer was when the last report was asked for, so the answer is
## compared against the question rather than against a mouse that has moved on.
var _ms_asked := Vector2i(-1, -1)

## Composite rate to ask the guest for, once it is listening.
##
## Not for the frames. The emulator scans the guest's framebuffer for changes on
## a timer of its own and forwards about thirty updates a second however fast
## the guest paints, so anything above that is drawn and thrown away.
##
## This used to be the thing that made the machine usable, and it was not: what
## made it unusable was the guest's timer interrupt arriving 65 times a second
## instead of 1000, which stretched every Sleep in the OS - the window
## manager's own frame wait included - by a factor of fifteen. /Game/Clock.HC
## fixes that at the source, and with it fixed a keystroke into a still screen
## appears in 24ms with this off, against 75ms and a tail past 300ms before.
##
## What is left for it is the emulator's empty-scan penalty: a scan that finds
## nothing adds fifty milliseconds to its own interval, and a guest painting
## every 33ms against a scan every 30ms produces one of those once or twice a
## second. Painting a little more often than the scan keeps it from happening.
## Measured end to end, keystroke to pixels on the wire:
##
##     pacer off      median  3ms   p90 48   max 50    emulator 12% of a core
##     pacer at 60    median  4ms   p90 30   max 32                 32%
##     pacer at 120   median 17ms   p90 28   max 33                 29%
##
## Sixty, because thirty is what can be delivered and asking for more than
## double that buys nothing. It settles lower on its own whenever the screen is
## too heavy; see /Game/Fps.HC.
##
## --fps 0 turns it off.
var _fps_target := 60
var _guest_timer := 0.0
var _guest_jif := 0
var _guest_fps := -1
var _guest_fps_rate := 0
var _guest_composed := 0.0
var _guest_fps_skipped := 0

## What the guest's error watcher puts in front of a compiler message it saw.
## See /Game/Novice.HC.
const ERR_MARK := "!err "
var _errors := ErrorBook.new()

## How much the machine meets a newcomer halfway. Chosen before the guest
## starts - it is a #define on the guest's disk, not a setting - so this is only
## what to tell the guest we believe, and what to show here. See
## guest/Game/Level.HC and tools/set_level.py.
var _level := 1

## Whether the machine makes any noise. --no-sound turns it off for the whole
## session; the panel's own switch turns it off while it runs.
var _sound := true


func _ready() -> void:
	# Sound first, so anything that happens during start-up can be heard.
	add_child(Sound.new())
	Sound.set_enabled(_sound)
	# And the guest's own pointer over the launcher's half of the window, so
	# the two halves are one machine rather than a program showing another one.
	add_child(TempleCursor.new())

	rfb = RfbClient.new()
	add_child(rfb)

	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--check" and i + 1 < args.size():
			_auto_check = args[i + 1]
		if args[i] == "--stats":
			_stats = true
		if args[i] == "--rate-limit" and i + 1 < args.size():
			rfb.min_request_interval_msec = args[i + 1].to_int()
		if args[i] == "--fps" and i + 1 < args.size():
			_fps_target = args[i + 1].to_int()
		if args[i] == "--bridge-port" and i + 1 < args.size():
			bridge_port = args[i + 1].to_int()
		if args[i] == "--vnc-port" and i + 1 < args.size():
			vnc_port = args[i + 1].to_int()
		# What the disk was prepared with, passed through so this side agrees
		# with it. It does not set anything on the guest - the level is a
		# #define compiled into the layer at boot - it only decides whether the
		# error watcher is wanted and what this panel offers.
		if args[i] == "--level" and i + 1 < args.size():
			_level = clampi(args[i + 1].to_int(), 0, 2)
		if args[i] == "--no-sound":
			_sound = false

	rfb.connected.connect(func(w: int, h: int) -> void: _note("guest view %dx%d" % [w, h]))
	# The guest is only worth redrawing when a frame lands, so the request is
	# driven by the previous one arriving rather than by the launcher's frame
	# rate. Asking faster than the guest paints only wastes work.
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

	var msgs := _errors.load_book()
	if msgs > 0:
		_note("%d compiler messages in the book" % msgs)

	campaign = Campaign.new()
	var n := campaign.load_from("res://data/tasks")
	_panel.bind(campaign)
	_panel.check_requested.connect(_on_check_requested)
	_panel.hint_requested.connect(_on_hint_requested)
	_note("%d task(s) loaded" % n)

	_guest.attach(rfb, bridge)
	_guest.capture_changed.connect(func(_c: bool) -> void: _refresh())
	rfb.frame_updated.connect(func() -> void: _frames += 1)

	_fit_window()

	rfb.connect_to_guest(vnc_host, vnc_port)
	bridge.connect_to_guest(bridge_host, bridge_port)
	_refresh()


## Shrink the window if the screen it opened on cannot hold it.
##
## The launcher is laid out on an 8-pixel grid and drawn at a whole-number
## scale, so the sizes that look right are the multiples: 920x488, then
## 1840x976. The larger is the default because it is what a 1080p screen wants,
## and on anything smaller it would open partly off the edge - with the
## campaign panel being the part that goes, since it is on the right.
##
## Godot letterboxes rather than scaling fractionally, so the fallback costs
## nothing but size.
func _fit_window() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var screen := DisplayServer.screen_get_usable_rect(
			DisplayServer.window_get_current_screen())
	var want := DisplayServer.window_get_size()
	if want.x <= screen.size.x and want.y <= screen.size.y:
		return
	var base := Vector2i(920, 488)
	var fit := maxi(1, mini(screen.size.x / base.x, screen.size.y / base.y))
	DisplayServer.window_set_size(base * fit)
	# Centred, because a window that has just been resized keeps its old
	# top-left and can end up hanging off the bottom.
	DisplayServer.window_set_position(
			screen.position + (screen.size - base * fit) / 2)
	_note("%dx%d would not fit this screen; using %dx%d"
			% [want.x, want.y, base.x * fit, base.y * fit])


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	# RfbClient drops the request if one is still outstanding, so asking every
	# frame cannot pile up - it simply keeps the pipe full.
	rfb.request_update()
	_refresh()
	_proc_usec += Time.get_ticks_usec() - t0

	if _stats:
		var now := Time.get_ticks_msec()
		if _stat_msec == 0:
			_stat_msec = now
		elif now - _stat_msec >= 1000:
			var secs := (now - _stat_msec) / 1000.0
			# Sent against arrived. If these two ever differ the pointer has
			# drifted, which is the whole failure this design exists to make
			# impossible - so it is worth checking every second rather than
			# discovering it by moving the mouse and squinting.
			#
			# Compared against the position that was on the wire when the
			# question was asked, not the one on the wire now. The answer takes
			# a round trip, so a moving mouse would otherwise report a
			# disagreement on every line and mean nothing by it.
			var drifted := _ms_asked.x >= 0 and _guest_ms.x >= 0 					and _ms_asked != _guest_ms
			print("frames/s %.1f   engine fps %d   launcher %.1f ms/frame   "
					% [(_frames - _stat_frames) / secs,
					   Engine.get_frames_per_second(),
					   _proc_usec / 1000.0 / maxf(1.0, Engine.get_frames_per_second() * secs)]
					+ "pointer %s  asked %s  guest %s n=%d%s"
					% ["bridge" if bridge.supports_pointer() else "rfb",
					   _ms_asked, _guest_ms, _guest_ms_cnt,
					   "   <-- DRIFTED" if drifted else ""]
					+ "   guest composed %.1f/s  paced %d  skipped %d  timer %.0f/s%s"
					% [_guest_composed, _guest_fps_rate, _guest_fps_skipped,
					   _guest_timer,
					   "" if _guest_timer > 900 else "  <-- SLOW CLOCK"])
			var fs: Dictionary = rfb.stats_take()
			print("   gaps: avg %.1f ms  max %d  over60 %d  over100 %d   client work %.2f ms/frame"
				% [fs["gap_avg"], fs["gap_max"], fs["over60"], fs["over100"],
				   fs["work_ms"] / maxf(1.0, fs["frames"])])
			_ms_asked = _guest.last_pointer
			bridge.send_command("ms_report")
			bridge.send_command("perf")
			_stat_msec = now
			_stat_frames = _frames
			_proc_usec = 0


func _refresh() -> void:
	# Cut to the width of the field. The bar is one character row across the
	# top of the window, the shape TempleOS gives its own
	# (Adam/WallPaper.HC:96-99), and a string longer than the row is not
	# wrapped or scrolled - it is cut off, taking the last message with it.
	var capture := "kbd:guest" if _guest.captured else "kbd:launcher"
	var line := "%s  layer %s  frames %d  events %d  %s" % [
		capture, _layer_ver, _frames, _events, _last]
	_status.text = line.left(STATUS_COLS)


func _on_first_heartbeat(jiffies: int) -> void:
	bridge.heartbeat.disconnect(_on_first_heartbeat)
	if _fps_target > 0:
		bridge.send_command("fps", {"n": _fps_target})
		_note("asked the guest to composite at %d" % _fps_target)
	bridge.send_command("level", {"n": _level})
	_note("bridge alive, guest at %d jiffies" % jiffies)
	if _auto_check != "":
		_on_check_requested(_auto_check)


func _on_hello(proto: String, os_build: String, layer_ver: String) -> void:
	_layer_ver = layer_ver
	# One beep and then the room, the order a machine does it in. Silence before
	# this point is the machine not being on yet, which is worth having.
	Sound.boot()
	Sound.room_on()
	# Whether the pointer goes down the bridge or falls back to moving a PS/2
	# mouse depends on this version, so it is worth saying out loud - a stale
	# disk image is otherwise a mystery about the cursor rather than a mismatch.
	var how := "absolute" if bridge.supports_pointer() else "relative (old layer)"
	_note("guest up: proto %s, %s, layer %s, pointer %s"
			% [proto, os_build, layer_ver, how])


func _on_event(id: String, fields: Dictionary) -> void:
	# The guest agreeing or disagreeing, in the voice of a PC speaker.
	if id == "task_done":
		Sound.passed()
	elif id == "task_checked" and int(fields.get("failed", 0)) > 0:
		Sound.failed()

	# Not a campaign event; the guest answering a question --stats asked.
	if id == "perf":
		_guest_fps = int(fields.get("fps", -1))
		_guest_fps_rate = int(fields.get("rate", 0))
		# What the compositor actually finished, which is the number to compare
		# the delivered count against - anything the guest drew and we did not
		# receive is a step some moving thing on screen skipped.
		var ms := int(fields.get("ms", 0))
		if ms > 200:
			_guest_composed = 1000.0 * int(fields.get("upd", 0)) / ms
			# The guest's timer interrupt, in interrupts a second. It should be
			# a thousand. When it is not, everything the guest schedules -
			# every Sleep, every frame the window manager waits for - is
			# stretched by the same factor, and no amount of work on the
			# display path will make the machine feel any different. This is
			# worth a column of its own because it cost a long time to find:
			# the guest's other clock reads correctly throughout, so the
			# machine insists the time is right while running fifteen times
			# slow. See /Game/Clock.HC.
			_guest_timer = 1000.0 * (int(fields.get("jif", 0)) - _guest_jif) / ms
		_guest_jif = int(fields.get("jif", 0))
		_guest_fps_skipped = int(fields.get("skipped", 0))
		return

	if id == "ms_at":
		_guest_ms = Vector2i(int(fields.get("x", -1)), int(fields.get("y", -1)))
		_guest_ms_cnt = int(fields.get("n", -1))
		return

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
	# A compiler message, marked by the guest's error watcher. It gets a plain
	# explanation beside it and never instead of it: what the compiler printed
	# stays on the guest's own screen, untouched, and this only annotates.
	if text.begins_with(ERR_MARK):
		var raw := text.substr(ERR_MARK.length()).strip_edges()
		if raw != "":
			Sound.error()
			_panel.show_compiler_error(raw, _errors.look_up(raw))
			_note("compiler: " + raw)
		return
	_note("log: " + text)


func _note(msg: String) -> void:
	_last = msg
	print(msg)
