class_name RBXInstance
extends RefCounted
## A node in the Roblox data model.
##
## This is the emulator's equivalent of `Instance`: it stores the class name,
## the property bag (in *canonical* property names, see `RBXData.resolve_property`),
## attributes, children and the referent id it had inside the file it came from.
##
## Values are plain Godot types, see `RBXValues` for the mapping.  Property
## values are only stored when they were actually set: reading a property that
## is not in the bag falls back to the class default from the reflection
## database, exactly like Roblox does.

signal child_added(child: RBXInstance)
signal child_removed(child: RBXInstance)
signal descendant_added(descendant: RBXInstance)
signal property_changed(name: String, value: Variant)
signal attribute_changed(name: String, value: Variant)
signal parent_changed(new_parent: RBXInstance)
signal destroyed()

var id: int = -1
var rbx_class: String = "Instance"
var properties: Dictionary = {}
var attributes: Dictionary = {}
var children: Array[RBXInstance] = []
var parent: RBXInstance = null
## `ProtectedString` payload of a script (`Source`), kept out of the property bag
## because scripts can be huge.
var source: String = ""
## Tags parsed from the `Tags` property (Roblox collection service).
var tags: PackedStringArray = PackedStringArray()
## Non fatal problems noticed while reading/writing this instance.
var warnings: PackedStringArray = PackedStringArray()
## Set when a class could not be found in the reflection database.
var unknown_class: bool = false


static func create(rbx_class_name: String) -> RBXInstance:
	var instance := RBXInstance.new()
	instance.rbx_class = rbx_class_name
	instance.properties["Name"] = rbx_class_name
	if not RbxData.has_class(rbx_class_name):
		instance.unknown_class = true
	return instance


func get_name() -> String:
	var value: Variant = properties.get("Name")
	return String(value) if value != null else rbx_class


func set_name(value: String) -> void:
	set_property("Name", value)


## Canonical property names are stored; serialized names are accepted too.
func get_property(name: String) -> Variant:
	if name == "Source" and rbx_class.ends_with("Script"):
		return source
	if name == "Name":
		return get_name()
	var canonical := RbxData.resolve_property(rbx_class, name)
	if properties.has(canonical):
		return properties[canonical]
	if properties.has(name):
		return properties[name]
	if canonical == "Source" and rbx_class.ends_with("Script"):
		return source
	return RbxData.default_for(rbx_class, canonical)


func set_property(name: String, value: Variant) -> void:
	var canonical := RbxData.resolve_property(rbx_class, name)
	if canonical == "Name":
		properties["Name"] = String(value)
		property_changed.emit("Name", properties["Name"])
		return
	if canonical == "Source" or (name == "Source" and rbx_class.ends_with("Script")):
		source = String(value)
		property_changed.emit("Source", source)
		return
	if canonical == "Tags":
		set_tags(value)
		return
	if canonical == "Attributes" and value is Dictionary:
		for key in value.keys():
			set_attribute(String(key), value[key])
		return
	var previous: Variant = properties.get(canonical)
	properties[canonical] = value
	if previous != value:
		property_changed.emit(canonical, value)


func has_property(name: String) -> bool:
	var canonical := RbxData.resolve_property(rbx_class, name)
	return properties.has(canonical)


func clear_property(name: String) -> void:
	var canonical := RbxData.resolve_property(rbx_class, name)
	properties.erase(canonical)


func property_names() -> PackedStringArray:
	return PackedStringArray(properties.keys())


func get_attribute(name: String) -> Variant:
	return attributes.get(name)


func set_attribute(name: String, value: Variant) -> void:
	attributes[name] = value
	attribute_changed.emit(name, value)


func get_attributes() -> Dictionary:
	return attributes


func set_tags(value: Variant) -> void:
	if value is PackedStringArray:
		tags = value
	elif value is Array:
		tags = PackedStringArray(value)
	elif value is String:
		tags = PackedStringArray([value])
	property_changed.emit("Tags", tags)


func add_child(child: RBXInstance, index: int = -1) -> void:
	if child == null or child == self:
		return
	if child.parent != null:
		child.parent.remove_child(child)
	if index < 0 or index >= children.size():
		children.append(child)
	else:
		children.insert(index, child)
	child.parent = self
	child.parent_changed.emit(self)
	child_added.emit(child)
	# Bubble the notification up so the importer can build nodes lazily.
	var ancestor := parent
	while ancestor != null:
		ancestor.descendant_added.emit(child)
		ancestor = ancestor.parent


func remove_child(child: RBXInstance) -> void:
	var index := children.find(child)
	if index == -1:
		return
	children.remove_at(index)
	child.parent = null
	child.parent_changed.emit(null)
	child_removed.emit(child)


func clear_children() -> void:
	for child: RBXInstance in children.duplicate():
		remove_child(child)


func destroy() -> void:
	clear_children()
	if parent != null:
		parent.remove_child(self)
	destroyed.emit()


func get_children() -> Array[RBXInstance]:
	return children


func child_count() -> int:
	return children.size()


func find_first_child(name: String) -> RBXInstance:
	for child in children:
		if child.get_name() == name:
			return child
	return null


func find_first_child_of_class(rbx_class_name: String, recursive: bool = false) -> RBXInstance:
	for child in children:
		if child.rbx_class == rbx_class_name:
			return child
		if recursive:
			var found := child.find_first_child_of_class(rbx_class_name, true)
			if found != null:
				return found
	return null


func find_first_child_which(pattern: String, recursive: bool = false) -> RBXInstance:
	for child in children:
		if _matches_pattern(child.get_name(), pattern):
			return child
		if recursive:
			var found := child.find_first_child_which(pattern, true)
			if found != null:
				return found
	return null


static func _matches_pattern(name: String, pattern: String) -> bool:
	if pattern == name:
		return true
	# Roblox supports `*` wildcards in FindFirstChild patterns.
	if pattern.contains("*"):
		var segments := pattern.split("*")
		var index := 0
		for i in segments.size():
			var segment: String = segments[i]
			if segment.is_empty():
				continue
			var found_at := name.find(segment, index)
			if found_at == -1:
				return false
			if i == 0 and not pattern.begins_with("*") and found_at != 0:
				return false
			index = found_at + segment.length()
		if not pattern.ends_with("*") and not name.ends_with(segments[segments.size() - 1]):
			return false
		return true
	return false


func is_a(rbx_class_name: String) -> bool:
	if rbx_class == rbx_class_name:
		return true
	return RbxData.is_a(rbx_class, rbx_class_name)


func get_descendants(limit: int = -1) -> Array[RBXInstance]:
	var out: Array[RBXInstance] = []
	var stack: Array[RBXInstance] = []
	for child in children:
		stack.append(child)
	while not stack.is_empty():
		var current: RBXInstance = stack.pop_back()
		out.append(current)
		if limit > 0 and out.size() >= limit:
			break
		for child in current.children:
			stack.append(child)
	return out


func descendants_count() -> int:
	var total := 0
	var stack: Array[RBXInstance] = children.duplicate()
	while not stack.is_empty():
		var current: RBXInstance = stack.pop_back()
		total += 1
		for child in current.children:
			stack.append(child)
	return total


func get_ancestors() -> Array[RBXInstance]:
	var out: Array[RBXInstance] = []
	var current := parent
	while current != null:
		out.append(current)
		current = current.parent
	return out


func is_ancestor_of(other: RBXInstance) -> bool:
	var current := other.parent
	while current != null:
		if current == self:
			return true
		current = current.parent
	return false


func get_full_name() -> String:
	if parent == null:
		return get_name()
	return parent.get_full_name() + "." + get_name()


## `Workspace.Model.Part`, the Roblox style path, without the `game.` prefix.
func get_path_string() -> String:
	var parts := PackedStringArray([get_name()])
	var current := parent
	while current != null:
		parts.insert(0, current.get_name())
		current = current.parent
	return ".".join(parts)


func find_by_id(referent: int) -> RBXInstance:
	if id == referent:
		return self
	for child in children:
		var found := child.find_by_id(referent)
		if found != null:
			return found
	return null


func root() -> RBXInstance:
	var current := self
	while current.parent != null:
		current = current.parent
	return current


## Deep copy.  `id_map` keeps referent ids consistent for `Referent` properties.
func clone(deep: bool = true, id_map: Dictionary = {}) -> RBXInstance:
	var copy := RBXInstance.new()
	copy.rbx_class = rbx_class
	copy.properties = properties.duplicate(true)
	copy.attributes = attributes.duplicate(true)
	copy.tags = tags.duplicate()
	copy.source = source
	copy.unknown_class = unknown_class
	copy.id = id
	if not id_map.has(id):
		id_map[id] = copy
	if deep:
		for child in children:
			copy.add_child(child.clone(true, id_map))
	return copy


## Depth first walk in the same order Roblox serializes files.
func walk(visitor: Callable) -> void:
	visitor.call(self)
	for child in children:
		child.walk(visitor)


func add_warning(text: String) -> void:
	if warnings.size() < 32 and not warnings.has(text):
		warnings.append(text)


## Godot's `Object` already owns `to_string()`, so the string form is the
## virtual `_to_string()` the engine calls from `str()`.
func _to_string() -> String:
	return "%s(%s)" % [rbx_class, get_name()]


## Renders a compact summary for the explorer panel.
func summary() -> String:
	return "%s \"%s\"" % [rbx_class, get_name()]
