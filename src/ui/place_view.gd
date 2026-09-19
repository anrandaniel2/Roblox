class_name RBXPlaceView
extends SubViewportContainer
## The 3D half of the app: a SubViewport holding the imported place, with an
## orbit camera that behaves the same on a desktop and on a phone.
##
## The view owns its own `World3D`, so a place can never leak lights or
## environment settings into the UI. Input is read from `_unhandled_input`, which
## means the panels drawn on top get first refusal: dragging a slider never spins
## the camera.

signal scene_built(stats: Dictionary)

const MIN_DISTANCE := 4.0
const MAX_DISTANCE := 20000.0
const PITCH_LIMIT := 1.45

var place_root: Node3D

var _viewport: SubViewport
var _pivot: Node3D
var _camera: Camera3D
var _sun: DirectionalLight3D
var _target: Vector3 = Vector3.ZERO
var _yaw: float = -0.7
var _pitch: float = -0.45
var _distance: float = 60.0
var _dragging: bool = false
var _touches: Dictionary = {}
var _pinch_spread: float = 0.0
var _pinch_distance: float = 0.0


func _ready() -> void:
	name = "PlaceView"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS

	_viewport = SubViewport.new()
	_viewport.name = "Viewport"
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.handle_input_locally = false
	_viewport.msaa_3d = RbxSettings.msaa
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	var environment := WorldEnvironment.new()
	environment.name = "Environment"
	environment.environment = load("res://data/default_environment.tres")
	_viewport.add_child(environment)

	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	_sun.light_energy = 1.15
	_sun.shadow_enabled = RbxSettings.shadows
	_viewport.add_child(_sun)

	_pivot = Node3D.new()
	_pivot.name = "CameraPivot"
	_viewport.add_child(_pivot)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.fov = RbxSettings.fov
	_camera.near = 0.1
	_camera.far = maxf(500.0, RbxSettings.draw_distance)
	_camera.current = true
	_pivot.add_child(_camera)

	place_root = Node3D.new()
	place_root.name = "Place"
	_viewport.add_child(place_root)

	_apply_camera()
	RbxApp.place_loaded.connect(_on_place_loaded)
	RbxApp.place_closed.connect(_on_place_closed)


# ---------------------------------------------------------------------------
# Loading a place into the viewport
# ---------------------------------------------------------------------------

func _on_place_loaded(place: RBXPlace) -> void:
	show_place(place)


func _on_place_closed() -> void:
	clear()
	scene_built.emit({})


## Replaces whatever is on screen with `place`.
func show_place(place: RBXPlace) -> void:
	clear()
	var builder := RBXSceneBuilder.new(RbxSettings)
	var stats := builder.build(place, place_root)
	frame_content()
	scene_built.emit(stats)
	var capped := int(stats.get("capped", 0))
	var summary := "Imported %d nodes (%d parts, %d skipped" % [
		int(stats.get("nodes", 0)),
		int(stats.get("parts", 0)),
		int(stats.get("skipped", 0)),
	]
	if capped > 0:
		summary += ", %d capped by the instance limit" % capped
	RbxLog.info(summary + ").", "importer")
	for warning: String in stats.get("warnings", PackedStringArray()):
		RbxLog.warn(warning, "importer")


func clear() -> void:
	for child in place_root.get_children():
		place_root.remove_child(child)
		child.queue_free()


# ---------------------------------------------------------------------------
# Camera
# ---------------------------------------------------------------------------

func _apply_camera() -> void:
	_pivot.position = _target
	_pivot.rotation = Vector3(_pitch, _yaw, 0.0)
	_camera.position = Vector3(0.0, 0.0, _distance)


## Points the camera at everything that was imported.
func frame_content() -> void:
	var bounds := _content_bounds()
	if bounds.size.length() <= 0.01:
		_target = Vector3.ZERO
		_distance = 60.0
	else:
		_target = bounds.get_center()
		_distance = clampf(bounds.size.length() * 1.05, MIN_DISTANCE, MAX_DISTANCE)
	_pitch = -0.45
	_apply_camera()


func _content_bounds() -> AABB:
	var box := AABB()
	var found := false
	var stack: Array[Node] = [place_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			if mesh_node.mesh == null:
				continue
			var local := mesh_node.get_aabb()
			var world := mesh_node.global_transform * local
			box = world if not found else box.merge(world)
			found = true
	return box


func focus_on_instance(id: int) -> void:
	for node in place_root.get_children():
		_focus_walk(node, id)


func _focus_walk(node: Node, id: int) -> void:
	if node is MeshInstance3D and node.get_meta("rbx_id", -1) == id:
		var bounds := (node as MeshInstance3D).global_transform * (node as MeshInstance3D).get_aabb()
		_target = bounds.get_center()
		_distance = clampf(bounds.size.length() * 2.2, MIN_DISTANCE, MAX_DISTANCE)
		_apply_camera()
		return
	for child in node.get_children():
		_focus_walk(child, id)


# ---------------------------------------------------------------------------
# Input: drag to orbit, wheel or pinch to zoom
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventScreenTouch:
		_handle_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				_zoom(-1.0)
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_zoom(1.0)
		_:
			pass


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if not _dragging:
		return
	_orbit(event.relative)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
	else:
		_touches.erase(event.index)
	if _touches.size() < 2:
		_pinch_spread = 0.0
	_dragging = _touches.size() == 1


func _handle_drag(event: InputEventScreenDrag) -> void:
	_touches[event.index] = event.position
	if _touches.size() >= 2:
		_pinch()
		return
	_orbit(event.relative)


func _orbit(relative: Vector2) -> void:
	var speed := 0.006
	_yaw -= relative.x * speed
	_pitch = clampf(_pitch - relative.y * speed, -PITCH_LIMIT, PITCH_LIMIT)
	_apply_camera()


func _pinch() -> void:
	var keys := _touches.keys()
	var first: Vector2 = _touches[keys[0]]
	var second: Vector2 = _touches[keys[1]]
	var spread := first.distance_to(second)
	if spread <= 1.0:
		return
	if _pinch_spread <= 1.0:
		# First frame of the gesture: remember how far apart the fingers are so
		# the camera only moves by how much they move.
		_pinch_spread = spread
		_pinch_distance = _distance
		return
	_distance = clampf(_pinch_distance * (_pinch_spread / spread), MIN_DISTANCE, MAX_DISTANCE)
	_apply_camera()


func _zoom(steps: float) -> void:
	_distance = clampf(_distance * pow(1.15, steps), MIN_DISTANCE, MAX_DISTANCE)
	_apply_camera()
