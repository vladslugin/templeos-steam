extends PanelContainer
class_name CampaignPanel

## The campaign, as the player sees it.
##
## Draws what Campaign decides; it holds no rules of its own. The one thing
## worth noticing here is what the buttons say: the solution is a plain button
## sitting next to the others, not something hidden behind a warning. Reading it
## costs a single campaign-wide achievement and nothing else, and pretending
## otherwise would just make people feel bad for being stuck.

signal check_requested(task_id: String)
signal hint_requested(task_id: String, level: int)

var campaign: Campaign
var lang := "en"

@onready var _tasks: ItemList = $Root/Tasks
@onready var _progress: Label = $Root/Progress
@onready var _title: Label = $Root/Title
@onready var _status: Label = $Root/Status
@onready var _hint: RichTextLabel = $Root/Hint
@onready var _btn_hint: Button = $Root/Buttons/Hint1
@onready var _btn_solution: Button = $Root/Buttons/Solution
@onready var _btn_check: Button = $Root/Buttons/Check

var _selected := ""


func _ready() -> void:
	_tasks.item_selected.connect(_on_item_selected)
	_btn_check.pressed.connect(func() -> void:
		if _selected != "":
			check_requested.emit(_selected))
	_btn_hint.pressed.connect(func() -> void: _ask_hint(_next_hint_level()))
	_btn_solution.pressed.connect(func() -> void: _ask_hint(3))


func bind(c: Campaign) -> void:
	campaign = c
	_rebuild()
	var first := campaign.next_unfinished()
	if first != null:
		select(first.id)


func _rebuild() -> void:
	_tasks.clear()
	for t: Campaign.Task in campaign.tasks:
		_tasks.add_item("%s  %s  %s" % [_mark(t.status), _chapter(t.chapter), t.title(lang)])
	_progress.text = "%d of %d passed" % [campaign.passed_count(), campaign.tasks.size()]


func _mark(s: Campaign.Status) -> String:
	match s:
		Campaign.Status.PASSED:    return "[x]"
		Campaign.Status.ATTEMPTED: return "[~]"
		_:                         return "[ ]"


func _chapter(c: float) -> String:
	# Chapter 1.5 is a real chapter in the campaign, so this cannot just be an int.
	return "ch%d" % int(c) if c == floor(c) else "ch%s" % str(c)


func select(task_id: String) -> void:
	if not campaign.by_id.has(task_id):
		return
	_selected = task_id
	for i in campaign.tasks.size():
		if campaign.tasks[i].id == task_id:
			_tasks.select(i)
			break
	_refresh_detail()


func _on_item_selected(index: int) -> void:
	if index >= 0 and index < campaign.tasks.size():
		_selected = campaign.tasks[index].id
		_refresh_detail()


func _refresh_detail() -> void:
	if _selected == "" or not campaign.by_id.has(_selected):
		return
	var t: Campaign.Task = campaign.by_id[_selected]

	_title.text = "%s  -  edit %s" % [t.title(lang), t.start_file]

	if t.status == Campaign.Status.PASSED:
		_status.text = "passed"
	elif t.last_failed > 0:
		_status.text = "%d of %d cases failed, attempt %d" % [t.last_failed, t.last_cases, t.attempts]
	elif t.attempts > 0:
		_status.text = "attempt %d" % t.attempts
	else:
		_status.text = "about %d minutes" % t.est_minutes if t.est_minutes > 0 else ""

	var hints := t.hints(lang)
	if t.hint_level > 0 and t.hint_level <= hints.size():
		_hint.text = "[b]Hint %d[/b]\n%s" % [t.hint_level, hints[t.hint_level - 1]]
	else:
		_hint.text = ""

	_btn_hint.text = "Hint %d" % _next_hint_level()
	_btn_hint.disabled = _next_hint_level() > 2
	_btn_solution.disabled = false
	_btn_check.disabled = false

	# A printing task is checked in the player's own shell: capturing output
	# needs a terminal, and the bridge pump is not one.
	if t.kind == "stdout":
		_btn_check.text = "Check  (type TaskCheck(\"%s\"); in the guest)" % t.id
	else:
		_btn_check.text = "Check"


func _next_hint_level() -> int:
	if _selected == "" or not campaign.by_id.has(_selected):
		return 1
	return mini((campaign.by_id[_selected] as Campaign.Task).hint_level + 1, 3)


func _ask_hint(level: int) -> void:
	if _selected == "":
		return
	hint_requested.emit(_selected, level)


## Called when the player has just failed and has not been offered help yet.
func offer_hint(task_id: String) -> void:
	if task_id != _selected:
		select(task_id)
	_hint.text = "[i]Stuck? There is a hint, and taking it costs nothing.[/i]"


func refresh() -> void:
	_rebuild()
	_refresh_detail()
