extends Node

## The launcher's pointer against the guest's own, pixel for pixel.
##
## The shape below was not designed. It was read off a running machine: the
## guest's pointer was parked at a known place with CMD ms, the framebuffer was
## dumped through QMP, and the pixels around it were counted. Seventeen of them,
## in this arrangement.
##
## TempleCursor draws the same three lines the OS draws - GrArrow3 from (8,8)
## back to (0,0), with barbs whose length falls out of w=2.75 and thick=1 - so
## if the two ever disagree, one of them has been changed by hand and the answer
## is on the machine, not here.

const MEASURED := [
	"#####....",
	"##.......",
	"#.#......",
	"#..#.....",
	"#...#....",
	".....#...",
	"......#..",
	".......#.",
	"........#",
]

var _ok := 0
var _bad := 0


func _ready() -> void:
	var rows := TempleCursor.shape_rows()
	_check("nine rows", rows.size(), MEASURED.size())
	for i in mini(rows.size(), MEASURED.size()):
		_row("row %d" % i, rows[i], MEASURED[i])

	var lit := 0
	for r: String in rows:
		lit += r.count("#")
	_check("seventeen pixels", lit, 17)

	# The tip is the hot spot and has to be a pixel, or the arrow points at
	# nothing.
	_row("tip is drawn", rows[0].substr(0, 1), "#")

	print("\n%d passed, %d failed" % [_ok, _bad])
	get_tree().quit(1 if _bad > 0 else 0)


func _check(what: String, got: int, want: int) -> void:
	if got == want:
		_ok += 1
	else:
		_bad += 1
		printerr("FAIL %s: got %d, wanted %d" % [what, got, want])


func _row(what: String, got: String, want: String) -> void:
	if got == want:
		_ok += 1
	else:
		_bad += 1
		printerr("FAIL %s:\n  got  %s\n  want %s" % [what, got, want])
