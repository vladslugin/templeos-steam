extends Node
class_name TempleCursor

## The launcher's pointer, drawn the way the guest draws its own.
##
## TempleOS has one cursor and it is three lines. DrawStdMs calls
## GrArrow3(dc, x+8, y+8, 0, x, y, 0) (Adam/Gr/GrComposites.HC:298-305), which
## draws the shaft from eight pixels down and right back to the hot spot, and
## then two barbs at the tip. With w=2.75 and thick=1 the barb arithmetic at
## GrComposites.HC:135-138 comes out to exactly four pixels each, straight up
## and straight left, so the whole cursor is:
##
##     #####....        the horizontal barb, four pixels and the tip
##     ##.......
##     #.#......        the vertical barb down the left
##     #..#.....
##     #...#....
##     .....#...        the shaft, out to (8,8)
##     ......#..
##     .......#.
##     ........#
##
## Seventeen pixels. Confirmed against the machine rather than trusted: the
## pointer was parked at a known place, the framebuffer was dumped, and the
## pixels around it were counted. They are these.
##
## ONE DEPARTURE, AND IT IS DELIBERATE
##
## The guest draws its cursor with XOR, so it is the inverse of whatever is
## under it - black over the white of a document, yellow over the blue of the
## desktop. A hardware cursor cannot invert; only something drawn into the frame
## can, and drawing it would put the pointer a frame behind the hand. After a
## night spent taking a frame of lag out of this launcher, adding one back for
## a colour would be a poor trade. So it is black, which is what the guest's own
## comes out as over the white the panel is mostly made of.
##
## Every shape is set to the same image on purpose. Godot swaps the pointer for
## a beam over text and a hand over links; TempleOS never swaps anything, and a
## cursor that changes shape is the launcher admitting it is a different program
## from the thing it is showing.

## The three lines, as the OS draws them, in the OS's own coordinates. Kept as
## endpoints rather than as a bitmap so the shape stays readable as the arrow it
## is - and so that anyone checking it against GrComposites.HC has something to
## check against.
const SHAFT := [Vector2i(0, 0), Vector2i(8, 8)]
const BARB_V := [Vector2i(0, 0), Vector2i(0, 4)]
const BARB_H := [Vector2i(0, 0), Vector2i(4, 0)]

const SIZE := 9

## Black over white is what XOR gives on a document, which is where the pointer
## spends nearly all of its time in this launcher.
const INK := Color(0, 0, 0, 1)

static var instance: TempleCursor = null

var _scale := 0


func _ready() -> void:
	instance = self
	get_window().size_changed.connect(_refresh)
	_refresh()


func _exit_tree() -> void:
	# Hand the pointer back. A custom cursor set by a process that has gone is
	# not the next program's problem, but leaving it is untidy.
	Input.set_custom_mouse_cursor(null)
	if instance == self:
		instance = null


## Rebuild at whatever whole-number magnification the window is at.
##
## The launcher's canvas is 920 logical pixels wide and project.godot pins the
## stretch to whole numbers, so the guest's pixels are always doubled or tripled
## by an integer. The cursor is not part of that canvas - it is drawn by the
## window system in real pixels - so it has to be told the factor, or it ends up
## a third of the size of everything it points at.
func _refresh() -> void:
	var f := maxi(1, int(floor(float(get_window().size.x) / 920.0)))
	if f == _scale:
		return
	_scale = f

	var img := Image.create(SIZE * f, SIZE * f, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_line(img, SHAFT[0], SHAFT[1], f)
	_line(img, BARB_V[0], BARB_V[1], f)
	_line(img, BARB_H[0], BARB_H[1], f)

	var tex := ImageTexture.create_from_image(img)
	# Hot spot at the tip, which is the corner. GrArrow3's second point is where
	# the arrow points, and here that is (0,0).
	for shape in [Input.CURSOR_ARROW, Input.CURSOR_IBEAM, Input.CURSOR_POINTING_HAND,
			Input.CURSOR_CROSS, Input.CURSOR_WAIT, Input.CURSOR_BUSY,
			Input.CURSOR_CAN_DROP, Input.CURSOR_FORBIDDEN, Input.CURSOR_HELP]:
		Input.set_custom_mouse_cursor(tex, shape, Vector2.ZERO)


## One line of the arrow, as whole magnified pixels.
##
## Bresenham rather than a float walk, because the OS's Line() is integer and
## the point of this file is to land on the same seventeen pixels it does.
func _line(img: Image, a: Vector2i, b: Vector2i, f: int) -> void:
	var dx := absi(b.x - a.x)
	var dy := -absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx + dy
	var p := a
	while true:
		_dot(img, p, f)
		if p == b:
			break
		var e2 := err * 2
		if e2 >= dy:
			err += dy
			p.x += sx
		if e2 <= dx:
			err += dx
			p.y += sy


func _dot(img: Image, p: Vector2i, f: int) -> void:
	for y in f:
		for x in f:
			img.set_pixel(p.x * f + x, p.y * f + y, INK)


## The cursor as a picture, for anything that wants to check it. Returns the
## nine-by-nine shape at magnification one, which is what the guest draws.
static func shape_rows() -> PackedStringArray:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := TempleCursor.new()
	c._line(img, SHAFT[0], SHAFT[1], 1)
	c._line(img, BARB_V[0], BARB_V[1], 1)
	c._line(img, BARB_H[0], BARB_H[1], 1)
	c.free()
	var out := PackedStringArray()
	for y in SIZE:
		var row := ""
		for x in SIZE:
			row += "#" if img.get_pixel(x, y).a > 0.5 else "."
		out.append(row)
	return out
