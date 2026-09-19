extends Node
## Headless checks for the place readers and the reflection database.
##
##     godot --headless --path . res://tests/core_smoke.tscn
##
## Every fixture in `res://fixtures` is loaded through `RBXFileLoader` and its
## shape is printed as a machine readable `FIXTURE …` line; `tools/check_parsers.py`
## compares those lines against `tools/rbxl_dump.py`, the Python reference
## reader. The XML and binary encodings of the same place must also agree, which
## is what catches a reader that silently drops a chunk.
##
## Exits with a non-zero status when anything fails, so CI can gate on it.

const FIXTURE_DIR := "res://fixtures"

## file name -> [instances, roots, format]
const EXPECTED := {
	"all_types.rbxl": [19, 5, "binary"],
	"all_types.rbxlx": [19, 5, "xml"],
	"all_types_zstd.rbxl": [19, 5, "binary"],
	"demo_obby.rbxl": [32, 1, "binary"],
	"demo_obby.rbxlx": [32, 1, "xml"],
	"demo_showcase.rbxl": [46, 5, "binary"],
	"demo_showcase.rbxlx": [46, 5, "xml"],
	"deep-folders-100.rbxm": [100, 1, "binary"],
	"folders-100.rbxm": [100, 1, "binary"],
	"parts-1000.rbxm": [1001, 1, "binary"],
}

## The same place in both containers must describe the same tree.
const PAIRS := [
	["all_types.rbxl", "all_types.rbxlx"],
	["demo_showcase.rbxl", "demo_showcase.rbxlx"],
	["demo_obby.rbxl", "demo_obby.rbxlx"],
]

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _loaded: Dictionary = {}


func _ready() -> void:
	print("--- core smoke test ---")
	print("Godot %s" % Engine.get_version_info().get("string", "unknown"))

	for file in _fixture_files():
		_check_fixture(file)
	_check_container_pairs()
	_check_values()
	_check_reflection()
	_check_instance_model()
	_finish()


func _fixture_files() -> PackedStringArray:
	var names := PackedStringArray()
	var dir := DirAccess.open(FIXTURE_DIR)
	if dir == null:
		_fail("cannot open %s" % FIXTURE_DIR)
		return names
	for file in dir.get_files():
		if RBXFileLoader.is_supported(file):
			names.append(file)
	names.sort()
	if names.is_empty():
		_fail("no fixtures are present in %s" % FIXTURE_DIR)
	return names


# ---------------------------------------------------------------------------
# The fixtures themselves
# ---------------------------------------------------------------------------

func _check_fixture(file: String) -> void:
	var path := FIXTURE_DIR.path_join(file)
	var place := RBXFileLoader.load_file(path)
	_loaded[file] = place

	var instances := place.total_instances()
	var roots := place.roots.size()
	var classes := place.class_histogram().size()
	var props := -1
	var chunks: Variant = place.stats.get("chunks", null)
	if chunks is Dictionary:
		props = int(chunks.get("props", -1))

	print("FIXTURE file=%s format=%s instances=%d roots=%d props=%d classes=%d ms=%d warnings=%d error=%s" % [
		file,
		place.format,
		instances,
		roots,
		props,
		classes,
		int(place.stats.get("parse_ms", -1)),
		place.warnings.size(),
		place.load_error if not place.load_error.is_empty() else "-",
	])

	if not place.load_error.is_empty():
		_fail("%s did not load: %s" % [file, place.load_error])
		return

	if EXPECTED.has(file):
		var expected: Array = EXPECTED[file]
		_check(instances == int(expected[0]), "%s has %d instances (expected %d)" % [file, instances, expected[0]])
		_check(roots == int(expected[1]), "%s has %d roots (expected %d)" % [file, roots, expected[1]])
		_check(place.format == String(expected[2]), "%s was read as %s (expected %s)" % [file, place.format, expected[2]])


func _check_container_pairs() -> void:
	for pair: Array in PAIRS:
		var binary_place: RBXPlace = _loaded.get(pair[0], null)
		var xml_place: RBXPlace = _loaded.get(pair[1], null)
		if binary_place == null or xml_place == null:
			continue
		_check(binary_place.total_instances() == xml_place.total_instances(),
			"%s and %s hold the same number of instances (%d vs %d)" % [
				pair[0], pair[1], binary_place.total_instances(), xml_place.total_instances()])
		_check(_histogram_signature(binary_place) == _histogram_signature(xml_place),
			"%s and %s agree on the class histogram" % [pair[0], pair[1]])
		_check(_tree_signature(binary_place) == _tree_signature(xml_place),
			"%s and %s agree on the tree shape" % [pair[0], pair[1]])
		_check(binary_place.renderable_count() == xml_place.renderable_count(),
			"%s and %s agree on the renderable count" % [pair[0], pair[1]])


func _histogram_signature(place: RBXPlace) -> String:
	var histogram := place.class_histogram()
	var keys := histogram.keys()
	keys.sort()
	var parts := PackedStringArray()
	for key: String in keys:
		parts.append("%s=%d" % [key, int(histogram[key])])
	return "|".join(parts)


func _tree_signature(place: RBXPlace) -> String:
	var parts := PackedStringArray()
	for root: RBXInstance in place.roots:
		parts.append(_node_signature(root))
	return "|".join(parts)


func _node_signature(instance: RBXInstance) -> String:
	var parts := PackedStringArray()
	parts.append("%s:%s" % [instance.rbx_class, instance.get_name()])
	for child: RBXInstance in instance.children:
		parts.append(_node_signature(child))
	return "[" + ",".join(parts) + "]"


# ---------------------------------------------------------------------------
# Values, reflection and the instance model
# ---------------------------------------------------------------------------

func _check_values() -> void:
	var place: RBXPlace = _loaded.get("all_types.rbxl", null)
	if place == null:
		return

	var names := PackedStringArray()
	for root: RBXInstance in place.roots:
		names.append(root.get_name())
	_check(", ".join(names) == "Bool, Vector, Emitter, Link, Sequences",
		"the roots are in file order (got '%s')" % ", ".join(names))

	var bool_value := _find(place, "Bool")
	var vector_value := _find(place, "Vector")
	_check(bool_value != null and bool_value.get_property("Value") == true, "BoolValue.Value round-trips as true")
	if vector_value != null:
		var value: Variant = vector_value.get_property("Value")
		_check(value is Vector3 and (value as Vector3).is_equal_approx(Vector3(1.5, -2.25, 3.0)),
			"Vector3Value.Value is Vector3(1.5, -2.25, 3) (got %s)" % str(value))
	else:
		_fail("Vector3Value 'Vector' was not parsed")

	var emitter := _find(place, "Emitter")
	if emitter != null:
		var color: Variant = emitter.get_property("Color")
		_check(color is Array and (color as Array).size() == 2,
			"the ColorSequence survives as two keypoints (got %s)" % str(color))

	var sequences := _find(place, "Sequences")
	if sequences != null:
		_check(sequences.children.size() >= 4,
			"the Sequences folder kept its children (%d)" % sequences.children.size())


func _check_reflection() -> void:
	_check(RbxData.has_class("Part"), "the reflection database knows Part")
	_check(RbxData.has_class("MeshPart"), "the reflection database knows MeshPart")
	_check(RbxData.is_a("Part", "BasePart"), "Part is a BasePart")
	_check(not RbxData.is_a("Part", "Model"), "Part is not a Model")
	_check(RbxData.resolve_property("Part", "size") == "Size", "the serialized alias 'size' resolves to Size")
	_check(RbxData.property_datatype("Part", "Shape").begins_with("Enum"),
		"Part.Shape is an enum (got '%s')" % RbxData.property_datatype("Part", "Shape"))

	var size: Variant = RbxData.default_for("Part", "Size")
	_check(size is Vector3 and (size as Vector3).is_equal_approx(Vector3(4.0, 1.2, 2.0)),
		"the default Part.Size is Vector3(4, 1.2, 2) (got %s)" % str(size))
	_check(RbxData.default_for("Part", "Anchored") == false, "the default Part.Anchored is false")
	_check(RbxData.enum_value("Material", "Plastic") == 256,
		"Material.Plastic is 256 (got %s)" % str(RbxData.enum_value("Material", "Plastic")))


func _check_instance_model() -> void:
	var folder := RBXInstance.new()
	folder.rbx_class = "Folder"
	folder.set_name("Container")

	var part := RBXInstance.new()
	part.rbx_class = "Part"
	part.set_name("Brick")
	part.set_property("Size", Vector3(2.0, 2.0, 2.0))

	folder.add_child(part)
	_check(part.parent == folder, "a child knows its parent")
	_check(folder.children.size() == 1, "the parent lists the child")
	_check(part.is_a("BasePart"), "a Part instance is a BasePart")
	_check(part.get_property("Size") == Vector3(2.0, 2.0, 2.0), "properties survive a set/get round trip")
	_check(part.get_property("Anchored") == false, "unset properties fall back to the class default")

	folder.remove_child(part)
	_check(part.parent == null and folder.children.is_empty(), "removing a child unhooks both sides")


func _find(place: RBXPlace, wanted: String) -> RBXInstance:
	for root: RBXInstance in place.roots:
		var found := _find_in(root, wanted)
		if found != null:
			return found
	return null


func _find_in(instance: RBXInstance, wanted: String) -> RBXInstance:
	if instance.get_name() == wanted:
		return instance
	for child: RBXInstance in instance.children:
		var found := _find_in(child, wanted)
		if found != null:
			return found
	return null


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("  ok   %s" % description)
	else:
		_fail(description)


func _fail(description: String) -> void:
	print("  FAIL %s" % description)
	_failures.append(description)


func _finish() -> void:
	if _failures.is_empty():
		print("CORE_SMOKE PASS checks=%d" % _checks)
		get_tree().quit(0)
		return
	print("CORE_SMOKE FAIL checks=%d failures=%d" % [_checks, _failures.size()])
	for failure in _failures:
		print("  - %s" % failure)
	get_tree().quit(1)
