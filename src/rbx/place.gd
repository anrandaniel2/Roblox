class_name RBXPlace
extends RefCounted
## A parsed Roblox place or model, plus everything the importer needs to know
## about how it was read.
##
## A `.rbxl` (place) file stores the *services* as root instances (`Workspace`,
## `Lighting`, `Players`, ...).  A `.rbxm` (model) file stores arbitrary
## instances instead.  `RBXPlace` papers over that difference: `is_place()`
## tells you which one it is and `ensure_service()` will create a missing
## service so a model can be dropped into a playable world.

var name: String = "Untitled"
var path: String = ""
var format: String = "unknown" ## `binary`, `xml` or `unknown`
var file_size: int = 0
var roots: Array[RBXInstance] = []
var metadata: Dictionary = {}
var stats: Dictionary = {}
var warnings: PackedStringArray = PackedStringArray()
## Set when the file could not be read at all (empty, not a Roblox file, ...).
var load_error: String = ""

var _data_model: RBXInstance = null

## Service classes that Roblox always keeps at the root of a place.
const KNOWN_SERVICES := [
	"Workspace", "Lighting", "Players", "ReplicatedFirst", "ReplicatedStorage",
	"ServerScriptService", "ServerStorage", "StarterGui", "StarterPack",
	"StarterPlayer", "SoundService", "Chat", "Teams", "TestService",
	"MaterialService", "TextChatService", "LocalizationService",
	"PhysicsService", "TweenService", "Debris", "ScriptContext", "JointsService",
	"ContentProvider", "ContextActionService", "UserInputService", "HttpService",
	"CollectionService", "PathfindingService", "RunService",
]


func add_warning(text: String) -> void:
	if warnings.size() < 64 and not warnings.has(text):
		warnings.append(text)


func is_place() -> bool:
	for root in roots:
		if KNOWN_SERVICES.has(root.rbx_class):
			return true
	return false


## The synthetic `DataModel` that Roblox uses as the parent of every service.
func data_model() -> RBXInstance:
	if _data_model == null:
		var model := RBXInstance.create("DataModel")
		model.set_name("game")
		for root in roots:
			model.add_child(root)
		_data_model = model
	return _data_model


func get_service(service_name: String) -> RBXInstance:
	for root in roots:
		if root.rbx_class == service_name:
			return root
	return null


## Returns the service, creating an empty one when the file did not contain it.
func ensure_service(service_name: String) -> RBXInstance:
	var found := get_service(service_name)
	if found != null:
		return found
	var created := RBXInstance.create(service_name)
	created.set_name(service_name)
	roots.append(created)
	return created


func workspace() -> RBXInstance:
	return get_service("Workspace")


func lighting() -> RBXInstance:
	return get_service("Lighting")


func total_instances() -> int:
	var total := 0
	for root in roots:
		total += 1 + root.descendants_count()
	return total


func class_histogram() -> Dictionary:
	var histogram: Dictionary = {}
	var stack: Array[RBXInstance] = roots.duplicate()
	while not stack.is_empty():
		var instance: RBXInstance = stack.pop_back()
		histogram[instance.rbx_class] = int(histogram.get(instance.rbx_class, 0)) + 1
		for child in instance.children:
			stack.append(child)
	return histogram


func instances_of_class_on_root(rbx_class: String, limit: int = -1) -> Array[RBXInstance]:
	var out: Array[RBXInstance] = []
	for root in roots:
		for descendant in root.get_descendants(limit):
			if descendant.rbx_class == rbx_class:
				out.append(descendant)
				if limit > 0 and out.size() >= limit:
					return out
		if root.rbx_class == rbx_class:
			out.append(root)
	return out


## Instances that the importer has to turn into something visible.
func renderable_count() -> int:
	var count := 0
	for root in roots:
		count += _count_renderable(root)
	return count


func _count_renderable(instance: RBXInstance) -> int:
	var total := 1 if _is_renderable(instance) else 0
	for child in instance.children:
		total += _count_renderable(child)
	return total


static func _is_renderable(instance: RBXInstance) -> bool:
	if instance.is_a("BasePart"):
		return true
	if instance.rbx_class == "Model" or instance.rbx_class == "Folder":
		return false
	if instance.rbx_class == "Script" or instance.rbx_class == "LocalScript" or instance.rbx_class == "ModuleScript":
		return false
	return instance.is_a("GuiObject") or instance.rbx_class == "ScreenGui" \
		or instance.is_a("Light") or instance.is_a("Decal") or instance.is_a("MeshPart")


func find_instance_by_path(path: String) -> RBXInstance:
	var segments := path.split(".", false)
	if segments.is_empty():
		return null
	var current: RBXInstance = null
	for root in roots:
		if root.get_name() == segments[0] or root.rbx_class == segments[0]:
			current = root
			break
	if current == null:
		return null
	for index in range(1, segments.size()):
		current = current.find_first_child(segments[index])
		if current == null:
			return null
	return current


func summary(limit: int = 6) -> String:
	var histogram := class_histogram()
	var keys := histogram.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return int(histogram[a]) > int(histogram[b]))
	var parts := PackedStringArray()
	for index in mini(limit, keys.size()):
		parts.append("%s ×%d" % [keys[index], histogram[keys[index]]])
	return "%d instances (%s)" % [total_instances(), ", ".join(parts)]


func describe_roots() -> PackedStringArray:
	var out := PackedStringArray()
	for root in roots:
		out.append("%s (%d children)" % [root.rbx_class, root.children.size()])
	return out
