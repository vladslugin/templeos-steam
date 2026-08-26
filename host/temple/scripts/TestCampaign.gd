extends Node

## The campaign rules, checked without a guest or a window.
##
## These are the rules the design actually cares about - when a hint is offered,
## what counts as finished, whether reading the answer costs progress - so they
## get assertions rather than being left to whatever the UI happens to do.

var _ok := 0
var _bad := 0


func _ready() -> void:
	var c := Campaign.new()
	var n := c.load_from("res://data/tasks")
	_check("tasks load", n > 0, true)
	_check("indexed by id", c.by_id.has("hc_fib"), true)

	# Ordering is what the campaign teaches in, not filename order.
	var first: Campaign.Task = c.tasks[0]
	_check("chapter 1 comes before chapter 2", first.chapter <= 2.0, true)
	_check("sh_print is first", first.id, "sh_print")

	var fib: Campaign.Task = c.by_id["hc_fib"]
	_check("starts unstarted", fib.status, Campaign.Status.NOT_STARTED)
	_check("three hints in english", fib.hints("en").size(), 3)
	_check("three hints in russian", fib.hints("ru").size(), 3)
	_check("russian title used when present", fib.title("ru"), "Фибоначчи")

	# No hint before an attempt: answering a question nobody asked.
	_check("no hint offered up front", c.should_offer_hint("hc_fib"), false)

	c.apply_event("task_checked", {"id": "hc_fib", "cases": "4", "failed": "3"})
	_check("a failed check counts as attempted", fib.status, Campaign.Status.ATTEMPTED)
	_check("hint offered after one failure", c.should_offer_hint("hc_fib"), true)

	c.mark_hint_offered("hc_fib")
	_check("offered only once", c.should_offer_hint("hc_fib"), false)

	c.apply_event("hint_asked", {"id": "hc_fib", "level": "1"})
	_check("hint level recorded", fib.hint_level, 1)
	_check("a hint does not cost self-taught", c.self_taught, true)

	c.apply_event("task_done", {"id": "hc_fib", "sig": "AB", "hinted": "0"})
	_check("passed", fib.status, Campaign.Status.PASSED)
	_check("no hint offered once passed", c.should_offer_hint("hc_fib"), false)
	_check("one passed", c.passed_count(), 1)
	_check("not complete yet", c.complete, false)

	# Opening the full solution costs the campaign-wide achievement and nothing
	# else - the task still counts as done.
	c.apply_event("task_done", {"id": "hc_prime", "sig": "CD", "hinted": "1"})
	var prime: Campaign.Task = c.by_id["hc_prime"]
	_check("still passes after reading the answer", prime.status, Campaign.Status.PASSED)
	_check("self-taught is lost", c.self_taught, false)

	# Events for tasks we do not have must not blow up.
	c.apply_event("task_done", {"id": "no_such_task", "sig": "EF"})
	c.apply_event("godword_used", {})
	_check("unknown ids ignored", c.passed_count(), 2)

	var nxt := c.next_unfinished()
	_check("next unfinished found", nxt != null, true)
	_check("next is not one already passed", nxt.status != Campaign.Status.PASSED, true)

	print("\n%d passed, %d failed" % [_ok, _bad])
	get_tree().quit(1 if _bad > 0 else 0)


func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		_ok += 1
	else:
		_bad += 1
		printerr("FAIL %s: got %s, wanted %s" % [what, got, want])
