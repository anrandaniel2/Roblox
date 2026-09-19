extends Node
## Roblox reflection data (`RbxData` autoload).
##
## Loads the generated tables in `data/` and answers the questions the importer
## and the script runtime have: "what is this class called?", "what property
## does `size` map to?", "what is the default value of `Anchored`?".
##
## The tables are produced by `tools/gen_data.py` from rbx-dom's reflection
## database (itself generated from Roblox's public API dump).  They are stored
## gzip compressed, which shrinks ~430 KiB of JSON down to ~65 KiB.
##
## Everything here is lazily loaded: opening the file browser of a phone should
## not pay for parsing the class database.

const REFLECTION_PATH := "res://data/reflection.json.gz"
const REFLECTION_FALLBACK := "res://data/reflection.json"
const ENUMS_PATH := "res://data/enums.json.gz"
const BRICKCOLORS_PATH := "res://data/brickcolors.json.gz"

var classes: Dictionary = {}
var enums: Dictionary = {}
var brick_colors: Dictionary = {}

var _loaded := false
var _load_error := ""
var _prop_cache: Dictionary = {}
var _default_cache: Dictionary = {}


func _ready() -> void:
	# Data is loaded on first use so startup stays instant on phones.
	pass


func loaded() -> bool:
	return _loaded


func load_error() -> String:
	return _load_error


## Loads every table.  Returns false when the tables are missing, in which case
## the importer still works but falls back to "keep property names as they are".
func ensure_loaded() -> bool:
	if _loaded:
		return true
	var reflection: Variant = _read_json(REFLECTION_PATH, REFLECTION_FALLBACK)
	if reflection is Dictionary:
		classes = reflection.get("classes", {})
	var enum_data: Variant = _read_json(ENUMS_PATH)
	if enum_data is Dictionary:
		enums = enum_data
	var brick_data: Variant = _read_json(BRICKCOLORS_PATH)
	if brick_data is Dictionary:
		brick_colors = brick_data
		RBXValues.BrickColorUtil.palette = brick_colors
	_loaded = true
	if classes.is_empty():
		_load_error = "reflection database missing"
		RbxLog.warn("Reflection database not found; property names will be used verbatim.", "data")
		return false
	RbxLog.info("Loaded %d classes, %d enums, %d BrickColors." % [classes.size(), enums.size(), brick_colors.size()], "data")
	return true


func class_count() -> int:
	ensure_loaded()
	return classes.size()


func has_class(rbx_class: String) -> bool:
	ensure_loaded()
	return classes.has(rbx_class)


func class_info(rbx_class: String) -> Dictionary:
	ensure_loaded()
	return classes.get(rbx_class, {})


func superclass(rbx_class: String) -> String:
	return String(class_info(rbx_class).get("super", ""))


func class_names() -> PackedStringArray:
	ensure_loaded()
	var names := PackedStringArray(classes.keys())
	names.sort()
	return names


## True when `rbx_class` is `base` or inherits from it.
func is_a(rbx_class: String, base: String) -> bool:
	if rbx_class == base:
		return true
	var current := rbx_class
	var guard := 0
	while guard < 64:
		guard += 1
		var info := class_info(current)
		if info.is_empty():
			return false
		current = String(info.get("super", ""))
		if current.is_empty():
			return false
		if current == base:
			return true
	return false


## Walks the inheritance chain and returns the first property entry with `key`.
func _find_entry(rbx_class: String, key: String) -> Array:
	var current := rbx_class
	var guard := 0
	while guard < 64:
		guard += 1
		var info := class_info(current)
		if info.is_empty():
			return []
		var props: Dictionary = info.get("props", {})
		if props.has(key):
			return props[key]
		current = String(info.get("super", ""))
		if current.is_empty():
			break
	return []


## Resolves any of a property's names (canonical or serialized) to the canonical
## name used by the rest of the engine.  Returns the input when unknown.
func resolve_property(rbx_class: String, name: String) -> String:
	var cache_key := rbx_class + "\u0000" + name
	if _prop_cache.has(cache_key):
		return _prop_cache[cache_key]
	var resolved := name
	var entry := _find_entry(rbx_class, name)
	if entry.size() >= 3:
		if entry.size() >= 4:
			# Alias entry: [~, datatype, serialized, canonical]
			resolved = String(entry[3])
		else:
			resolved = name
	else:
		# Maybe the caller passed the serialized name (`size`, `Color3uint8`).
		var found := _find_canonical_by_serialized(rbx_class, name)
		if not found.is_empty():
			resolved = found
	_prop_cache[cache_key] = resolved
	return resolved


func _find_canonical_by_serialized(rbx_class: String, serialized: String) -> String:
	var current := rbx_class
	var guard := 0
	while guard < 64:
		guard += 1
		var info := class_info(current)
		if info.is_empty():
			return ""
		var props: Dictionary = info.get("props", {})
		for key in props.keys():
			var entry: Array = props[key]
			if entry.size() >= 3 and String(entry[0]) == serialized:
				return String(key)
		current = String(info.get("super", ""))
		if current.is_empty():
			break
	return ""


## Returns `{ canonical, serialized, datatype, alias }` for a property, or an
## empty dictionary when the class/property pair is unknown.
func property_info(rbx_class: String, name: String) -> Dictionary:
	var canonical := resolve_property(rbx_class, name)
	var entry := _find_entry(rbx_class, canonical)
	if entry.is_empty():
		return {}
	if entry.size() >= 4:
		return {
			"canonical": canonical,
			"serialized": String(entry[2]),
			"datatype": String(entry[1]),
			"alias": true,
		}
	return {
		"canonical": canonical,
		"serialized": String(entry[0]),
		"datatype": String(entry[1]),
		"alias": false,
	}


## Data type name of a property, e.g. `Vector3` or `Enum.Material`.
func property_datatype(rbx_class: String, name: String) -> String:
	return String(property_info(rbx_class, name).get("datatype", ""))


func property_serialized_name(rbx_class: String, name: String) -> String:
	var info := property_info(rbx_class, name)
	return String(info.get("serialized", name))


## Decoded default value for a property.  Returns null when unknown.
func default_for(rbx_class: String, name: String) -> Variant:
	var canonical := resolve_property(rbx_class, name)
	var cache_key := rbx_class + "\u0000" + canonical
	if _default_cache.has(cache_key):
		return _default_cache[cache_key]
	var value: Variant = null
	var current := rbx_class
	var guard := 0
	while guard < 64:
		guard += 1
		var info := class_info(current)
		if info.is_empty():
			break
		var defaults: Dictionary = info.get("defaults", {})
		if defaults.has(canonical):
			value = RBXValues.decode_default(defaults[canonical])
			break
		current = String(info.get("super", ""))
		if current.is_empty():
			break
	_default_cache[cache_key] = value
	return value


func default_value_for(rbx_class: String, name: String, fallback: Variant) -> Variant:
	var value: Variant = default_for(rbx_class, name)
	return fallback if value == null else value


## All property names (canonical) known for a class, including inherited ones.
func all_property_names(rbx_class: String, include_internal: bool = false) -> PackedStringArray:
	ensure_loaded()
	var out := {}
	var current := rbx_class
	var guard := 0
	while guard < 64:
		guard += 1
		var info := class_info(current)
		if info.is_empty():
			break
		var props: Dictionary = info.get("props", {})
		for key in props.keys():
			var entry: Array = props[key]
			if entry.size() >= 4 and not include_internal:
				continue # alias entries are folded into their canonical property
			out[key] = true
		current = String(info.get("super", ""))
		if current.is_empty():
			break
	var names := PackedStringArray(out.keys())
	names.sort()
	return names


func enum_value(enum_name: String, item: String) -> int:
	ensure_loaded()
	var table: Dictionary = enums.get(enum_name, {})
	return int(table.get(item, 0))


func enum_item(enum_name: String, value: int) -> String:
	ensure_loaded()
	if enum_name.is_empty():
		return str(value)
	var table: Dictionary = enums.get(enum_name, {})
	for key in table.keys():
		if int(table[key]) == value:
			return String(key)
	return str(value)


func enum_table(enum_name: String) -> Dictionary:
	ensure_loaded()
	return enums.get(enum_name, {})


func has_enum(enum_name: String) -> bool:
	ensure_loaded()
	return enums.has(enum_name)


func enum_names() -> PackedStringArray:
	ensure_loaded()
	var names := PackedStringArray(enums.keys())
	names.sort()
	return names


func brick_color_color(number: int) -> Color:
	ensure_loaded()
	return RBXValues.BrickColorUtil.color_for(number)


func brick_color_name(number: int) -> String:
	ensure_loaded()
	return RBXValues.BrickColorUtil.name_for(number)


func _read_json(path: String, fallback_path: String = "") -> Variant:
	var text := _read_text(path)
	if text.is_empty() and not fallback_path.is_empty():
		text = _read_text(fallback_path)
	if text.is_empty():
		return null
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		RbxLog.error("Failed to parse %s (invalid JSON)." % path, "data")
	return parsed


## Reads one of the generated tables, inflating it when it is gzip'd.
##
## `FileAccess.open_compressed()` is not an option here: it reads the engine's own
## magic + block-table container, not a plain gzip stream like the one `gzip` or
## `tools/gen_data.py` writes.  The bytes are inflated directly instead, and the
## mode comes from `FileAccess` because Godot 4.7 dropped the `Compression` class.
func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		RbxLog.warn("Could not open %s for reading." % path, "data")
		return ""
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		RbxLog.warn("Could not open %s for reading." % path, "data")
		return ""
	if bytes.size() >= 2 and bytes[0] == 0x1F and bytes[1] == 0x8B:
		var plain := bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
		if plain.is_empty():
			RbxLog.warn("Could not decompress %s." % path, "data")
			return ""
		return plain.get_string_from_utf8()
	return bytes.get_string_from_utf8()
