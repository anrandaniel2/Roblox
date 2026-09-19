class_name RBXXmlReader
extends RefCounted
## Reader for Roblox's XML model format (`.rbxlx` / `.rbxmx`, format version 4).
##
## Uses Godot's built in streaming `XMLParser`, so even very large `.rbxlx`
## files (Studio writes XML with a lot of whitespace) parse without building a
## DOM in memory.
##
## Reference: https://github.com/rojo-rbx/rbx-dom/blob/master/docs/xml.md

var _place: RBXPlace = null
var _instances_by_referent: Dictionary = {}
var _shared_strings: Dictionary = {} ## md5 -> contents
var _pending_refs: Array = []


func parse(bytes: PackedByteArray, place: RBXPlace) -> bool:
	_place = place
	_instances_by_referent.clear()
	_shared_strings.clear()
	_pending_refs.clear()

	var parser := XMLParser.new()
	var error := parser.open_buffer(bytes)
	if error != OK:
		place.add_warning("Could not open the XML document (error %d)." % error)
		return false

	var stack: Array[RBXInstance] = []
	var in_properties := false
	var in_shared_strings := false
	var current: RBXInstance = null
	var depth := 0

	while parser.read() == OK:
		var node_type := parser.get_node_type()
		if node_type == XMLParser.NODE_ELEMENT:
			depth += 1
			var element := parser.get_node_name()
			if element == "roblox":
				place.stats["xml_version"] = parser.get_named_attribute_value_safe("version")
			elif element == "Item":
				current = _read_item(parser, current)
				if current != null:
					stack.append(current)
			elif element == "Properties":
				in_properties = true
			elif element == "SharedStrings":
				in_shared_strings = true
			elif element == "Meta":
				var key := parser.get_named_attribute_value_safe("name")
				place.metadata[key] = _read_text(parser)
			elif in_shared_strings and element == "SharedString":
				var md5 := parser.get_named_attribute_value_safe("md5")
				_shared_strings[md5] = _read_text(parser)
			elif in_properties and current != null:
				var property_name := parser.get_named_attribute_value_safe("name")
				var raw: Variant = _read_element(parser, element)
				_assign_property(current, element, property_name, raw)
		elif node_type == XMLParser.NODE_ELEMENT_END:
			depth -= 1
			var element_end := parser.get_node_name()
			if element_end == "Item":
				if not stack.is_empty():
					stack.pop_back()
				current = stack[stack.size() - 1] if not stack.is_empty() else null
			elif element_end == "Properties":
				in_properties = false
			elif element_end == "SharedStrings":
				in_shared_strings = false

	_resolve_refs()
	place.stats["shared_strings"] = _shared_strings.size()
	place.stats["xml"] = true
	return true


func _read_item(parser: XMLParser, parent: RBXInstance) -> RBXInstance:
	var rbx_class := parser.get_named_attribute_value_safe("class")
	var referent := parser.get_named_attribute_value_safe("referent")
	if rbx_class.is_empty():
		rbx_class = "Instance"
	var instance := RBXInstance.create(rbx_class)
	instance.properties["Name"] = rbx_class
	if not RbxData.has_class(rbx_class):
		instance.unknown_class = true
	if parent == null:
		_place.roots.append(instance)
	else:
		parent.add_child(instance)
	if not referent.is_empty():
		instance.id = _instances_by_referent.size()
		_instances_by_referent[referent] = instance
	return instance


## Reads all text and child elements of the current element.
## Returns a String when the element only holds text, a Dictionary when it has
## child elements.
func _read_element(parser: XMLParser, _element_name: String = "") -> Variant:
	var text := ""
	var children: Dictionary = {}
	while parser.read() == OK:
		var node_type := parser.get_node_type()
		if node_type == XMLParser.NODE_TEXT or node_type == XMLParser.NODE_CDATA:
			text += parser.get_node_data()
		elif node_type == XMLParser.NODE_ELEMENT:
			var child_name := parser.get_node_name()
			children[child_name] = _read_element(parser, child_name)
		elif node_type == XMLParser.NODE_ELEMENT_END:
			break
	if children.is_empty():
		return text
	return children


## Reads the text content of the current element (used for `<Meta>`, `<SharedString>`).
func _read_text(parser: XMLParser) -> String:
	var text := ""
	while parser.read() == OK:
		var node_type := parser.get_node_type()
		if node_type == XMLParser.NODE_TEXT or node_type == XMLParser.NODE_CDATA:
			text += parser.get_node_data()
		elif node_type == XMLParser.NODE_ELEMENT_END:
			break
	return text


func _assign_property(instance: RBXInstance, element: String, property_name: String, raw: Variant) -> void:
	if property_name.is_empty():
		return
	var canonical := RbxData.resolve_property(instance.rbx_class, property_name)
	if canonical == "AttributesSerialize" and raw is String:
		_decode_attributes(instance, Marshalls.base64_to_raw(raw))
		return
	var datatype := RbxData.property_datatype(instance.rbx_class, canonical)
	var value: Variant = _decode_value(element, datatype, raw)
	if value == null and element != "Content" and element != "OptionalCoordinateFrame":
		_place.add_warning("Could not decode `%s` (%s) on %s." % [property_name, element, instance.rbx_class])
		return
	if canonical == "Source":
		instance.source = String(value)
		return
	if value is Dictionary and value.has("__ref__"):
		_pending_refs.append([instance, canonical, value["__ref__"]])
		instance.properties[canonical] = null
		return
	instance.properties[canonical] = value


func _resolve_refs() -> void:
	for entry in _pending_refs:
		var instance: RBXInstance = entry[0]
		var canonical: String = entry[1]
		var referent := String(entry[2]).strip_edges()
		instance.properties[canonical] = _instances_by_referent.get(referent)
	_pending_refs.clear()


func _decode_value(element: String, datatype: String, raw: Variant) -> Variant:
	match element:
		"string", "ProtectedString", "BinaryString":
			if element == "BinaryString":
				return Marshalls.base64_to_raw(String(raw))
			return String(raw).strip_edges() if element != "ProtectedString" else String(raw)
		"bool":
			return String(raw).strip_edges().to_lower() == "true"
		"int", "int64", "token":
			if datatype == "BrickColor":
				return RBXValues.BrickColorUtil.color_for(_to_int(raw))
			return _to_int(raw)
		"float", "double":
			return _to_float(raw)
		"Color3":
			var children := _as_children(raw)
			return Color(_to_float(children.get("R", "0")), _to_float(children.get("G", "0")), _to_float(children.get("B", "0")))
		"Color3uint8":
			var packed := _to_int(raw)
			return Color8((packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF)
		"Vector2":
			var v2 := _as_children(raw)
			return Vector2(_to_float(v2.get("X", "0")), _to_float(v2.get("Y", "0")))
		"Vector3":
			var v3 := _as_children(raw)
			return Vector3(_to_float(v3.get("X", "0")), _to_float(v3.get("Y", "0")), _to_float(v3.get("Z", "0")))
		"Vector3int16":
			var v3i := _as_children(raw)
			return Vector3i(_to_int(v3i.get("X", "0")), _to_int(v3i.get("Y", "0")), _to_int(v3i.get("Z", "0")))
		"CoordinateFrame":
			return _decode_cframe(_as_children(raw))
		"OptionalCoordinateFrame":
			var optional_children := _as_children(raw)
			if optional_children.has("CFrame"):
				return _decode_cframe(_as_children(optional_children["CFrame"]))
			return null
		"UDim":
			var udim := _as_children(raw)
			return Vector2(_to_float(udim.get("S", "0")), float(_to_int(udim.get("O", "0"))))
		"UDim2":
			var udim2 := _as_children(raw)
			return Vector4(
				_to_float(udim2.get("XS", "0")), _to_float(udim2.get("YS", "0")),
				float(_to_int(udim2.get("XO", "0"))), float(_to_int(udim2.get("YO", "0")))
			)
		"NumberRange":
			var parts := _split_numbers(String(raw))
			return Vector2(parts[0] if parts.size() > 0 else 0.0, parts[1] if parts.size() > 1 else 0.0)
		"NumberSequence":
			return _decode_number_sequence(String(raw))
		"ColorSequence":
			return _decode_color_sequence(String(raw))
		"Rect2D", "Rect":
			var rect := _as_children(raw)
			var minimum := _as_children(rect.get("min", {}))
			var maximum := _as_children(rect.get("max", {}))
			return Rect2(
				_to_float(minimum.get("X", "0")), _to_float(minimum.get("Y", "0")),
				_to_float(maximum.get("X", "0")), _to_float(maximum.get("Y", "0"))
			)
		"PhysicalProperties":
			var physics := _as_children(raw)
			var custom := String(physics.get("CustomPhysics", "false")).strip_edges().to_lower() == "true"
			if not custom:
				return {"custom": false}
			return {
				"custom": true,
				"density": _to_float(physics.get("Density", "0.7")),
				"friction": _to_float(physics.get("Friction", "0.3")),
				"elasticity": _to_float(physics.get("Elasticity", "0.5")),
				"friction_weight": _to_float(physics.get("FrictionWeight", "1")),
				"elasticity_weight": _to_float(physics.get("ElasticityWeight", "1")),
				"acoustic_absorption": _to_float(physics.get("AcousticAbsorption", "1")),
			}
		"Ray":
			var ray := _as_children(raw)
			return {
				"origin": _decode_value("Vector3", "Vector3", ray.get("origin", {})),
				"direction": _decode_value("Vector3", "Vector3", ray.get("direction", {})),
			}
		"Axes":
			return _to_int(_as_children(raw).get("axes", raw))
		"Faces":
			if raw is Dictionary:
				return _to_int(_as_children(raw).get("faces", "0"))
			return _to_int(raw)
		"Ref":
			var reference := String(raw).strip_edges()
			if reference.is_empty() or reference == "null":
				return null
			return {"__ref__": reference}
		"SharedString", "NetAssetRef":
			var key := String(raw).strip_edges()
			return String(_shared_strings.get(key, ""))
		"Content":
			var content := _as_children(raw)
			if content.has("uri"):
				return String(content["uri"]).strip_edges()
			if content.has("null"):
				return ""
			return ""
		"ContentId":
			var content_id := _as_children(raw)
			if content_id.has("url"):
				return String(content_id["url"]).strip_edges()
			return ""
		"Font":
			var font := _as_children(raw)
			return {
				"family": String(font.get("Family", "")).strip_edges(),
				"weight": font.get("Weight", "Regular"),
				"style": font.get("Style", "Normal"),
				"cached": "",
			}
		"UniqueId":
			return {"raw": Marshalls.base64_to_raw(String(raw))}
	return null


func _decode_cframe(children: Dictionary) -> Transform3D:
	var rows: Array = [
		[_to_float(children.get("R00", "0")), _to_float(children.get("R01", "0")), _to_float(children.get("R02", "0"))],
		[_to_float(children.get("R10", "0")), _to_float(children.get("R11", "0")), _to_float(children.get("R12", "0"))],
		[_to_float(children.get("R20", "0")), _to_float(children.get("R21", "0")), _to_float(children.get("R22", "0"))],
	]
	var position := Vector3(_to_float(children.get("X", "0")), _to_float(children.get("Y", "0")), _to_float(children.get("Z", "0")))
	return Transform3D(RBXValues.basis_from_rows(rows), position)


func _decode_number_sequence(text: String) -> Array:
	var numbers := _split_numbers(text)
	var keypoints: Array = []
	var index := 0
	while index + 2 < numbers.size() + 1 and index + 3 <= numbers.size():
		keypoints.append({"t": numbers[index], "value": numbers[index + 1], "envelope": numbers[index + 2]})
		index += 3
	return keypoints


func _decode_color_sequence(text: String) -> Array:
	var numbers := _split_numbers(text)
	var keypoints: Array = []
	var index := 0
	while index + 5 <= numbers.size():
		keypoints.append({"t": numbers[index], "color": Color(numbers[index + 1], numbers[index + 2], numbers[index + 3])})
		index += 5
	return keypoints


func _split_numbers(text: String) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for token in text.strip_edges().split(" ", false):
		out.append(_to_float(token))
	return out


func _as_children(raw: Variant) -> Dictionary:
	if raw is Dictionary:
		return raw
	return {}


func _to_float(value: Variant) -> float:
	if value is float or value is int:
		return float(value)
	var text := String(value).strip_edges()
	if text.is_empty():
		return 0.0
	var upper := text.to_upper()
	if upper == "INF" or upper == "+INF" or upper == "INFINITY":
		return INF
	if upper == "-INF" or upper == "-INFINITY":
		return -INF
	if upper == "NAN" or upper == "-NAN":
		return NAN
	return text.to_float()


func _to_int(value: Variant) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	var text := String(value).strip_edges()
	if text.is_empty():
		return 0
	if text.begins_with("0x") or text.begins_with("0X"):
		return text.hex_to_int()
	if text.is_valid_float():
		return int(text.to_float())
	return text.to_int()


func _decode_attributes(instance: RBXInstance, blob: PackedByteArray) -> void:
	if blob.is_empty():
		return
	var reader := RBXByteReader.new(blob)
	var count := reader.u32_le()
	for _index in count:
		if reader.eof():
			break
		var key := reader.string_utf8()
		var type_id := reader.u8()
		var type_name: String = RBXBinaryReader.ATTRIBUTE_TYPES.get(type_id, "")
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
			"Enum":
				value = reader.u32_le()
			"NumberRange":
				value = Vector2(reader.f32_le(), reader.f32_le())
			"Rect":
				value = Rect2(reader.f32_le(), reader.f32_le(), reader.f32_le(), reader.f32_le())
			_:
				continue
		instance.set_attribute(key, value)
