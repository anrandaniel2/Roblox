extends Node
## Headless checks for the Roblox API layer that sits on top of the Luau VM.
##
##     godot --headless --path . res://tests/lua_api_smoke.tscn
##
## The VM itself is covered by `tests/luau_smoke.gd`; this one proves a *place*
## can run scripts: the API table installs, `Instance.new` builds real instances
## in the data model, property syntax reads and writes through the bridge, and a
## script error is reported without taking the runtime down.
##
## Runs in the extension CI job, where the GDExtension has been built. Without it
## the test reports SKIP and passes, so it is safe to run anywhere.

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _ready() -> void:
	print("--- roblox api smoke test ---")
	print("Godot %s" % Engine.get_version_info().get("string", "unknown"))

	if not ClassDB.class_exists("LuauVMState"):
		print("SKIP: the Luau extension is not loaded in this build.")
		get_tree().quit(0)
		return

	# The sandbox freezes the global table once the place's own scripts have been
	# collected, and these checks write globals from Luau to read them back.  The
	# sandbox itself is covered by the extension smoke test.
	RbxSettings.scripting_sandbox = false

	var place := RBXPlace.new()
	place.name = "api_test"

	var runtime := RBXScriptRuntime.new()
	if not runtime.start(place):
		_fail("the runtime did not start: %s" % runtime.last_error)
		_finish()
		return
	_check(runtime.available, "the Luau runtime started")

	_check_script_run(runtime)
	_check_data_model(place)
	_check_error_recovery(runtime)
	_check_methods(runtime)
	_finish()


const SCRIPT := """
--!nocheck
local part = Instance.new('Part')
part.Name = 'SmokePart'
part.Size = Vector3.new(4, 1, 2)
part.Anchored = true
part.Parent = workspace

local folder = Instance.new('Folder')
folder.Name = 'Group'
folder.Parent = workspace

local sum = Vector3.new(1, 2, 3) + Vector3.new(10, 20, 30)
local scaled = Vector3.new(2, 4, 6) * 0.5

api_result = {
	name = part.Name,
	size = part.Size,
	anchored = part.Anchored,
	parent_name = part.Parent.Name,
	children = #workspace:GetChildren(),
	sum_x = sum.x,
	magnitude = Vector3.new(3, 4, 0).Magnitude,
	scaled_z = scaled.z,
	kind = typeof(part),
	full_name = part:GetFullName(),
}
print('api test script finished')
"""


func _check_script_run(runtime: RBXScriptRuntime) -> void:
	_check(runtime.run(SCRIPT, "@api_test"), "the API script ran: %s" % runtime.last_error)

	var result: Variant = runtime.get_global("api_result")
	if not (result is Dictionary):
		_fail("the script did not leave a result table (got %s)" % str(result))
		return
	var table: Dictionary = result
	_check(table.get("name", "") == "SmokePart", "Name reads back through the bridge")
	_check(table.get("anchored", false) == true, "a boolean property round-trips")
	_check(table.get("parent_name", "") == "Workspace", "Parent resolves to the service")
	_check(table.get("kind", "") == "Instance", "typeof() recognises an instance")
	_check(int(table.get("children", 0)) >= 2, "the new instances are children of workspace")
	_check(is_equal_approx(float(table.get("sum_x", 0.0)), 11.0), "Vector3 addition works")
	_check(is_equal_approx(float(table.get("magnitude", 0.0)), 5.0), "Vector3.Magnitude works")
	_check(is_equal_approx(float(table.get("scaled_z", 0.0)), 3.0), "Vector3 scaling works")
	_check(String(table.get("full_name", "")).contains("SmokePart"), "GetFullName() walks the tree")

	var size: Variant = table.get("size", null)
	_check(size is Dictionary and is_equal_approx(float((size as Dictionary).get("y", 0.0)), 1.0),
		"a Vector3 property reads back as x/y/z")


func _check_data_model(place: RBXPlace) -> void:
	var workspace := place.get_service("Workspace")
	if workspace == null:
		_fail("the script did not create a Workspace service")
		return

	var part := _find_child(workspace, "SmokePart")
	_check(part != null, "Instance.new added the part to the data model")
	if part != null:
		_check(part.rbx_class == "Part", "the new instance has the requested class")
		var size: Variant = part.get_property("Size")
		_check(size is Vector3 and (size as Vector3).is_equal_approx(Vector3(4.0, 1.0, 2.0)),
			"the size written from Luau is a Vector3 in the data model (got %s)" % str(size))
		_check(part.get_property("Anchored") == true, "the anchored flag reached the data model")

	_check(_find_child(workspace, "Group") != null, "the folder was parented too")
	_check(place.renderable_count() >= 1, "the imported scene sees the new part")


func _check_error_recovery(runtime: RBXScriptRuntime) -> void:
	_check(not runtime.run("error('script blew up')", "@broken"), "a failing script reports failure")
	_check(runtime.run("recovered = 42", "@recovered"), "the runtime keeps working after an error")
	_check(runtime.get_global("recovered") == 42, "state survives a failed script")


func _check_methods(runtime: RBXScriptRuntime) -> void:
	var source := """
--!nocheck
local workspace_children = workspace:GetChildren()
local found = workspace:FindFirstChild('SmokePart')
local descendants = workspace:GetDescendants()
method_result = {
	children = #workspace_children,
	found = found ~= nil and found.Name or 'missing',
	descendants = #descendants,
	is_a = found and found:IsA('BasePart') or false,
}
"""
	_check(runtime.run(source, "@methods"), "the instance methods ran: %s" % runtime.last_error)
	var result: Variant = runtime.get_global("method_result")
	if not (result is Dictionary):
		_fail("the method script did not leave a result")
		return
	var table: Dictionary = result
	_check(int(table.get("children", 0)) >= 2, "GetChildren() lists the new instances")
	_check(table.get("found", "") == "SmokePart", "FindFirstChild() finds by name")
	_check(int(table.get("descendants", 0)) >= 2, "GetDescendants() walks the tree")
	_check(table.get("is_a", false) == true, "IsA() consults the reflection database")


func _find_child(parent: RBXInstance, wanted: String) -> RBXInstance:
	for child: RBXInstance in parent.children:
		if child.get_name() == wanted:
			return child
	return null


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
		print("LUA_API_SMOKE PASS checks=%d" % _checks)
		get_tree().quit(0)
		return
	print("LUA_API_SMOKE FAIL checks=%d failures=%d" % [_checks, _failures.size()])
	for failure in _failures:
		print("  - %s" % failure)
	get_tree().quit(1)
