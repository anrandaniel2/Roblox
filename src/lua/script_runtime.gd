class_name RBXScriptRuntime
extends RefCounted
## Runs a place's scripts on the Luau VM.
##
## One runtime owns one `LuauVMState`: the API is installed, the place's scripts
## run in tree order (a parent's scripts before its children's, so services are
## alive before anything reaches for them), and then the globals are frozen.
## Nothing here may assume the extension is present — `start()` returns false and
## the caller keeps running without scripts, which is what happens in the editor
## and in headless tooling that has no extension built.

signal script_finished(path: String, ok: bool)

## Scripts that do not run server-side in Roblox but still define behaviour we
## want when there is no client/server split yet.
const SCRIPT_CLASSES := ["Script", "LocalScript"]

const MAX_SCRIPTS := 512
const MAX_SCRIPT_BYTES := 2 * 1024 * 1024

var available: bool = false
var scripts_run: int = 0
var last_error: String = ""

var _vm: Object = null
var _api: RBXScriptAPI = null
var _place: RBXPlace = null
var _sources: Array[Dictionary] = []


## Brings up a VM for `place`. Returns false when scripting cannot run, which the
## caller should treat as "the place simply has no scripts".
func start(place: RBXPlace) -> bool:
	stop()
	_place = place
	_api = RBXScriptAPI.new()
	if not _api.is_available():
		last_error = "The Luau extension is not loaded."
		available = false
		return false

	_vm = ClassDB.instantiate("LuauVMState")
	if _vm == null:
		last_error = "Could not create a Luau state."
		available = false
		return false

	_vm.call("set_optimization_level", 1)
	if not _api.install(_vm, place):
		last_error = String(_vm.call("get_last_error"))
		available = false
		return false

	available = true
	_collect_scripts(place)
	run_collected()

	if RbxSettings.scripting_sandbox:
		_api.sandbox()
	RbxLog.info("Luau runtime ready: %d script(s) ran." % scripts_run, "script")
	return true


func stop() -> void:
	if _vm != null:
		_vm.call("reset")
	_vm = null
	_api = null
	_place = null
	_sources.clear()
	scripts_run = 0
	available = false


func is_running() -> bool:
	return available and _vm != null


## Runs one chunk in the place's context — used by the console and by tests.
func run(source: String, chunk_name: String = "@console") -> bool:
	if _vm == null or _api == null:
		return false
	var ok: bool = _api.run(source, chunk_name)
	script_finished.emit(chunk_name, ok)
	return ok


func get_global(name: String) -> Variant:
	if _vm == null:
		return null
	return _vm.call("get_global", name)


func set_global(name: String, value: Variant) -> void:
	if _vm != null:
		_vm.call("set_global", name, value)


func memory_used() -> int:
	if _vm == null:
		return 0
	return int(_vm.call("get_memory_used"))


# ---------------------------------------------------------------------------
# Collecting and running the place's scripts
# ---------------------------------------------------------------------------

func _collect_scripts(place: RBXPlace) -> void:
	var budget := [MAX_SCRIPT_BYTES]
	for root: RBXInstance in place.roots:
		_collect_from(root, budget)


func _collect_from(instance: RBXInstance, budget: Array) -> void:
	if SCRIPT_CLASSES.has(instance.rbx_class):
		var source: Variant = instance.get_property("Source")
		if source is String and not (source as String).is_empty():
			var text: String = source
			if text.length() <= int(budget[0]):
				budget[0] = int(budget[0]) - text.length()
				_sources.append({"path": instance.path() if instance.has_method("path") else instance.get_name(), "source": text})
	elif instance.rbx_class == "ModuleScript":
		# Modules are required on demand; nothing runs them at load time.
		pass
	for child: RBXInstance in instance.children:
		_collect_from(child, budget)


func run_collected() -> void:
	var count := 0
	for entry in _sources:
		if count >= MAX_SCRIPTS:
			RbxLog.warn("Stopped after %d scripts; the rest of the place was not started." % MAX_SCRIPTS, "script")
			break
		count += 1
		var path := String(entry["path"])
		var ok := run(String(entry["source"]), path)
		scripts_run += 1
		if not ok:
			last_error = String(_vm.call("get_last_error"))
