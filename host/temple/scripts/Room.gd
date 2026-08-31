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

## How much wider the glass is than the raster on it.
##
## The picture bows outward, and it has to bow into something. With the glass
## exactly the size of the picture there is nowhere for the curve to go and the
## corners get pushed off the panel - which is the first thing anyone noticed
## about this scene: the corners of the desktop were cut off diagonally and the
## work was underneath them.
const GLASS_MARGIN := 1.12

## The glass, as the shader sees it. These three are read by the shader and by
## the code that works out where on the guest the mouse is pointing, and they
## have to be the same numbers or the pointer lands somewhere the picture is not.
const BULGE := 0.030
const CURVE := 0.030
const SCANLINE := 0.10

## The raster, in metres, before the margin.
const GLASS := Vector2(0.34, 0.255)

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
const SEAT_FOV := 26.1
const STAND_FOV := 70.0
const SIT_SECONDS := 1.2

const WALK := 2.6
const LOOK_SENSITIVITY := 0.0022
const REACH := 1.2

var rfb: RfbClient
## The pointer goes down this rather than over the frame connection, for the
## reason the flat launcher found out the hard way: RFB moves a PS/2 mouse by
## deltas, and deltas accumulate error until the guest's cursor is somewhere
## other than the hand. The layer takes an absolute position instead.
var bridge: BridgeClient
var _seated := false
var _last_sent := Vector2i(-1, -1)
var _buttons := 0
var _leave_hint_until := 0
## --trace prints every pointer position sent, for checking the mapping.
var _trace := false

## How long the way out stays on screen after sitting down. Long enough to read
## once, short enough not to be part of the furniture.
const LEAVE_HINT_MSEC := 4000


func _t_leave() -> String:
	return "F12 - get up"
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
@export var bridge_host := "127.0.0.1"
@export var bridge_port := 4556


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--vnc-port" and i + 1 < args.size():
			vnc_port = args[i + 1].to_int()
		if args[i] == "--bridge-port" and i + 1 < args.size():
			bridge_port = args[i + 1].to_int()
		if args[i] == "--trace":
			_trace = true

	_build_room()
	_build_desk()
	_build_screen()
	_build_player()
	_build_hud()

	rfb = RfbClient.new()
	add_child(rfb)
	rfb.connect_to_guest(vnc_host, vnc_port)

	bridge = BridgeClient.new()
	add_child(bridge)
	bridge.connect_to_guest(bridge_host, bridge_port)

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# ---------------------------------------------------------------- the room

## One box, wearing one of the room's textures.
##
## `tex` names a file in res://textures. `tiles_per_metre` decides how often it
## repeats: a BoxMesh maps each face across the whole 0..1 of the texture, so
## without this a six metre wall and a fifty centimetre monitor case wear the
## same picture at wildly different scales and neither looks like the material
## it is meant to be.
##
## `tint` multiplies the texture, for the places where the same plastic wants to
## be a shade darker rather than a texture of its own.
func _box(size: Vector3, at: Vector3, tex: String,
		tiles_per_metre := 1.2, tint := Color(1, 1, 1)) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	# Cut big faces up. Affine mapping shears across a whole triangle, so a wall
	# drawn as two of them warps into a diagonal pattern that reads as wallpaper
	# rather than as plaster. Subdividing is what was actually done about this at
	# the time - the error is per triangle, so smaller triangles carry less of
	# it - and it costs nothing here: the room is a dozen boxes.
	# Six a metre, capped. A wall wants the cap; the monitor case wants the rate,
	# because at arm's length its front is a big triangle on the screen even
	# though it is small in the room, and that is where the shear shows most.
	mesh.subdivide_width = clampi(int(size.x * 6.0), 1, 12)
	mesh.subdivide_height = clampi(int(size.y * 6.0), 1, 12)
	mesh.subdivide_depth = clampi(int(size.z * 6.0), 1, 12)
	m.mesh = mesh
	m.position = at
	m.material_override = _psx_material(tex, size, tiles_per_metre, tint)
	add_child(m)
	return m


var _psx: Shader = null
var _tex_cache: Dictionary = {}


func _psx_material(tex: String, size: Vector3, tiles: float,
		tint: Color) -> ShaderMaterial:
	if _psx == null:
		_psx = load("res://shaders/psx.gdshader")
	if not _tex_cache.has(tex):
		var path := "res://textures/%s.png" % tex
		_tex_cache[tex] = load(path) if ResourceLoader.exists(path) else null
	var mat := ShaderMaterial.new()
	mat.shader = _psx
	mat.set_shader_parameter("albedo", _tex_cache[tex])
	# One number for both axes, from the largest face, which is close enough for
	# boxes and keeps the texture square. Getting this per-face would mean
	# building the mesh by hand, and the wrong repeat on the thin edge of a slab
	# is not something anybody will see.
	var span: float = maxf(maxf(size.x, size.y), size.z)
	mat.set_shader_parameter("uv_scale", Vector2.ONE * maxf(1.0, span * tiles))
	mat.set_shader_parameter("tint", tint)
	return mat


func _build_room() -> void:
	# Four walls, a floor and a ceiling, as one box each. Inside faces are what
	# is seen, so the boxes are thin slabs rather than a hollowed cube.
	_box(Vector3(6, 0.1, 6), Vector3(0, -0.05, 0), "floor", 1.4)
	_box(Vector3(6, 0.1, 6), Vector3(0, 2.7, 0), "ceiling", 1.0)
	for wall in [
			[Vector3(6, 2.8, 0.1), Vector3(0, 1.4, -3)],
			[Vector3(6, 2.8, 0.1), Vector3(0, 1.4, 3)],
			[Vector3(0.1, 2.8, 6), Vector3(-3, 1.4, 0)],
			[Vector3(0.1, 2.8, 6), Vector3(3, 1.4, 0)]]:
		_box(wall[0], wall[1], "wall", 0.9)

	# One warm bulb, low. A room lit evenly reads as a showroom; a room lit from
	# one place reads as somewhere a person actually sat.
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(-1.4, 2.2, 1.2)
	lamp.light_color = Color(1.0, 0.86, 0.66)
	lamp.light_energy = 2.1
	lamp.omni_range = 7.0
	add_child(lamp)

	# A second, much dimmer lamp behind where the player comes in. Not for
	# looks: the one bulb is above the chair, so the chair's back - a vertical
	# face lit edge-on - comes out at zero, and a black rectangle in front of
	# the desk reads as a hole in the floor rather than as furniture. Raising
	# the ambient instead did nothing visible in the compatibility renderer,
	# which is the one this project uses.
	var fill := OmniLight3D.new()
	fill.position = Vector3(0.8, 2.0, 2.6)
	fill.light_color = Color(0.72, 0.74, 0.85)
	fill.light_energy = 0.7
	fill.omni_range = 6.0
	add_child(fill)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.02, 0.03)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Enough that nothing in the room is pure black. One bulb above the chair
	# leaves its back - a vertical face lit edge-on - at zero, and a black
	# rectangle in front of the desk does not read as a chair, it reads as a
	# hole in the floor. This lifts it without flattening the room, which is
	# what a second lamp would have done.
	e.ambient_light_color = Color(0.16, 0.15, 0.18)
	e.ambient_light_energy = 1.8
	env.environment = e
	add_child(env)


func _build_desk() -> void:
	_box(Vector3(1.8, 0.05, 0.8), Vector3(0, 0.74, 0), "desk", 1.1)
	for x in [-0.82, 0.82]:
		for z in [-0.34, 0.34]:
			_box(Vector3(0.06, 0.74, 0.06), Vector3(x, 0.37, z), "desk", 2.0,
					Color(0.72, 0.72, 0.72))
	# The case, on its side under the desk, and the chair.
	_box(Vector3(0.45, 0.18, 0.42), Vector3(0.6, 0.09, -0.1), "case", 3.0)
	# The chair, in a grey that catches the lamp. Nearly black was truer to an
	# office chair and read as a hole cut out of the room: it is the closest
	# thing to the camera on the way in, so it fills a third of the frame, and
	# an unlit third of the frame is not furniture, it is a missing wall.
	_box(Vector3(0.5, 0.08, 0.5), Vector3(0, 0.45, 1.15), "chair", 3.0)
	# The back is low enough to see the desk over. A real one is taller; a real
	# one is also not between the viewer and the thing they came to look at.
	_box(Vector3(0.5, 0.40, 0.07), Vector3(0, 0.66, 1.38), "chair", 3.0)
	_box(Vector3(0.08, 0.45, 0.08), Vector3(0, 0.22, 1.15), "case", 4.0,
			Color(0.35, 0.35, 0.38))
	# A keyboard, because a monitor with nothing in front of it looks like a
	# display in a shop.
	_box(Vector3(0.44, 0.02, 0.16), Vector3(0, 0.775, 0.24), "case", 6.0,
			Color(0.62, 0.60, 0.56))


# ------------------------------------------------------------- the monitor

func _build_screen() -> void:
	# The case around the tube: a shallow box with the picture set into its
	# front. A 4:3 screen 0.34m across, which is a 17-inch monitor.
	_box(Vector3(0.50, 0.42, 0.36), Vector3(0, 1.03, -0.18), "plastic", 3.0)
	_box(Vector3(0.54, 0.06, 0.34), Vector3(0, 0.79, -0.18), "plastic", 3.0,
			Color(0.92, 0.92, 0.92))

	_screen = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	# The glass, not the picture. A tenth larger than the raster on purpose:
	# bowing the image outward needs somewhere for it to bow into, and without
	# the margin the only way to make a curve is to push the corners off the
	# panel and lose them - which is exactly what the first version did.
	plane.size = GLASS * GLASS_MARGIN
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
	mat.set_shader_parameter("bulge", BULGE)
	mat.set_shader_parameter("curve", CURVE)
	mat.set_shader_parameter("margin", GLASS_MARGIN)
	# Gentle. At arm's length the guest's 480 rows land on a couple of hundred
	# screen pixels and a strong scanline is not a scanline any more, it is
	# aliasing - the picture crawls when the head moves.
	mat.set_shader_parameter("scanline", SCANLINE)
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
uniform float bulge = 0.03;
uniform float curve = 0.085;
uniform float margin = 1.12;
uniform float scanline = 0.10;

void vertex() {
	// A cap of a sphere: the middle stands proud of the rim and the rim itself
	// stays where the mesh put it. The first version used 0.25 - r*r, which is
	// negative past the middle of an edge, so the four corners of the glass
	// sank almost a centimetre INTO the case and were swallowed by it. That is
	// where the diagonal cut across the corners of the desktop came from.
	float r = length(UV - vec2(0.5));
	VERTEX.z += bulge * (1.0 - r * r / 0.5);
}

void fragment() {
	// From the glass to the raster. The glass is `margin` times larger, so the
	// picture starts out inside it, and the barrel term then pushes the edges
	// outward into that room. Every pixel of the guest ends up somewhere on the
	// glass; what is left over at the corners is dark, which is what the corner
	// of a tube looks like.
	vec2 c = (UV - vec2(0.5)) * 2.0 * margin;
	float r2 = dot(c, c);
	c *= 1.0 - curve * r2;
	vec2 uv = c * 0.5 + vec2(0.5);

	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		ALBEDO = vec3(0.02, 0.02, 0.025);
	} else {
		vec3 col = texture(picture, uv).rgb;
		// One dark line every other row of the source. 480 rows, so 240 pairs.
		float line = 0.5 + 0.5 * cos(uv.y * 480.0 * 3.14159);
		col *= 1.0 - scanline * line;
		// A tube is dimmer towards its edges. Gently - the old 0.55 took a
		// quarter of the brightness out of the corners, and there is work in
		// the corners of this desktop.
		col *= 1.0 - 0.22 * r2;
		ALBEDO = col;
	}
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
	# A Control over the whole window will happily swallow the mouse before
	# _unhandled_input ever sees it.
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	layer.add_child(_prompt)


func _unhandled_input(event: InputEvent) -> void:
	if _seated:
		_desk_input(event)
		return

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


# ------------------------------------------------------- sitting at the desk

## Everything the player does once they are in the chair goes to the guest.
##
## Which is the whole point and was missing: before this the room was a picture
## of a computer. The one thing that does not go through is the key that gets
## you out of the chair, and it is F12 because that is already what the flat
## launcher uses to hand the keyboard back (KeyMap.is_release_capture).
func _desk_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ev := event as InputEventKey
		if ev.pressed and not ev.echo and KeyMap.is_release_capture(ev):
			_stand()
			return
		if not ev.echo:
			if ev.pressed:
				Sound.key_down(ev.keycode == KEY_SPACE)
			else:
				Sound.key_up()
		_send_key(ev)
		return

	if event is InputEventMouseMotion:
		_point_at((event as InputEventMouseMotion).position)
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			Sound.mouse_down()
		else:
			Sound.mouse_up()
		# Bit 0 left, bit 1 right. No middle: TempleOS's mouse state has two
		# buttons (Kernel/KernelA.HH:3010-3011) and inventing a third would mean
		# deciding what it does.
		var bit := 0
		if mb.button_index == MOUSE_BUTTON_LEFT:
			bit = 1
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			bit = 2
		if bit != 0:
			if mb.pressed:
				_buttons |= bit
			else:
				_buttons &= ~bit
		_point_at(mb.position, true)


func _send_key(ev: InputEventKey) -> void:
	if _trace and ev.pressed and not ev.echo:
		print("key  code %d  physical %d  unicode %d (%s)  shift %s  ->  keysym 0x%X"
				% [ev.keycode, ev.physical_keycode, ev.unicode,
				   char(ev.unicode) if ev.unicode >= 32 else "?",
				   ev.shift_pressed, KeyMap.keysym_for(ev)])
	rfb.send_key_event(ev)


## Where on the guest the mouse is pointing, and tell it.
##
## The awkward part is that the glass is not flat and the picture on it is not
## square: the mesh bulges towards the viewer and the raster is sampled through
## a barrel term. So the ray is walked onto the bulged surface - two rounds is
## plenty, the displacement is thirty millimetres - and then put through exactly
## the same warp the shader uses, which is why those constants live in one place.
func _point_at(mouse: Vector2, urgent: bool = false) -> void:
	var p := _guest_pixel(mouse)
	if p.x < 0:
		return
	if p == _last_sent and not urgent:
		return
	_last_sent = p
	if bridge.supports_pointer():
		bridge.send_pointer(p.x, p.y, _buttons)
	else:
		rfb.send_pointer(p.x, p.y, _buttons)
	if _trace:
		print("pointer %s  buttons %d  %s"
				% [p, _buttons, "bridge" if bridge.supports_pointer() else "rfb"])


func _guest_pixel(mouse: Vector2) -> Vector2i:
	if _screen == null or _cam == null:
		return Vector2i(-1, -1)
	var xf := _screen.global_transform
	var inv := xf.affine_inverse()
	var n := xf.basis.z.normalized()
	var from := _cam.project_ray_origin(mouse)
	var dir := _cam.project_ray_normal(mouse)
	var denom := dir.dot(n)
	if absf(denom) < 1e-6:
		return Vector2i(-1, -1)

	var size := GLASS * GLASS_MARGIN
	var u := Vector2(-1, -1)
	var z_off := 0.0
	for _i in 2:
		var t := (xf.origin + n * z_off - from).dot(n) / denom
		if t <= 0.0:
			return Vector2i(-1, -1)
		var local := inv * (from + dir * t)
		u = Vector2(local.x / size.x + 0.5, 0.5 - local.y / size.y)
		var r := (u - Vector2(0.5, 0.5)).length()
		z_off = BULGE * (1.0 - r * r / 0.5)

	# The same warp the shader applies, in the same direction.
	var c := (u - Vector2(0.5, 0.5)) * 2.0 * GLASS_MARGIN
	c *= 1.0 - CURVE * c.length_squared()
	var tex := c * 0.5 + Vector2(0.5, 0.5)
	if tex.x < 0.0 or tex.x > 1.0 or tex.y < 0.0 or tex.y > 1.0:
		return Vector2i(-1, -1)
	return Vector2i(clampi(int(tex.x * GUEST.x), 0, GUEST.x - 1),
			clampi(int(tex.y * GUEST.y), 0, GUEST.y - 1))


func _stand() -> void:
	rfb.release_held_keys()
	_seated = false
	_sitting = false
	_buttons = 0
	_last_sent = Vector2i(-1, -1)
	_body.position = Vector3(0, 1.65, 1.9)
	_body.rotation = Vector3.ZERO
	_pitch = -0.16
	_cam.rotation.x = _pitch
	_cam.fov = STAND_FOV
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


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
		if _sit_t >= 1.0:
			# Arrived. From here the keyboard and the mouse belong to the guest,
			# and the host's pointer is hidden so the only cursor on the glass is
			# the one TempleOS draws - the same rule the flat launcher follows
			# over its own view of the guest.
			_sitting = false
			_seated = true
			Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
			_prompt.text = _t_leave()
			_leave_hint_until = Time.get_ticks_msec() + LEAVE_HINT_MSEC
		return

	if _seated:
		# The hint fades out of the way rather than sitting over the work.
		if _leave_hint_until > 0 and Time.get_ticks_msec() > _leave_hint_until:
			_leave_hint_until = 0
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
