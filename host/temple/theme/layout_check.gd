extends Node

## Proves the guest gets its 640x480 with nothing left over.
##
## The whole reason the launcher's layout was wrong before is that it was never
## measured against the scene that actually runs. GuestView takes the size of
## the control it is in, picks the largest whole-number scale that fits, and
## centres the picture in whatever is left; if the control is not an exact
## multiple of 640x480, the remainder is a band the host cursor travels through
## while the guest's cursor is already pinned at the edge. So the number to
## check is not the window size and not the viewport size - it is the size of
## the node named Guest, and it has to be exactly 640x480.
##
## HOW THIS RUNS WITHOUT WAKING THE GUEST
##
## scenes/Main.tscn is the real scene, so this loads the real scene - a
## hand-rebuilt copy is how the previous measurement of this same layout came
## out three times too large. But Main.gd's _ready opens an RFB connection to
## the guest's VNC port and a socket to the bridge, and a second client on
## either wire perturbs anything anyone else is measuring. Instantiating a
## PackedScene does not run _ready; that happens on entering the tree. So the
## script is taken off the root in between, and Main._ready never runs. Every
## other node in the scene is untouched and its own _ready does run, which is
## what makes the numbers below real.
##
## CampaignPanel.bind is called here because Main normally does it, and it
## changes the geometry: it selects the first unfinished task, whose detail text
## is what used to widen the panel and slide the guest sideways.
##
##   godot --headless --path host/temple res://theme/layout_check.tscn
##
## Exits non-zero and says which number is wrong if it ever stops being true.

const NATIVE := Vector2i(640, 480)

var _failures: Array[String] = []


func _ready() -> void:
	var packed: PackedScene = load("res://scenes/Main.tscn")
	var main: Control = packed.instantiate()
	main.set_script(null)
	add_child(main)

	var panel: CampaignPanel = main.get_node("Split/CampaignPanel")
	var campaign := Campaign.new()
	var n := campaign.load_from("res://data/tasks")
	panel.bind(campaign)

	# Two frames: one for the containers to sort, one for the resize that
	# binding a campaign causes to settle.
	await get_tree().process_frame
	await get_tree().process_frame

	var win := get_window()
	var guest: Control = main.get_node("Split/Guest")
	var bar: Control = main.get_node("Bar")

	print("tasks loaded          %d" % n)
	print("window size           %s" % win.size)
	print("content scale size    %s" % win.content_scale_size)
	print("content scale factor  %s" % win.content_scale_factor)
	print("root viewport         %s" % get_viewport().get_visible_rect().size)
	print("canvas transform      %s" % get_viewport().get_screen_transform())
	print("Bar   rect            %s" % bar.get_rect())
	print("Guest rect            %s" % guest.get_rect())
	print("Panel rect            %s" % panel.get_rect())
	print("Panel combined min    %s" % panel.get_combined_minimum_size())

	var scale := GuestView.integer_scale(guest.size, NATIVE)
	var shown := Vector2(NATIVE) * scale
	var origin: Vector2 = ((guest.size - shown) * 0.5).floor()
	print("guest scale           %d" % scale)
	print("guest picture         %s at %s" % [shown, origin])
	print("dead margin l/r t/b   %s %s" % [origin.x, origin.y])

	_expect("guest control is 640x480", guest.size, Vector2(NATIVE))
	_expect("guest letterbox is zero", origin, Vector2.ZERO)
	_expect("guest scale is 1", scale, 1)
	_expect("panel is 34 cells wide", panel.size.x, 272.0)
	_expect("panel does not grow with its text", panel.get_combined_minimum_size().x, 272.0)
	_expect("status line is one cell tall", bar.size.y, 8.0)
	_expect("guest sits on the cell grid", fmod(guest.position.x, 8.0), 0.0)
	_expect("panel sits on the cell grid", fmod(panel.position.x, 8.0), 0.0)

	# Every rect the player sees has to be a whole number of cells, or the
	# glyphs inside it stop lining up with the guest's.
	for c: Control in [bar, guest, panel]:
		_expect("%s is a whole number of cells" % c.name,
				Vector2(fmod(c.size.x, 8.0), fmod(c.size.y, 8.0)), Vector2.ZERO)

	_check_no_default_styleboxes(main)

	if _failures.is_empty():
		print("OK")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL  " + f)
		get_tree().quit(1)


func _expect(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		_failures.append("%s: got %s, wanted %s" % [what, got, want])


## Every stylebox in the scene has to come from temple.tres.
##
## A theme item that is not overridden falls through to Godot's own default
## theme, which draws rounded corners, gradients and drop shadows - the three
## things this operating system does not have anywhere. One missed stylebox on
## one control is enough to give the whole panel away, and it is invisible in a
## diff. So walk what is really on screen, including the controls Godot builds
## for itself like the scrollbar inside a list, and check every stylebox name
## the default theme knows about for that class.
##
## Styleboxes and icons only: a colour or a constant that falls through is a
## wrong colour, which review catches, while a stylebox that falls through is a
## different visual language.
func _check_no_default_styleboxes(root: Control) -> void:
	var theme: Theme = root.theme
	var defaults := ThemeDB.get_default_theme()
	var seen := {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children(true):
			stack.append(child)
		if not node is Control:
			continue
		var control := node as Control
		var cls := control.get_class()
		var variation := String(control.theme_type_variation)
		var key := "%s/%s" % [cls, variation]
		if seen.has(key):
			continue
		seen[key] = true
		for data_type in [Theme.DATA_TYPE_STYLEBOX, Theme.DATA_TYPE_ICON]:
			for item in defaults.get_theme_item_list(data_type, cls):
				# Godot's own default for a few icons is an empty texture -
				# the arrows at the ends of a scrollbar, which it has not drawn
				# for years. Falling through to nothing is not falling through
				# to a different visual language, so those do not count.
				if data_type == Theme.DATA_TYPE_ICON \
						and defaults.get_icon(item, cls).get_size() == Vector2.ZERO:
					continue
				var covered := theme.has_theme_item(data_type, item, cls) \
						or (variation != "" and theme.has_theme_item(data_type, item, variation))
				if not covered:
					_failures.append("%s%s falls back to Godot's default %s"
							% [cls, "" if variation == "" else " (%s)" % variation, item])
