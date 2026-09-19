class_name RBXBinaryReader
extends RefCounted
## Reader for Roblox's binary model format (`.rbxl` / `.rbxm`) — format version 0.
##
## Layout: a 32 byte header followed by chunks (`META`, `SSTR`, `INST`, `PROP`,
## `PRNT`, `SIGN`, `END`).  Chunks are either stored raw or compressed with LZ4
## (block format) or ZSTD (a full frame, detected by its magic number).
##
## The parser is written to survive real world files: anything that cannot be
## understood becomes a warning on the returned `RBXPlace` instead of an error,
## so a partially supported place still opens and can be explored.
##
## Reference: https://github.com/rojo-rbx/rbx-dom/blob/master/docs/binary.md

const MAGIC := "roblox!" ## preceded by a `<`
const END_MAGIC := "</roblox>"

## The six bytes that follow `<roblox!`.  A `static var` rather than a `const`
## because Godot 4.7 no longer folds packed array constructors into constants
## ("Assigned value for constant \"SIGNATURE\" isn't a constant expression"),
## which took the whole reader — and everything that loads a file — down.
static var SIGNATURE := PackedByteArray([0x89, 0xFF, 0x0D, 0x0A, 0x1A, 0x0A])

## Rotation matrices for the 24 "basic rotation" CFrame ids.  Columns are stored
## in the same order Roblox's `Matrix3::new(x, y, z)` uses.
const ROTATION_TABLE := {
	0x02: [1, 0, 0, 0, 1, 0, 0, 0, 1],
	0x03: [1, 0, 0, 0, 0, -1, 0, 1, 0],
	0x05: [1, 0, 0, 0, -1, 0, 0, 0, -1],
	0x06: [1, 0, 0, 0, 0, 1, 0, -1, 0],
	0x07: [0, 1, 0, 1, 0, 0, 0, 0, -1],
	0x09: [0, 0, 1, 1, 0, 0, 0, 1, 0],
	0x0A: [0, -1, 0, 1, 0, 0, 0, 0, 1],
	0x0C: [0, 0, -1, 1, 0, 0, 0, -1, 0],
	0x0D: [0, 1, 0, 0, 0, 1, 1, 0, 0],
	0x0E: [0, 0, -1, 0, 1, 0, 1, 0, 0],
	0x10: [0, -1, 0, 0, 0, -1, 1, 0, 0],
	0x11: [0, 0, 1, 0, -1, 0, 1, 0, 0],
	0x14: [-1, 0, 0, 0, 1, 0, 0, 0, -1],
	0x15: [-1, 0, 0, 0, 0, 1, 0, 1, 0],
	0x17: [-1, 0, 0, 0, -1, 0, 0, 0, 1],
	0x18: [-1, 0, 0, 0, 0, -1, 0, -1, 0],
	0x19: [0, 1, 0, -1, 0, 0, 0, 0, 1],
	0x1B: [0, 0, -1, -1, 0, 0, 0, 1, 0],
	0x1C: [0, -1, 0, -1, 0, 0, 0, 0, -1],
	0x1E: [0, 0, 1, -1, 0, 0, 0, -1, 0],
	0x1F: [0, 1, 0, 0, 0, -1, -1, 0, 0],
	0x20: [0, 0, 1, 0, 1, 0, -1, 0, 0],
	0x22: [0, -1, 0, 0, 0, 1, -1, 0, 0],
	0x23: [0, 0, -1, 0, -1, 0, -1, 0, 0],
}

## Attribute type ids used inside the `AttributesSerialize` blob.
const ATTRIBUTE_TYPES := {
	0x02: "BinaryString", 0x03: "Bool", 0x04: "Int32", 0x05: "Float32",
	0x06: "Float64", 0x09: "UDim", 0x0A: "UDim2", 0x0E: "BrickColor",
	0x0F: "Color3", 0x10: "Vector2", 0x11: "Vector3", 0x14: "CFrame",
	0x15: "Enum", 0x17: "NumberSequence", 0x19: "ColorSequence",
	0x1B: "NumberRange", 0x1C: "Rect", 0x21: "Font",
}

var _instances: Dictionary = {} ## referent -> RBXInstance
var _classes: Dictionary = {} ## class index -> { name, referents, is_service }
var _shared_strings: PackedStringArray = PackedStringArray()
var _pending_refs: Array = []
var _place: RBXPlace = null
var _type_histogram: Dictionary = {}
var _chunk_stats: Dictionary = {"raw": 0, "lz4": 0, "zstd": 0, "unknown": 0, "props": 0}


## Parses `bytes` (a whole `.rbxl`/`.rbxm` file) into `place`.
## Returns true when the file looked like a valid binary model.
func parse(bytes: PackedByteArray, place: RBXPlace) -> bool:
	_place = place
	var reader := RBXByteReader.new(bytes)
	if bytes.size() < 32:
		place.add_warning("File is too small to be a Roblox binary model.")
		return false
	var magic := reader.take(8).get_string_from_utf8()
	if magic != "<" + MAGIC:
		place.add_warning("Missing `<roblox!` magic number.")
		return false
	if reader.take(6) != SIGNATURE:
		place.add_warning("The file signature is not the Roblox one; trying anyway.")
	var version := reader.u16_le()
	if version != 0:
		place.add_warning("Unknown format version %d; reading it as version 0." % version)
	var class_count := reader.i32_le()
	var instance_count := reader.i32_le()
	reader.skip(8)
	place.stats["header"] = {
		"version": version,
		"class_count": class_count,
		"instance_count": instance_count,
	}

	# --- chunks -----------------------------------------------------------
	var finished := false
	var guard := 0
	while not reader.eof() and not finished:
		guard += 1
		if guard > 1000000:
			place.add_warning("Aborting after a million chunks; the file is corrupt.")
			break
		var name := reader.take(4)
		var chunk_name := name.get_string_from_utf8().strip_edges()
		var compressed_length := reader.u32_le()
		var uncompressed_length := reader.u32_le()
		reader.skip(4)
		var payload := PackedByteArray()
		if compressed_length == 0:
			payload = reader.take(uncompressed_length)
			_chunk_stats["raw"] += 1
		else:
			var body := reader.take(compressed_length)
			payload = _decompress(body, uncompressed_length)
		if chunk_name == "END":
			finished = true
			break
		if payload.is_empty() and chunk_name != "META":
			continue
		_read_chunk(chunk_name, payload)

	# --- assemble the tree ------------------------------------------------
	_apply_pending_refs()
	place.stats["chunks"] = _chunk_stats.duplicate()
	place.stats["property_types"] = _type_histogram.duplicate()
	place.stats["shared_strings"] = _shared_strings.size()
	if reader.truncated:
		place.add_warning("The file ended unexpectedly; some data may be missing.")
	return true


func _decompress(body: PackedByteArray, expected: int) -> PackedByteArray:
	if body.size() >= 4 and body[0] == 0x28 and body[1] == 0xB5 and body[2] == 0x2F and body[3] == 0xFD:
		_chunk_stats["zstd"] += 1
		return RBXZstd.decompress(body, expected)
	_chunk_stats["lz4"] += 1
	return RBXLZ4.decompress(body, expected)


func _read_chunk(chunk_name: String, payload: PackedByteArray) -> void:
	match chunk_name:
		"META":
			_read_meta(payload)
		"SSTR":
			_read_shared_strings(payload)
		"INST":
			_read_instance_chunk(payload)
		"PROP":
			_read_property_chunk(payload)
		"PRNT":
			_read_parent_chunk(payload)
		"SIGN":
			_place.stats["signed"] = true
		_:
			if _chunk_stats["unknown"] < 8:
				_place.add_warning("Skipped unknown chunk `%s`." % chunk_name)
			_chunk_stats["unknown"] += 1


func _read_meta(payload: PackedByteArray) -> void:
	var reader := RBXByteReader.new(payload)
	var count := reader.u32_le()
	for _index in count:
		if reader.eof():
			break
		var key := reader.string_utf8()
		var value := reader.string_utf8()
		_place.metadata[key] = value


func _read_shared_strings(payload: PackedByteArray) -> void:
	var reader := RBXByteReader.new(payload)
	var version := reader.u32_le()
	if version != 0:
		_place.add_warning("Unsupported shared string chunk version %d." % version)
	var count := reader.u32_le()
	_shared_strings = PackedStringArray()
	for _index in count:
		if reader.eof():
			break
		reader.skip(16) # md5 hash, not used when loading
		_shared_strings.append(reader.string_utf8())


func _read_instance_chunk(payload: PackedByteArray) -> void:
	var reader := RBXByteReader.new(payload)
	var class_index := reader.u32_le()
	var rbx_class := reader.string_utf8()
	var object_format := reader.u8()
	var count := reader.u32_le()
	var referents := reader.read_referent_array(count)
	if object_format == 1:
		reader.skip(count) # service markers
	var info := {"name": rbx_class, "referents": referents, "is_service": object_format == 1}
	_classes[class_index] = info
	for referent in referents:
		var instance := RBXInstance.create(rbx_class)
		instance.id = referent
		instance.properties["Name"] = rbx_class
		if not RbxData.has_class(rbx_class):
			instance.unknown_class = true
		_instances[referent] = instance


func _read_property_chunk(payload: PackedByteArray) -> void:
	var reader := RBXByteReader.new(payload)
	var class_index := reader.u32_le()
	var property_name := reader.string_utf8()
	var type_id := reader.u8()
	if not _classes.has(class_index):
		if _chunk_stats["props"] < 4:
			_place.add_warning("Property `%s` references unknown class id %d." % [property_name, class_index])
		return
	var info: Dictionary = _classes[class_index]
	var referents: PackedInt64Array = info["referents"]
	var rbx_class := String(info["name"])
	var values := _read_values(reader, type_id, referents.size(), rbx_class)
	_chunk_stats["props"] += 1
	var type_name := _type_name(type_id)
	_type_histogram[type_name] = int(_type_histogram.get(type_name, 0)) + 1
	var canonical := RbxData.resolve_property(rbx_class, property_name)
	for index in mini(referents.size(), values.size()):
		var instance: RBXInstance = _instances.get(referents[index])
		if instance == null:
			continue
		_assign_property(instance, property_name, canonical, type_id, values[index])
	if reader.truncated and not _place.warnings.has("A property chunk was truncated."):
		_place.add_warning("A property chunk was truncated.")


func _assign_property(instance: RBXInstance, raw_name: String, canonical: String, type_id: int, value: Variant) -> void:
	match raw_name:
		"AttributesSerialize":
			if value is PackedByteArray:
				_decode_attributes(instance, value)
			return
		"Tags":
			if value is String:
				instance.set_tags(_split_tags(value))
			elif value is Array or value is PackedStringArray:
				instance.set_tags(value)
			return
		"Name":
			instance.set_property("Name", String(value))
			return
	if type_id == 0x13 and value is int:
		# Referent: resolved once every instance is known.
		_pending_refs.append([instance, canonical, int(value)])
		instance.properties[canonical] = null
		return
	if canonical == "Source":
		instance.source = String(value)
		return
	instance.properties[canonical] = value


func _apply_pending_refs() -> void:
	for entry in _pending_refs:
		var instance: RBXInstance = entry[0]
		var property: String = entry[1]
		var referent: int = entry[2]
		if referent < 0:
			instance.properties[property] = null
		else:
			instance.properties[property] = _instances.get(referent)
	_pending_refs.clear()


func _read_parent_chunk(payload: PackedByteArray) -> void:
	var reader := RBXByteReader.new(payload)
	var version := reader.u8()
	if version != 0:
		_place.add_warning("Unsupported parent chunk version %d." % version)
	var count := reader.u32_le()
	var children := reader.read_referent_array(count)
	var parents := reader.read_referent_array(count)
	var linked := 0
	for index in mini(children.size(), parents.size()):
		var child: RBXInstance = _instances.get(children[index])
		if child == null:
			continue
		var parent_referent: int = parents[index]
		if parent_referent == -1:
			_place.roots.append(child)
			linked += 1
			continue
		var parent: RBXInstance = _instances.get(parent_referent)
		if parent == null:
			_place.roots.append(child)
			linked += 1
			continue
		parent.add_child(child)
		linked += 1
	# Instances that PRNT forgot about are still worth showing.
	for referent in _instances.keys():
		var instance: RBXInstance = _instances[referent]
		if instance.parent == null and not _place.roots.has(instance):
			_place.roots.append(instance)
	_place.stats["linked"] = linked


# ---------------------------------------------------------------------------
# Property values
# ---------------------------------------------------------------------------


func _read_values(reader: RBXByteReader, type_id: int, count: int, _rbx_class: String = "") -> Array:
	var out: Array = []
	if count <= 0:
		return out
	match type_id:
		0x01, 0x1D: # String, Bytecode
			for _index in count:
				out.append(reader.string_utf8())
		0x02: # Bool
			for _index in count:
				out.append(reader.u8() != 0)
		0x03: # Int32
			for value in reader.read_i32_array(count):
				out.append(value)
		0x04: # Float32
			for value in reader.read_roblox_f32_array(count):
				out.append(value)
		0x05: # Float64
			for value in reader.read_f64_array(count):
				out.append(value)
		0x06: # UDim
			var scales := reader.read_roblox_f32_array(count)
			var offsets := reader.read_i32_array(count)
			for index in count:
				out.append(Vector2(scales[index], float(offsets[index])))
		0x07: # UDim2
			var x_scale := reader.read_roblox_f32_array(count)
			var y_scale := reader.read_roblox_f32_array(count)
			var x_offset := reader.read_i32_array(count)
			var y_offset := reader.read_i32_array(count)
			for index in count:
				out.append(Vector4(x_scale[index], y_scale[index], float(x_offset[index]), float(y_offset[index])))
		0x08: # Ray
			for _index in count:
				out.append({
					"origin": Vector3(reader.f32_le(), reader.f32_le(), reader.f32_le()),
					"direction": Vector3(reader.f32_le(), reader.f32_le(), reader.f32_le()),
				})
		0x09, 0x0A: # Faces, Axes
			for _index in count:
				out.append(reader.u8())
		0x0B: # BrickColor
			for value in reader.read_u32_array(count):
				out.append(RBXValues.BrickColorUtil.color_for(int(value) & 0xFFFF))
		0x0C: # Color3
			var red := reader.read_roblox_f32_array(count)
			var green := reader.read_roblox_f32_array(count)
			var blue := reader.read_roblox_f32_array(count)
			for index in count:
				out.append(Color(red[index], green[index], blue[index]))
		0x0D: # Vector2
			var vx := reader.read_roblox_f32_array(count)
			var vy := reader.read_roblox_f32_array(count)
			for index in count:
				out.append(Vector2(vx[index], vy[index]))
		0x0E: # Vector3
			var x3 := reader.read_roblox_f32_array(count)
			var y3 := reader.read_roblox_f32_array(count)
			var z3 := reader.read_roblox_f32_array(count)
			for index in count:
				out.append(Vector3(x3[index], y3[index], z3[index]))
		0x10: # CFrame
			out = _read_cframes(reader, count)
		0x12: # Enum
			for value in reader.read_u32_array(count):
				out.append(int(value))
		0x13: # Referent
			for value in reader.read_referent_array(count):
				out.append(value)
		0x14: # Vector3int16
			var shorts := reader.read_i16_array(count * 3)
			for index in count:
				out.append(Vector3i(shorts[index * 3], shorts[index * 3 + 1], shorts[index * 3 + 2]))
		0x15: # NumberSequence
			for _index in count:
				var keypoints: Array = []
				var keypoint_count := reader.u32_le()
				for _point in keypoint_count:
					var t := reader.f32_le()
					var value := reader.f32_le()
					var envelope := reader.f32_le()
					keypoints.append({"t": t, "value": value, "envelope": envelope})
				out.append(keypoints)
		0x16: # ColorSequence
			for _index in count:
				var keypoints: Array = []
				var keypoint_count := reader.u32_le()
				for _point in keypoint_count:
					var t := reader.f32_le()
					var color := Color(reader.f32_le(), reader.f32_le(), reader.f32_le())
					reader.f32_le() # unused envelope
					keypoints.append({"t": t, "color": color})
				out.append(keypoints)
		0x17: # NumberRange
			for _index in count:
				out.append(Vector2(reader.f32_le(), reader.f32_le()))
		0x18: # Rect
			for _index in count:
				out.append(Rect2(reader.f32_le(), reader.f32_le(), reader.f32_le(), reader.f32_le()))
		0x19: # PhysicalProperties
			for _index in count:
				var bits := reader.u8()
				var entry := {"custom": (bits & 1) != 0}
				if bits & 1:
					entry["density"] = reader.f32_le()
					entry["friction"] = reader.f32_le()
					entry["elasticity"] = reader.f32_le()
					entry["friction_weight"] = reader.f32_le()
					entry["elasticity_weight"] = reader.f32_le()
					if bits & 2:
						entry["acoustic_absorption"] = reader.f32_le()
				out.append(entry)
		0x1A: # Color3uint8
			var reds := reader.take(count)
			var greens := reader.take(count)
			var blues := reader.take(count)
			for index in mini(count, mini(reds.size(), mini(greens.size(), blues.size()))):
				out.append(Color8(reds[index], greens[index], blues[index]))
		0x1B: # Int64
			for value in reader.read_i64_array(count):
				out.append(value)
		0x1C: # SharedString / NetAssetRef
			for value in reader.read_u32_array(count):
				var index_value := int(value)
				out.append(_shared_strings[index_value] if index_value >= 0 and index_value < _shared_strings.size() else "")
		0x1E: # OptionalCoordinateFrame
			var inner := reader.u8()
			if inner != 0x10:
				_place.add_warning("OptionalCoordinateFrame without an inner CFrame (got 0x%02x)." % inner)
			var frames := _read_cframes(reader, count)
			var present: Array = []
			for _index in count:
				present.append(reader.u8() != 0)
			for index in count:
				out.append(frames[index] if present[index] else null)
		0x1F: # UniqueId
			var indices := reader.read_u32_array(count)
			var times := reader.read_u32_array(count)
			var randoms := reader.read_u64_array(count)
			for index in count:
				out.append({"index": indices[index], "time": times[index], "random": randoms[index]})
		0x20: # Font
			for _index in count:
				var family := reader.string_utf8()
				var weight := reader.u16_le()
				var style := reader.u8()
				var cached := reader.string_utf8()
				out.append({"family": family, "weight": weight, "style": style, "cached": cached})
		0x21: # SecurityCapabilities
			for value in reader.read_u64_array(count):
				out.append(value)
		0x22: # Content
			for _index in count:
				var source_types := reader.u32_le()
				var kinds := PackedInt32Array()
				for _kind in source_types:
					kinds.append(reader.u32_le())
				var uri_count := reader.u32_le()
				var uri := ""
				for _uri_index in uri_count:
					var candidate := reader.string_utf8()
					if uri.is_empty():
						uri = candidate
				var object_count := reader.u32_le()
				var object_value: Variant = null
				if object_count > 0:
					var refs := reader.read_referent_array(object_count)
					if refs.size() > 0:
						object_value = _instances.get(refs[0])
				var external_count := reader.u32_le()
				if external_count > 0:
					reader.read_referent_array(external_count)
				out.append({
					"kinds": kinds,
					"uri": uri,
					"object": object_value,
					"none": source_types == 0,
				})
		_:
			_place.add_warning("Skipped property of unsupported type 0x%02x." % type_id)
			# Drain the rest of the chunk so other properties still parse?
			# The chunk is self contained, so we simply stop here.
			reader.seek(reader.limit)
	return out


func _read_cframes(reader: RBXByteReader, count: int) -> Array:
	var basis_list: Array = []
	for _index in count:
		var rotation_id := reader.u8()
		if rotation_id == 0:
			var rows: Array = []
			for _row in 3:
				rows.append([reader.f32_le(), reader.f32_le(), reader.f32_le()])
			basis_list.append(RBXValues.basis_from_rows(rows))
		else:
			basis_list.append(_basis_for_rotation(rotation_id))
	var xs := reader.read_roblox_f32_array(count)
	var ys := reader.read_roblox_f32_array(count)
	var zs := reader.read_roblox_f32_array(count)
	var out: Array = []
	for index in count:
		var position := Vector3(xs[index], ys[index], zs[index])
		out.append(Transform3D(basis_list[index], position))
	return out


func _basis_for_rotation(rotation_id: int) -> Basis:
	var table: Variant = ROTATION_TABLE.get(rotation_id)
	if table == null:
		return Basis.IDENTITY
	var values: Array = table
	return Basis(
		Vector3(values[0], values[1], values[2]),
		Vector3(values[3], values[4], values[5]),
		Vector3(values[6], values[7], values[8])
	)


func _type_name(type_id: int) -> String:
	match type_id:
		0x01: return "String"
		0x02: return "Bool"
		0x03: return "Int32"
		0x04: return "Float32"
		0x05: return "Float64"
		0x06: return "UDim"
		0x07: return "UDim2"
		0x08: return "Ray"
		0x09: return "Faces"
		0x0A: return "Axes"
		0x0B: return "BrickColor"
		0x0C: return "Color3"
		0x0D: return "Vector2"
		0x0E: return "Vector3"
		0x10: return "CFrame"
		0x12: return "Enum"
		0x13: return "Referent"
		0x14: return "Vector3int16"
		0x15: return "NumberSequence"
		0x16: return "ColorSequence"
		0x17: return "NumberRange"
		0x18: return "Rect"
		0x19: return "PhysicalProperties"
		0x1A: return "Color3uint8"
		0x1B: return "Int64"
		0x1C: return "SharedString"
		0x1D: return "Bytecode"
		0x1E: return "OptionalCoordinateFrame"
		0x1F: return "UniqueId"
		0x20: return "Font"
		0x21: return "SecurityCapabilities"
		0x22: return "Content"
	return "Unknown(0x%02x)" % type_id


# ---------------------------------------------------------------------------
# Attributes and tags
# ---------------------------------------------------------------------------


func _decode_attributes(instance: RBXInstance, blob: PackedByteArray) -> void:
	var reader := RBXByteReader.new(blob)
	var count := reader.u32_le()
	for _index in count:
		if reader.eof():
			break
		var key := reader.string_utf8()
		var type_id := reader.u8()
		var type_name: String = ATTRIBUTE_TYPES.get(type_id, "")
		var value: Variant = null
		match type_name:
			"Bool":
				value = reader.u8() != 0
			"Int32":
				value = reader.i32_le()
			"Float32":
				value = reader.f32_le()
			"Float64":
				value = reader.f64_le()
			"String", "BinaryString":
				value = reader.string_utf8()
			"UDim":
				value = Vector2(reader.f32_le(), reader.i32_le())
			"UDim2":
				value = Vector4(reader.f32_le(), reader.f32_le(), reader.i32_le(), reader.i32_le())
			"BrickColor":
				value = RBXValues.BrickColorUtil.color_for(reader.u32_le() & 0xFFFF)
			"Color3":
				value = Color(reader.f32_le(), reader.f32_le(), reader.f32_le())
			"Vector2":
				value = Vector2(reader.f32_le(), reader.f32_le())
			"Vector3":
				value = Vector3(reader.f32_le(), reader.f32_le(), reader.f32_le())
			"CFrame":
				var rows: Array = []
				var position := Vector3(reader.f32_le(), reader.f32_le(), reader.f32_le())
				# Attributes store the rotation matrix in column-major order.
				var matrix: Array = []
				for _index2 in 3:
					matrix.append([reader.f32_le(), reader.f32_le(), reader.f32_le()])
				rows = matrix
				value = Transform3D(RBXValues.basis_from_rows(rows), position)
			"Enum":
				value = reader.u32_le()
			"NumberRange":
				value = Vector2(reader.f32_le(), reader.f32_le())
			"Rect":
				value = Rect2(reader.f32_le(), reader.f32_le(), reader.f32_le(), reader.f32_le())
			"NumberSequence":
				var keypoint_count := reader.u32_le()
				var keypoints: Array = []
				for _point in keypoint_count:
					var envelope := reader.f32_le()
					var t := reader.f32_le()
					var key_value := reader.f32_le()
					keypoints.append({"t": t, "value": key_value, "envelope": envelope})
				value = keypoints
			"ColorSequence":
				var color_count := reader.u32_le()
				var color_points: Array = []
				for _point in color_count:
					reader.f32_le()
					var t := reader.f32_le()
					var color := Color(reader.f32_le(), reader.f32_le(), reader.f32_le())
					color_points.append({"t": t, "color": color})
				value = color_points
			"Font":
				value = {
					"family": reader.string_utf8(),
					"weight": reader.u16_le(),
					"style": reader.u8(),
					"cached": reader.string_utf8(),
				}
			_:
				_place.add_warning("Unsupported attribute type 0x%02x for `%s`." % [type_id, key])
				return
		instance.set_attribute(key, value)


static func _split_tags(value: String) -> PackedStringArray:
	var out := PackedStringArray()
	for tag in value.split("\u0000", false):
		if not tag.is_empty():
			out.append(tag)
	return out
