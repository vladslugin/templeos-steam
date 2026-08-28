extends Node3D
class_name Room

## The machine on a desk, in a room you can walk around.
##
## This exists to answer one question with something running rather than with an
## opinion: can the thing the launcher shows in a panel be a screen in a 3D
## space that a person walks up to and sits down at? It can, and the reason is
## that nothing about the guest was ever tied to being a rectangle in a window.
## RfbClient hands out an Image; GuestView happens to draw it flat. Put the same
## image on a material and it is a monitor.
##
## What is here is deliberately unfurnished: boxes for the desk, the case and
## the chair, one warm lamp, and a screen. The point being made is about the
## pipeline and not about the art, and a room dressed up would hide which of the
## two was being demonstrated.
##
##     godot --path host/temple scenes/Room.tscn -- --vnc-port 5909
##
## WASD to walk, mouse to look, E at the desk to sit down, Esc to let the
## pointer go.
##
## WHAT SITTING DOWN WOULD ACTUALLY DO IN THE GAME
##
## Here it moves the camera to the chair and stops. In the game it is the seam
## where this scene hands over to the flat launcher - the camera finishes its
## move already square-on to the screen at the distance where 640x480 lands on
## a whole number of pixels, and the 2D view fades in over it. Nothing has to
## be re-created on the other side of that seam, because both sides are looking
## at the same texture.

const GUEST := Vector2i(640, 480)

## Where sitting down puts the eye, and what the lens does when it gets there.
##
## These two numbers are the hand-over to the flat launcher, and they are
## arithmetic rather than taste. The launcher draws the guest at twice size, so
## its 480 rows are 960 window pixels of the 1015 the window has. A screen
## 0.255m tall fills that many when
##
##     0.255 * 1015 / 960 = 2 d tan(fov/2)
##
## which at a realistic 0.60m from the glass wants 25.3 degrees. So the camera
## dollies to the chair and the lens closes from 70 to 25.3 on the way - the
## leaning-in and narrowing-down that anyone does at a monitor - and lands with
## the guest at exactly the size the 2D view draws it. The picture does not jump
## when one becomes the other: at that moment they are the same size, and both
## are the same texture.
##
## Godot's Camera3D.fov is the VERTICAL angle. Working it out horizontally gives
## 44.7 degrees here, which looks reasonable, sits the guest at about half the
## size it should be, and is wrong in a way that only a ruler catches.
const SEAT := Vector3(0, 1.06, 0.60)
const SEAT_LOOK := Vector3(0, 1.05, 0.0)
const SEAT_FOV := 25.3
const STAND_FOV := 70.0
const SIT_SECONDS := 1.2

const WALK := 2.6
const LOOK_SENSITIVITY := 0.0022
const REACH := 1.2

var rfb: RfbClient
var _screen: MeshInstance3D
var _tex := ImageTexture.new()
var _cam: Camera3D
var _body: Node3D
var _pitch := 0.0
var _sitting := false
var _sit_t := 0.0
var _sit_from := Transform3D()
var _prompt: Label

@export var vnc_host := "127.0.0.1"
@export var vnc_port := 5909


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--vnc-port" and i + 1 < args.size():
			vnc_port = args[i + 1].to_int()

	_build_room()
	_build_desk()
	_build_screen()
	_build_player()
	_build_hud()

	rfb = RfbClient.new()
	add_child(rfb)
	rfb.connect_to_guest(vnc_host, vnc_port)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# ---------------------------------------------------------------- the room

func _box(size: Vector3, at: Vector3, colour: Color,
		rough := 0.9) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	m.mesh = mesh
	m.position = at
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness = rough
	m.material_override = mat
	add_child(m)
	return m


func _build_room() -> void:
	# Four walls, a floor and a ceiling, as one box each. Inside faces are what
	# is seen, so the boxes are thin slabs rather than a hollowed cube.
	var wall := Color(0.20, 0.19, 0.17)
	_box(Vector3(6, 0.1, 6), Vector3(0, -0.05, 0), Color(0.13, 0.12, 0.11))
	_box(Vector3(6, 0.1, 6), Vector3(0, 2.7, 0), Color(0.16, 0.15, 0.14))
	_box(Vector3(6, 2.8, 0.1), Vector3(0, 1.4, -3), wall)
	_box(Vector3(6, 2.8, 0.1), Vector3(0, 1.4, 3), wall)
	_box(Vector3(0.1, 2.8, 6), Vector3(-3, 1.4, 0), wall)
	_box(Vector3(0.1, 2.8, 6), Vector3(3, 1.4, 0), wall)

	# One warm bulb, low. A room lit evenly reads as a showroom; a room lit from
	# one place reads as somewhere a person actually sat.
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(-1.4, 2.2, 1.2)
	lamp.light_color = Color(1.0, 0.86, 0.66)
	lamp.light_energy = 3.0
	lamp.omni_range = 7.0
	add_child(lamp)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.02, 0.03)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.10, 0.10, 0.13)
	e.ambient_light_energy = 0.8
	env.environment = e
	add_child(env)


func _build_desk() -> void:
	_box(Vector3(1.8, 0.05, 0.8), Vector3(0, 0.74, 0), Color(0.32, 0.24, 0.16), 0.7)
	for x in [-0.82, 0.82]:
		for z in [-0.34, 0.34]:
			_box(Vector3(0.06, 0.74, 0.06), Vector3(x, 0.37, z),
					Color(0.24, 0.18, 0.12))
	# The case, on its side under the desk, and the chair.
	_box(Vector3(0.45, 0.18, 0.42), Vector3(0.6, 0.09, -0.1),
			Color(0.75, 0.72, 0.62), 0.8)
	_box(Vector3(0.5, 0.08, 0.5), Vector3(0, 0.45, 1.05), Color(0.15, 0.15, 0.17))
	_box(Vector3(0.5, 0.5, 0.07), Vector3(0, 0.72, 1.28), Color(0.15, 0.15, 0.17))
	_box(Vector3(0.08, 0.45, 0.08), Vector3(0, 0.22, 1.05), Color(0.1, 0.1, 0.1))
	# A keyboard, because a monitor with nothing in front of it looks like a
	# display in a shop.
	_box(Vector3(0.44, 0.02, 0.16), Vector3(0, 0.775, 0.24),
			Color(0.42, 0.40, 0.36), 0.95)


# ------------------------------------------------------------- the monitor

func _build_screen() -> void:
	# The case around the tube: a shallow box with the picture set into its
	# front. A 4:3 screen 0.34m across, which is a 17-inch monitor.
	_box(Vector3(0.50, 0.42, 0.36), Vector3(0, 1.03, -0.18),
			Color(0.80, 0.77, 0.67), 0.85)
	_box(Vector3(0.54, 0.06, 0.34), Vector3(0, 0.79, -0.18),
			Color(0.74, 0.71, 0.62), 0.85)

	_screen = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(0.34, 0.255)
	# Subdivided so the vertex shader has something to bend. A flat quad with a
	# curvature shader on it is still flat.
	plane.subdivide_width = 24
	plane.subdivide_depth = 18
	plane.orientation = PlaneMesh.FACE_Z
	_screen.mesh = plane
	_screen.position = Vector3(0, 1.05, 0.005)

	var mat := ShaderMaterial.new()
	mat.shader = _crt_shader()
	# Unshaded: a CRT is a light source, not a lit surface, and lighting it
	# would put the room's lamp on the glass.
	mat.set_shader_parameter("picture", _tex)
	mat.set_shader_parameter("bulge", 0.035)
	# Gentle. At arm's length the guest's 480 rows land on a couple of hundred
	# screen pixels and a strong scanline is not a scanline any more, it is
	# aliasing - the picture crawls when the head moves.
	mat.set_shader_parameter("scanline", 0.10)
	_screen.material_override = mat
	add_child(_screen)

	# The glow the tube throws into the room. Weak and blue, because that is
	# what a screen showing a blue desktop does to a dark wall.
	var glow := OmniLight3D.new()
	glow.position = Vector3(0, 1.05, 0.25)
	glow.light_color = Color(0.55, 0.70, 1.0)
	glow.light_energy = 0.55
	glow.omni_range = 2.2
	add_child(glow)


## Curvature and scanlines, which is most of what makes a picture read as a
## tube rather than as a poster.
##
## The bulge is done in the vertex shader on real geometry, not faked in the
## fragment shader by warping the lookup: the silhouette has to curve too, or it
## is a flat screen with a distorted picture on it, which the eye catches
## immediately from any angle but straight on.
func _crt_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D picture : filter_nearest;
uniform float bulge = 0.05;
uniform float scanline = 0.2;

void vertex() {
	// Push the middle of the plane towards the viewer, falling off to nothing
	// at the edges, so the glass is a shallow cap of a sphere.
	float r = length(UV - vec2(0.5));
	VERTEX.z += bulge * (0.25 - r * r);
}

void fragment() {
	vec3 c = texture(picture, UV).rgb;
	// One dark line every other row of the source. 480 rows, so 240 pairs.
	float line = 0.5 + 0.5 * cos(UV.y * 480.0 * 3.14159);
	c *= 1.0 - scanline * line;
	// The corners of a tube are dimmer than the middle.
	float r = length(UV - vec2(0.5));
	c *= 1.0 - 0.55 * r * r;
	ALBEDO = c;
}
"""
	return sh


# -------------------------------------------------------------- the player

func _build_player() -> void:
	_body = Node3D.new()
	_body.position = Vector3(0, 1.65, 2.6)
	add_child(_body)
	_cam = Camera3D.new()
	_cam.fov = STAND_FOV
	# Looking slightly down, the way anyone walking into a room with a desk in
	# it does. Standing eyes are at 1.65 and the screen is at 1.05, so a level
	# camera puts the monitor at the bottom edge and the empty wall above it in
	# the middle of the picture.
	_pitch = -0.16
	_cam.rotation.x = _pitch
	_body.add_child(_cam)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_prompt = Label.new()
	_prompt.anchor_left = 0.5
	_prompt.anchor_right = 0.5
	_prompt.anchor_top = 0.94
	_prompt.anchor_bottom = 0.94
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	layer.add_child(_prompt)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not _sitting:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			var mm := event as InputEventMouseMotion
			_body.rotate_y(-mm.relative.x * LOOK_SENSITIVITY)
			_pitch = clampf(_pitch - mm.relative.y * LOOK_SENSITIVITY,
					-1.3, 1.3)
			_cam.rotation.x = _pitch
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_ESCAPE:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		elif k.keycode == KEY_E and _can_sit() and not _sitting:
			_sit()


func _can_sit() -> bool:
	return _body.position.distance_to(SEAT) < REACH


func _sit() -> void:
	_sitting = true
	_sit_t = 0.0
	_sit_from = Transform3D(_body.transform.basis, _body.position)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _process(delta: float) -> void:
	_update_picture()

	if _sitting:
		# The move that becomes the hand-over to the flat launcher. It ends
		# square-on to the screen, which is the frame the 2D view would fade in
		# over.
		_sit_t = minf(1.0, _sit_t + delta / SIT_SECONDS)
		var k := _sit_t * _sit_t * (3.0 - 2.0 * _sit_t)
		_body.position = _sit_from.origin.lerp(SEAT, k)
		var want := Transform3D().looking_at(SEAT_LOOK - SEAT, Vector3.UP)
		_body.basis = _sit_from.basis.slerp(want.basis, k)
		_cam.rotation.x = lerpf(_pitch, 0.0, k)
		_cam.fov = lerpf(STAND_FOV, SEAT_FOV, k)
		_prompt.text = ""
		return

	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir -= _body.global_transform.basis.z
	if Input.is_key_pressed(KEY_S):
		dir += _body.global_transform.basis.z
	if Input.is_key_pressed(KEY_A):
		dir -= _body.global_transform.basis.x
	if Input.is_key_pressed(KEY_D):
		dir += _body.global_transform.basis.x
	dir.y = 0
	if dir.length() > 0.01:
		_body.position += dir.normalized() * WALK * delta
	# Keep the walker inside the room and out of the desk.
	_body.position.x = clampf(_body.position.x, -2.7, 2.7)
	# Stopped at the chair rather than at the screen. Without this the walk goes
	# straight through the desk and out the other side, and the first thing the
	# room says about itself is that it is not solid.
	_body.position.z = clampf(_body.position.z, 1.35, 2.7)

	_prompt.text = "E - sit down" if _can_sit() else ""


## The guest's frame onto the tube.
##
## The texture is created once and then written in place. Making a new
## ImageTexture per frame works and allocates a 640x480 image thirty times a
## second, which on a machine that is also running an emulator is a poor way to
## spend memory bandwidth.
func _update_picture() -> void:
	if rfb == null or rfb.state != RfbClient.State.READY:
		return
	# Ask for the next one. The client drops the request if one is already
	# outstanding, so asking every frame keeps the pipe full without piling up.
	rfb.request_update()
	var img := rfb.get_frame_image()
	if img == null:
		return
	if _tex.get_width() != img.get_width():
		_tex.set_image(img)
		(_screen.material_override as ShaderMaterial).set_shader_parameter(
				"picture", _tex)
	else:
		_tex.update(img)
