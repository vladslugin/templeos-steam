extends Node
class_name BridgeClient

## The host end of the guest bridge.
##
## Same line protocol as tools/eventbridge_host.py, which is the reference
## implementation and has the tests. ASCII lines over COM1, LF terminated,
## 240 bytes maximum:
##
##     guest -> host                    host -> guest
##       HELLO <proto> <os> <layer>       ACK <event_id>
##       EV <event_id> [<k>=<v> ...]      CMD load_task id=<id>
##       HB <jiffies>                     CMD check_task id=<id>
##       LOG <text>                       CMD hint id=<id> level=<1..3>
##
## Events arriving here are the only thing that unlocks anything. The guest is
## in ring 0 and could send whatever it likes, so this side filters against the
## catalogue in data/events.json rather than trusting what turns up - not as
## anti-cheat, which is meaningless here, but so that a malformed line cannot
## quietly award a task.

signal hello_received(proto: String, os_build: String, layer_ver: String)
signal event_received(id: String, fields: Dictionary)
signal log_received(text: String)
signal heartbeat(jiffies: int)
signal link_lost(reason: String)

const LINE_MAX := 240
const HEARTBEAT_TIMEOUT_MS := 5000

var connected: bool = false
var last_heartbeat_msec: int = 0

var _peer := StreamPeerTCP.new()
var _buf := ""
var _whitelist: Dictionary = {}


func _ready() -> void:
	_load_whitelist()


func _load_whitelist() -> void:
	# The catalogue ships with the game rather than being hard-coded, so adding
	# an event does not mean touching the launcher.
	var f := FileAccess.open("res://data/events.json", FileAccess.READ)
	if f == null:
		push_warning("events.json missing; every event will be rejected")
		return
	var doc: Variant = JSON.parse_string(f.get_as_text())
	if typeof(doc) != TYPE_DICTIONARY or not doc.has("events"):
		push_warning("events.json is not the expected shape")
		return
	for e: Dictionary in doc["events"]:
		_whitelist[e["id"]] = e.get("fields", [])


func connect_to_guest(host: String, port: int) -> Error:
	var err := _peer.connect_to_host(host, port)
	if err == OK:
		last_heartbeat_msec = Time.get_ticks_msec()
	return err


func close() -> void:
	_peer.disconnect_from_host()
	connected = false


func send_command(name: String, args: Dictionary = {}) -> void:
	var parts := ["CMD", name]
	for k: String in args:
		parts.append("%s=%s" % [k, args[k]])
	var line := " ".join(parts)
	if line.length() > LINE_MAX:
		push_error("command over %d bytes, dropped: %s" % [LINE_MAX, name])
		return
	_peer.put_data((line + "\n").to_ascii_buffer())


func _process(_delta: float) -> void:
	_peer.poll()
	var status := _peer.get_status()
	if status == StreamPeerTCP.STATUS_ERROR:
		if connected:
			connected = false
			link_lost.emit("socket error")
		return
	if status != StreamPeerTCP.STATUS_CONNECTED:
		return

	var avail := _peer.get_available_bytes()
	if avail > 0:
		var res: Array = _peer.get_data(avail)
		if res[0] == OK:
			_buf += (res[1] as PackedByteArray).get_string_from_ascii()

	while true:
		var nl := _buf.find("\n")
		if nl < 0:
			break
		var line := _buf.substr(0, nl).strip_edges()
		_buf = _buf.substr(nl + 1)
		if line != "":
			_handle(line)

	# A guest that stops sending heartbeats is not necessarily broken. In a
	# cooperatively scheduled OS a loop without Yield stops everything until it
	# ends - and in a game about writing code, players write those constantly.
	# So this is reported, never treated as a crash.
	if connected and Time.get_ticks_msec() - last_heartbeat_msec > HEARTBEAT_TIMEOUT_MS:
		last_heartbeat_msec = Time.get_ticks_msec()
		link_lost.emit("guest quiet for %d ms" % HEARTBEAT_TIMEOUT_MS)


func _handle(line: String) -> void:
	if line.length() > LINE_MAX:
		push_warning("over-long line dropped")
		return

	var parts := line.split(" ", false)
	if parts.is_empty():
		return

	match parts[0]:
		"HELLO":
			if parts.size() < 4:
				push_warning("malformed HELLO: " + line)
				return
			connected = true
			last_heartbeat_msec = Time.get_ticks_msec()
			hello_received.emit(parts[1], parts[2], parts[3])
			_peer.put_data("ACK HELLO\n".to_ascii_buffer())
		"HB":
			if parts.size() >= 2:
				last_heartbeat_msec = Time.get_ticks_msec()
				heartbeat.emit(parts[1].to_int())
		"LOG":
			log_received.emit(line.substr(4))
		"EV":
			if parts.size() < 2:
				return
			_handle_event(parts[1], _parse_fields(parts.slice(2)))
		_:
			push_warning("unknown verb: " + line)


func _handle_event(id: String, fields: Dictionary) -> void:
	if not _whitelist.has(id):
		push_warning("event outside the catalogue, ignored: " + id)
		return
	for required: String in _whitelist[id]:
		if not fields.has(required):
			push_warning("%s missing field %s, ignored" % [id, required])
			return
	# A task_done without a signature is almost always a double-fired check
	# rather than a completion.
	if id == "task_done" and not fields.has("sig"):
		push_warning("task_done without sig, ignored")
		return
	event_received.emit(id, fields)
	_peer.put_data(("ACK " + id + "\n").to_ascii_buffer())


func _parse_fields(tokens: PackedStringArray) -> Dictionary:
	var out := {}
	for tok: String in tokens:
		var eq := tok.find("=")
		if eq > 0:
			out[tok.substr(0, eq)] = tok.substr(eq + 1)
	return out
