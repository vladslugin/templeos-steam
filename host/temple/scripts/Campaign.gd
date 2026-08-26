extends RefCounted
class_name Campaign

## What the player has done, and what the game should offer them next.
##
## Kept apart from the panel that draws it so the rules can be tested without a
## window - and the rules are where the design lives. In particular the one in
## should_offer_hint(): a first failed attempt earns an offer of the first hint,
## unprompted. Nobody has to ask for help, which is the point.
##
## Taking a hint costs nothing. Opening the full solution costs nothing either,
## except the single campaign-wide achievement for never having opened one. A
## player who reads the answer still finished the task, and the progress here
## says so.

enum Status { NOT_STARTED, ATTEMPTED, PASSED }

class Task extends RefCounted:
	var id: String
	var chapter: float
	var order: int
	var title_en: String
	var title_ru: String
	var start_file: String
	var kind: String
	var achievement: String
	var est_minutes: int
	var hints_en: Array = []
	var hints_ru: Array = []
	var doc_refs: Array = []

	var status: Campaign.Status = Campaign.Status.NOT_STARTED
	var attempts: int = 0
	var last_failed: int = -1
	var last_cases: int = -1
	var hint_level: int = 0        ## highest hint the player has opened
	var hint_offered: bool = false ## the first hint has already been put in front of them

	func hints(lang: String) -> Array:
		return hints_ru if lang == "ru" else hints_en

	func title(lang: String) -> String:
		return title_ru if lang == "ru" and title_ru != "" else title_en


var tasks: Array[Task] = []
var by_id: Dictionary = {}

## True once every task has passed. Not the same as "the player saw everything".
var complete: bool:
	get:
		for t: Task in tasks:
			if t.status != Status.PASSED:
				return false
		return not tasks.is_empty()

## The campaign-wide achievement for never opening a full solution.
var self_taught: bool:
	get:
		for t: Task in tasks:
			if t.hint_level >= 3:
				return false
		return true


func load_from(dir_path: String) -> int:
	tasks.clear()
	by_id.clear()

	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("no task directory at " + dir_path)
		return 0

	for name in dir.get_files():
		if not name.ends_with(".json"):
			continue
		var f := FileAccess.open(dir_path.path_join(name), FileAccess.READ)
		if f == null:
			continue
		var doc: Variant = JSON.parse_string(f.get_as_text())
		if typeof(doc) != TYPE_DICTIONARY:
			push_warning("unreadable task: " + name)
			continue
		var t := _parse(doc as Dictionary)
		if t != null:
			tasks.append(t)
			by_id[t.id] = t

	# Chapter then order, which is the sequence the campaign teaches in. Chapter
	# is a float because the spec has a chapter 1.5.
	tasks.sort_custom(func(a: Task, b: Task) -> bool:
		if a.chapter != b.chapter:
			return a.chapter < b.chapter
		return a.order < b.order)
	return tasks.size()


func _parse(doc: Dictionary) -> Task:
	if not doc.has("id") or not doc.has("check"):
		return null
	var t := Task.new()
	t.id = doc["id"]
	t.chapter = float(doc.get("chapter", 0))
	t.order = int(doc.get("order", 0))
	t.start_file = doc.get("start_file", "")
	t.achievement = doc.get("achievement", "")
	t.est_minutes = int(doc.get("est_minutes", 0))
	t.kind = (doc["check"] as Dictionary).get("kind", "")
	t.doc_refs = doc.get("doc_refs", [])
	var title: Dictionary = doc.get("title", {})
	t.title_en = title.get("en", t.id)
	t.title_ru = title.get("ru", "")
	var hints: Dictionary = doc.get("hints", {})
	t.hints_en = hints.get("en", [])
	t.hints_ru = hints.get("ru", [])
	return t


## Fold a bridge event into the state. Unknown events are ignored, not an error:
## the catalogue carries plenty this model has no opinion about.
func apply_event(id: String, fields: Dictionary) -> void:
	var task_id: String = fields.get("id", "")
	if task_id == "" or not by_id.has(task_id):
		return
	var t: Task = by_id[task_id]

	match id:
		"task_checked":
			t.attempts += 1
			t.last_failed = int(fields.get("failed", -1))
			t.last_cases = int(fields.get("cases", -1))
			if t.last_failed > 0 and t.status != Status.PASSED:
				t.status = Status.ATTEMPTED
		"task_done":
			t.status = Status.PASSED
			t.last_failed = 0
			# The guest reports whether the full solution was opened. Trust it
			# over local state: the player may have read it in their own shell.
			if int(fields.get("hinted", 0)) != 0:
				t.hint_level = maxi(t.hint_level, 3)
		"hint_asked":
			t.hint_level = maxi(t.hint_level, int(fields.get("level", 1)))
		"task_loaded":
			if t.status == Status.NOT_STARTED:
				t.status = Status.ATTEMPTED


## Should the first hint be put in front of the player without being asked for?
##
## After one failed attempt, and only once. Waiting longer means watching someone
## be stuck on purpose; offering it sooner means answering a question nobody
## asked.
func should_offer_hint(task_id: String) -> bool:
	if not by_id.has(task_id):
		return false
	var t: Task = by_id[task_id]
	return t.attempts >= 1 and t.last_failed > 0 and not t.hint_offered \
			and t.status != Status.PASSED


func mark_hint_offered(task_id: String) -> void:
	if by_id.has(task_id):
		(by_id[task_id] as Task).hint_offered = true


func next_unfinished() -> Task:
	for t: Task in tasks:
		if t.status != Status.PASSED:
			return t
	return null


func passed_count() -> int:
	var n := 0
	for t: Task in tasks:
		if t.status == Status.PASSED:
			n += 1
	return n
