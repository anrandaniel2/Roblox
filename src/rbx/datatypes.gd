class_name RBXValues
extends RefCounted
## Conversions between Roblox data types and the closest native Godot type.
##
## The engine stores Roblox property values in plain Godot types so that the
## rest of the runtime (physics, UI, rendering) never has to think about the
## Roblox side of things:
##
## | Roblox | Godot representation |
## | --- | --- |
## | `CFrame` | `Transform3D` (same handedness, `-Z` is the look vector) |
## | `Vector3`, `Vector2` | `Vector3`, `Vector2` |
## | `Vector3int16`, `Vector2int16` | `Vector3i`, `Vector2i` |
## | `Color3`, `Color3uint8`, `BrickColor` | `Color` |
## | `UDim` | `Vector2(scale, offset)` |
## | `UDim2` | `Vector4(x_scale, y_scale, x_offset, y_offset)` |
## | `NumberRange` | `Vector2(min, max)` |
## | `Rect` | `Rect2` |
## | `NumberSequence` | `Array[Dictionary]` of `{t, value, envelope}` |
## | `ColorSequence` | `Array[Dictionary]` of `{t, color}` |
## | `Enum` | `int` (resolve names through `RBXData.enum_item`) |
## | `Referent` | `int` instance id (`RBXInstance.id`) |
## | `Faces`, `Axes` | `int` bitmask |
## | `Font` | `Dictionary` |
## | `PhysicalProperties` | `Dictionary` |
## | `Ray` | `Dictionary {origin, direction}` |
##
## Roblox and Godot share the same world convention (right handed, +Y up, -Z
## forward, 1 unit == 1 stud) which is why `CFrame` maps onto `Transform3D`
## without any axis juggling.

const FACES := ["Front", "Bottom", "Left", "Back", "Top", "Right"]
const AXES := ["X", "Y", "Z"]


static func decode_default(value: Variant) -> Variant:
	## Decodes a type tagged value such as `{"Vector3": [1, 2, 3]}` coming from
	## the generated reflection database into a native Godot value.
	if value == null:
		return null
	if not (value is Dictionary):
		return value
	var tag: String = String(value.keys()[0])
	var payload: Variant = value[tag]
	return decode_tagged(tag, payload)


static func decode_tagged(tag: String, payload: Variant) -> Variant:
	match tag:
		"Vector3":
			return _vec3(payload)
		"Vector2":
			return _vec2(payload)
		"Vector3int16":
			return Vector3i(int(payload[0]), int(payload[1]), int(payload[2]))
		"Vector2int16":
			return Vector2i(int(payload[0]), int(payload[1]))
		"Color3":
			return _color3(payload)
		"Color3uint8":
			return Color8(int(payload[0]), int(payload[1]), int(payload[2]))
		"BrickColor":
			return BrickColorUtil.color_for(int(payload))
		"CFrame", "OptionalCFrame":
			if payload == null:
				return null
			return decode_cframe(payload)
		"UDim":
			return Vector2(float(payload[0]), float(payload[1]))
		"UDim2":
			return decode_udim2(payload)
		"NumberRange":
			return Vector2(float(payload[0]), float(payload[1]))
		"Rect":
			return Rect2(_vec2(payload[0]), _vec2(payload[1]))
		"Ray":
			return {"origin": _vec3(payload[0]), "direction": _vec3(payload[1])}
		"NumberSequence":
			return decode_number_sequence(payload)
		"ColorSequence":
			return decode_color_sequence(payload)
		"Font":
			return decode_font(payload)
		"PhysicalProperties":
			return decode_physical_properties(payload)
		"Enum", "Int32", "Int64", "SecurityCapabilities":
			return int(payload)
		"Float32", "Float64":
			return float(payload)
		"Bool":
			return bool(payload)
		"String", "Content", "ContentId", "SharedString", "NetAssetRef", "BinaryString":
			return payload if payload is String else str(payload)
		"Axes", "Faces":
			return int(payload) if payload != null else 0
		"Attributes":
			return payload if payload is Dictionary else {}
		"Tags":
			return payload if payload is Array else []
		_:
			return payload


static func decode_cframe(payload: Variant) -> Transform3D:
	# [[x, y, z], [[r00, r01, r02], [r10, r11, r12], [r20, r21, r22]]]
	var rows: Array = payload[1]
	var basis := Basis(
		Vector3(float(rows[0][0]), float(rows[1][0]), float(rows[2][0])),
		Vector3(float(rows[0][1]), float(rows[1][1]), float(rows[2][1])),
		Vector3(float(rows[0][2]), float(rows[1][2]), float(rows[2][2]))
	)
	return Transform3D(basis, _vec3(payload[0]))


static func encode_cframe(cf: Transform3D) -> Array:
	var b := cf.basis
	var rows := [
		[b.x.x, b.y.x, b.z.x],
		[b.x.y, b.y.y, b.z.y],
		[b.x.z, b.y.z, b.z.z],
	]
	return [[cf.origin.x, cf.origin.y, cf.origin.z], rows]


static func decode_udim2(payload: Variant) -> Vector4:
	# [[x_scale, x_offset], [y_scale, y_offset]]
	var x: Array = payload[0]
	var y: Array = payload[1]
	return Vector4(float(x[0]), float(y[0]), float(x[1]), float(y[1]))


static func encode_udim2(value: Vector4) -> Array:
	return [[value.x, int(value.z)], [value.y, int(value.w)]]


static func decode_number_sequence(payload: Variant) -> Array:
	var keypoints: Array = []
	for point in payload:
		keypoints.append({"t": float(point[0]), "value": float(point[1]), "envelope": float(point[2]) if point.size() > 2 else 0.0})
	return keypoints


static func decode_color_sequence(payload: Variant) -> Array:
	var keypoints: Array = []
	for point in payload:
		keypoints.append({"t": float(point[0]), "color": _color3(point[1])})
	return keypoints


static func decode_font(payload: Variant) -> Dictionary:
	return {
		"family": String(payload[0]) if payload.size() > 0 else "",
		"weight": String(payload[1]) if payload.size() > 1 else "Regular",
		"style": String(payload[2]) if payload.size() > 2 else "Normal",
		"cached": String(payload[3]) if payload.size() > 3 else "",
	}


static func decode_physical_properties(payload: Variant) -> Dictionary:
	if payload is String or payload == null:
		return {"custom": false, "density": 0.7, "friction": 0.3, "elasticity": 0.5}
	var values: Array = payload
	return {
		"custom": true,
		"density": float(values[0]) if values.size() > 0 else 0.7,
		"friction": float(values[1]) if values.size() > 1 else 0.3,
		"elasticity": float(values[2]) if values.size() > 2 else 0.5,
		"friction_weight": float(values[3]) if values.size() > 3 else 1.0,
		"elasticity_weight": float(values[4]) if values.size() > 4 else 1.0,
	}


## Roblox `R00..R22` rows are written row major, matching Basis's column layout.
static func basis_from_rows(rows: Array) -> Basis:
	return Basis(
		Vector3(float(rows[0][0]), float(rows[1][0]), float(rows[2][0])),
		Vector3(float(rows[0][1]), float(rows[1][1]), float(rows[2][1])),
		Vector3(float(rows[0][2]), float(rows[1][2]), float(rows[2][2]))
	)


static func rows_from_basis(basis: Basis) -> Array:
	return [
		[basis.x.x, basis.y.x, basis.z.x],
		[basis.x.y, basis.y.y, basis.z.y],
		[basis.x.z, basis.y.z, basis.z.z],
	]


static func udim2_size(value: Vector4, parent: Vector2) -> Vector2:
	return Vector2(value.x * parent.x + value.z, value.y * parent.y + value.w)


static func udim2_position(value: Vector4, parent: Vector2) -> Vector2:
	return Vector2(value.x * parent.x + value.z, value.y * parent.y + value.w)


static func udim2_from_pixels(size: Vector2) -> Vector4:
	return Vector4(0.0, 0.0, size.x, size.y)


static func faces_from_mask(mask: int) -> PackedStringArray:
	var out := PackedStringArray()
	for index in FACES.size():
		if mask & (1 << index):
			out.append(FACES[index])
	return out


static func axes_from_mask(mask: int) -> PackedStringArray:
	var out := PackedStringArray()
	for index in AXES.size():
		if mask & (1 << index):
			out.append(AXES[index])
	return out


static func value_to_string(value: Variant) -> String:
	if value is Transform3D:
		return "CFrame(%s)" % [value.origin]
	if value is float:
		return "%.3f" % value
	if value is Color:
		return "Color3(%s)" % [value.to_html(false)]
	if value is Vector4:
		return "UDim2(%s)" % [value]
	if value is Array:
		return "Array(%d)" % [value.size()]
	if value is Dictionary:
		return "Dict(%d)" % [value.size()]
	return str(value)


static func _vec3(payload: Variant) -> Vector3:
	return Vector3(float(payload[0]), float(payload[1]), float(payload[2]))


static func _vec2(payload: Variant) -> Vector2:
	return Vector2(float(payload[0]), float(payload[1]))


static func _color3(payload: Variant) -> Color:
	return Color(float(payload[0]), float(payload[1]), float(payload[2]))


## Legacy Roblox color palette.  The data table is generated from rbx-dom by
## `tools/gen_data.py` and loaded by `RBXData`.
class BrickColorUtil:
	static var palette: Dictionary = {}

	static func color_for(number: int) -> Color:
		var entry: Variant = palette.get(str(number))
		if entry is Array and entry.size() >= 4:
			return Color8(int(entry[1]), int(entry[2]), int(entry[3]))
		# Roblox's fallback for unknown BrickColors is Medium stone grey.
		return Color8(163, 162, 165)

	static func name_for(number: int) -> String:
		var entry: Variant = palette.get(str(number))
		if entry is Array and entry.size() >= 1:
			return String(entry[0])
		return "Unknown"

	static func closest_number(color: Color) -> int:
		var best := 194
		var best_distance := INF
		var target := Vector3(color.r, color.g, color.b)
		for key in palette.keys():
			var entry: Array = palette[key]
			var candidate := Vector3(int(entry[1]) / 255.0, int(entry[2]) / 255.0, int(entry[3]) / 255.0)
			var distance := target.distance_squared_to(candidate)
			if distance < best_distance:
				best_distance = distance
				best = int(key)
		return best
