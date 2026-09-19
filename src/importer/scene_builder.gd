class_name RBXSceneBuilder
extends RefCounted
## Turns a parsed `RBXPlace` into Godot scene nodes.
##
## The importer is deliberately a plain object rather than a node: it can be
## driven by the UI, by a test or by a background thread, and it never touches
## the scene tree except through the `parent` it is handed.
##
## Supported today
##   * BasePart shapes: block, ball, cylinder, wedge, corner wedge, truss
##   * CFrame → Transform3D, colours, transparency and a rough material bucket
##   * Models and folders as grouping nodes, lights, spawn locations
##   * Anchored parts become static bodies, unanchored parts rigid bodies
## Not yet: meshes (no asset fetching), terrain, CSG, GUI, particles.

## Roblox's `Enum.PartType`.
const SHAPE_BALL := 0
const SHAPE_BLOCK := 1
const SHAPE_CYLINDER := 2
const SHAPE_WEDGE := 3
const SHAPE_CORNER_WEDGE := 4

## `Enum.Material` values that change how a part is shaded.
const MATERIAL_GLASS := 1568
const MATERIAL_NEON := 288
const MATERIAL_METAL := 1088
const MATERIAL_FORCE_FIELD := 1584

const GROUPING_CLASSES := [
	"Model", "Folder", "Configuration", "Workspace", "Lighting", "ReplicatedStorage",
	"ServerStorage", "ServerScriptService", "StarterGui", "StarterPack", "StarterPlayer",
	"Players", "Teams", "SoundService", "Terrain", "Camera", "WorldModel", "Actor",
]
const PART_CLASSES := [
	"Part", "WedgePart", "CornerWedgePart", "TrussPart", "Platform", "Seat",
	"VehicleSeat", "SpawnLocation", "MeshPart", "UnionOperation",
	"IntersectOperation", "NegateOperation", "PartOperation",
]
const LIGHT_CLASSES := ["PointLight", "SpotLight", "SurfaceLight"]
const SKIP_CLASSES := [
	"Script", "LocalScript", "ModuleScript", "RemoteEvent", "RemoteFunction",
	"BindableEvent", "BindableFunction", "ScreenGui", "Frame", "TextLabel",
	"TextButton", "ImageLabel", "ImageButton", "TextBox", "UIListLayout",
	"UIGridLayout", "UIPadding", "UICorner", "UIStroke", "NumberValue",
	"StringValue", "BoolValue", "IntValue", "ObjectValue", "CFrameValue",
	"Vector3Value", "Color3Value", "BrickColorValue", "NumberRangeValue",
	"RayValue", "Sound", "Animation", "AnimationController", "Motor6D", "Weld",
	"WeldConstraint", "Snap", "ManualWeld", "Motor", "Attachment", "Humanoid",
	"Decal", "Texture", "ParticleEmitter", "Fire", "Smoke", "Sparkles", "BillboardGui",
]

var _settings: Node = null
var _warned: Dictionary = {}


func _init(settings: Node = null) -> void:
	_settings = settings


## Builds `place` under `parent` and returns a stats dictionary:
## `{nodes, parts, skipped, warnings, capped}`.
func build(place: RBXPlace, parent: Node3D) -> Dictionary:
	var stats := {
		"nodes": 0,
		"parts": 0,
		"capped": 0,
		"skipped": 0,
		"warnings": PackedStringArray(),
	}
	if place == null or parent == null:
		return stats

	var limit := _max_instances()
	var budget := [limit, 0]
	for root: RBXInstance in place.roots:
		_build_instance(root, parent, stats, budget)

	stats["warnings"] = _warned.keys()
	return stats


func _build_instance(instance: RBXInstance, parent: Node3D, stats: Dictionary, budget: Array) -> Node3D:
	if budget[0] > 0 and budget[1] >= budget[0]:
		stats["capped"] = int(stats["capped"]) + 1
		return null
	budget[1] = int(budget[1]) + 1

	var node := _make_node(instance, stats)
	if node == null:
		# The instance does not own a node of its own, but its children still
		# belong in the tree, so they are built under the same parent.
		for child: RBXInstance in instance.children:
			_build_instance(child, parent, stats, budget)
		return null

	stats["nodes"] = int(stats["nodes"]) + 1
	parent.add_child(node)
	for child: RBXInstance in instance.children:
		_build_instance(child, node, stats, budget)
	return node


func _make_node(instance: RBXInstance, stats: Dictionary) -> Node3D:
	var rbx_class := instance.rbx_class

	if instance.is_a("BasePart") or PART_CLASSES.has(rbx_class):
		stats["parts"] = int(stats["parts"]) + 1
		return _build_part(instance)

	if LIGHT_CLASSES.has(rbx_class):
		return _build_light(instance)

	if GROUPING_CLASSES.has(rbx_class) or instance.is_a("Model"):
		var group := Node3D.new()
		group.name = _node_name(instance)
		return group

	if SKIP_CLASSES.has(rbx_class):
		stats["skipped"] = int(stats["skipped"]) + 1
		return null

	# Unknown classes keep their children so a place never loses geometry just
	# because one class is not implemented yet.
	_warn("Unsupported class '%s' — its children were kept." % rbx_class)
	var fallback := Node3D.new()
	fallback.name = _node_name(instance)
	return fallback


# ---------------------------------------------------------------------------
# Parts
# ---------------------------------------------------------------------------

func _build_part(instance: RBXInstance) -> Node3D:
	var size := _size_of(instance)
	var transform := _transform_of(instance)
	var anchored := bool(_property(instance, "Anchored", true))
	var simulate := anchored or not _setting("simulate_unanchored", true)

	if rbx_class_needs_mesh(instance):
		_warn("Meshes are not fetched yet — '%s' is shown as a block." % instance.rbx_class)

	var body: Node3D
	if not _setting("build_collision", true) or not _wants_collision(instance, transform):
		body = Node3D.new()
	else:
		body = _make_body(anchored, simulate, size)

	body.name = _node_name(instance)
	body.transform = transform
	# Lets the UI focus a part straight from the explorer or a log line.
	body.set_meta("rbx_id", instance.id)
	body.set_meta("rbx_class", instance.rbx_class)

	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.mesh = _make_mesh(instance, size)
	visual.material_override = _make_material(instance)
	var visual_pivot := Node3D.new()
	visual_pivot.name = "Shape"
	# Roblox cylinders run along X, Godot's along Y.
	if _shape_of(instance) == SHAPE_CYLINDER:
		visual_pivot.rotation = Vector3(0.0, 0.0, PI * 0.5)
	visual_pivot.add_child(visual)
	body.add_child(visual_pivot)

	if body is CollisionObject3D:
		var collision := CollisionShape3D.new()
		collision.name = "Collision"
		collision.shape = _make_shape(instance, size)
		var collision_pivot := Node3D.new()
		collision_pivot.name = "Shape"
		if _shape_of(instance) == SHAPE_CYLINDER:
			collision_pivot.rotation = Vector3(0.0, 0.0, PI * 0.5)
		collision_pivot.add_child(collision)
		body.add_child(collision_pivot)

	return body


func rbx_class_needs_mesh(instance: RBXInstance) -> bool:
	return instance.rbx_class == "MeshPart" \
		or instance.rbx_class == "UnionOperation" \
		or instance.rbx_class == "IntersectOperation" \
		or instance.rbx_class == "PartOperation"


func _make_body(anchored: bool, simulate: bool, size: Vector3) -> Node3D:
	if anchored or not simulate:
		var static_body := StaticBody3D.new()
		static_body.collision_layer = 1
		static_body.collision_mask = 0
		return static_body

	var rigid := RigidBody3D.new()
	rigid.collision_layer = 1
	rigid.collision_mask = 1
	rigid.mass = maxf(0.01, size.x * size.y * size.z * 0.7)
	return rigid


func _make_mesh(instance: RBXInstance, size: Vector3) -> Mesh:
	var absolute := Vector3(absf(size.x), absf(size.y), absf(size.z))
	var shape := _shape_of(instance)
	if shape == SHAPE_BALL:
		var sphere := SphereMesh.new()
		sphere.radius = maxf(absolute.x, absolute.z) * 0.5
		sphere.height = absolute.y
		sphere.radial_segments = 24
		sphere.rings = 12
		return sphere
	if shape == SHAPE_CYLINDER:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = maxf(absolute.z, 0.01) * 0.5
		cylinder.bottom_radius = cylinder.top_radius
		cylinder.height = maxf(absolute.x, 0.01)
		cylinder.radial_segments = 24
		return cylinder
	if shape == SHAPE_WEDGE or shape == SHAPE_CORNER_WEDGE:
		var prism := PrismMesh.new()
		prism.size = absolute
		prism.left_to_right = 0.5
		return prism
	var box := BoxMesh.new()
	box.size = absolute
	return box


func _make_shape(instance: RBXInstance, size: Vector3) -> Shape3D:
	var absolute := Vector3(absf(size.x), absf(size.y), absf(size.z))
	var shape := _shape_of(instance)
	if shape == SHAPE_BALL:
		var sphere := SphereShape3D.new()
		sphere.radius = maxf(absolute.x, absolute.z) * 0.5
		return sphere
	if shape == SHAPE_CYLINDER:
		var cylinder := CylinderShape3D.new()
		cylinder.radius = maxf(absolute.z, 0.01) * 0.5
		cylinder.height = maxf(absolute.x, 0.01)
		return cylinder
	var box := BoxShape3D.new()
	box.size = absolute
	return box


func _make_material(instance: RBXInstance) -> StandardMaterial3D:
	var surface := StandardMaterial3D.new()
	surface.albedo_color = _color_of(instance)
	surface.roughness = 0.72
	surface.metallic = 0.0

	var material_id := int(_property(instance, "Material", 256))
	if material_id == MATERIAL_METAL:
		surface.metallic = 0.85
		surface.roughness = 0.35
	elif material_id == MATERIAL_NEON:
		surface.emission_enabled = true
		surface.emission = surface.albedo_color
		surface.emission_energy_multiplier = 1.4
	elif material_id == MATERIAL_GLASS or material_id == MATERIAL_FORCE_FIELD:
		surface.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		surface.albedo_color.a = minf(surface.albedo_color.a, 0.35)
		surface.roughness = 0.08

	var transparency := float(_property(instance, "Transparency", 0.0))
	if transparency > 0.01:
		surface.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		surface.albedo_color.a = clampf(1.0 - transparency, 0.0, 1.0)
	return surface


func _build_light(instance: RBXInstance) -> Node3D:
	var light: Light3D
	if instance.rbx_class == "SpotLight":
		light = SpotLight3D.new()
	else:
		light = OmniLight3D.new()

	light.name = _node_name(instance)
	var color: Variant = _property(instance, "Color", Color.WHITE)
	if color is Color:
		light.light_color = color
	light.light_energy = maxf(0.1, float(_property(instance, "Brightness", 1.0)))
	var range_value := maxf(1.0, float(_property(instance, "Range", 8.0)))
	var omni := light as OmniLight3D
	if omni != null:
		omni.omni_range = range_value
	var spot := light as SpotLight3D
	if spot != null:
		spot.spot_range = range_value
	light.shadow_enabled = bool(_property(instance, "Shadows", false)) and _setting("shadows", true)

	var pivot := Node3D.new()
	pivot.name = "Light"
	pivot.add_child(light)
	return pivot


# ---------------------------------------------------------------------------
# Property helpers
# ---------------------------------------------------------------------------

func _property(instance: RBXInstance, property_name: String, fallback: Variant) -> Variant:
	var value: Variant = instance.get_property(property_name)
	return fallback if value == null else value


func _size_of(instance: RBXInstance) -> Vector3:
	var value: Variant = instance.get_property("Size")
	if value is Vector3:
		var size: Vector3 = value
		return Vector3(maxf(size.x, 0.05), maxf(size.y, 0.05), maxf(size.z, 0.05))
	return Vector3.ONE


func _shape_of(instance: RBXInstance) -> int:
	var value: Variant = _property(instance, "Shape", SHAPE_BLOCK)
	if value is float or value is int:
		return int(value)
	return SHAPE_BLOCK


func _transform_of(instance: RBXInstance) -> Transform3D:
	var value: Variant = instance.get_property("CFrame")
	if value is Transform3D:
		return value
	# A CFrame that failed to decode is still a position worth honouring.
	if value is Dictionary:
		var origin: Variant = (value as Dictionary).get("origin", null)
		if origin is Vector3:
			return Transform3D(Basis(), origin)
	return Transform3D()


func _color_of(instance: RBXInstance) -> Color:
	var value: Variant = instance.get_property("Color")
	if value is Color:
		return value
	var brick: Variant = instance.get_property("BrickColor")
	if brick is int:
		return RBXValues.brick_color_color(brick) if brick > 0 else Color(0.64, 0.64, 0.64)
	return Color(0.64, 0.64, 0.64)


func _wants_collision(instance: RBXInstance, transform: Transform3D) -> bool:
	if bool(_property(instance, "CanCollide", true)) == false:
		return false
	var mode := String(_setting("collision_mode", "all"))
	if mode == "none":
		return false
	if mode == "near_spawn":
		var radius := float(_setting("collision_radius", 1200.0))
		return transform.origin.length() <= radius
	return true


func _max_instances() -> int:
	return int(_setting("max_instances", 250000))


func _setting(name: String, fallback: Variant) -> Variant:
	if _settings != null and _settings.has_method("get_value"):
		var value: Variant = _settings.call("get_value", name, fallback)
		return fallback if value == null else value
	return fallback


func _warn(text: String) -> void:
	_warned[text] = true


func _node_name(instance: RBXInstance) -> String:
	var raw_name := instance.get_name()
	var cleaned := ""
	for index in raw_name.length():
		var character := raw_name[index]
		cleaned += "_" if character in ["/", ":", "@", ".", "%", "\"", "<", ">"] else character
	if cleaned.is_empty():
		cleaned = instance.rbx_class
	# Godot node names cannot start with a digit either.
	if cleaned[0].is_valid_int():
		cleaned = "_" + cleaned
	return cleaned
