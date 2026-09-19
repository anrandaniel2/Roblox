class_name RBXScriptAPI
extends RefCounted
## The Roblox API surface, exposed to Luau.
##
## The split is deliberate: everything that needs to touch the data model goes
## through a handful of host callables implemented here in GDScript (where
## `RBXInstance` already lives), while the object model that scripts actually see
## — `Instance.new`, `:GetChildren()`, property syntax, `Vector3` arithmetic — is
## written in Luau in `PRELUDE` below. That keeps the C++ layer a plain
## value/function bridge and puts the "Roblox-ness" somewhere easy to extend.
##
## Nothing here needs the extension to be present: `install()` reports false when
## the VM class is missing, so the editor and headless tooling still work.

const HOST_TABLE := "__rbxhost"

## Host callables are referenced from Luau by name, so the table doubles as the
## documentation for what the prelude may rely on.
const HOST_FUNCTIONS := [
	"print_line", "warn_line", "new_instance", "get", "set", "children",
	"parent", "set_parent", "class_name", "instance_name", "find_child",
	"destroy", "service", "is_a", "full_name", "clone",
]

var _vm: Object = null
var _place: RBXPlace = null
var _instances: Dictionary = {}


func is_available() -> bool:
	return ClassDB.class_exists("LuauVMState")


## Installs the API into `vm` and returns false when the extension is missing.
func install(vm: Object, place: RBXPlace) -> bool:
	_vm = vm
	_place = place
	_instances.clear()
	if not is_available():
		RbxLog.warn("The Luau extension is not loaded; scripts are disabled.", "script")
		return false

	var host := {}
	for name in HOST_FUNCTIONS:
		host[name] = Callable(self, "_host_" + name)
	_vm.call("set_global", HOST_TABLE, host)

	var ok: bool = _vm.call("run", PRELUDE, "@rbx/prelude")
	if not ok:
		RbxLog.error("The Luau prelude failed: %s" % _vm.call("get_last_error"), "script")
		return false
	RbxLog.info("Roblox API installed into the Luau state.", "script")
	return true


## Runs one chunk with the API available and reports the outcome.
func run(source: String, chunk_name: String) -> bool:
	if _vm == null:
		return false
	var ok: bool = _vm.call("run", source, chunk_name)
	if not ok:
		RbxLog.error("%s: %s" % [chunk_name, String(_vm.call("get_last_error")).strip_edges()], "script")
		var traceback := String(_vm.call("get_last_traceback")).strip_edges()
		if not traceback.is_empty():
			RbxLog.debug("%s traceback:\n%s" % [chunk_name, traceback], "script")
	return ok


## Freezes the globals once the API is in place, as Roblox does for game code.
func sandbox() -> void:
	if _vm != null:
		_vm.call("sandbox")


# ---------------------------------------------------------------------------
# Host functions — the bridge between the data model and Luau
# ---------------------------------------------------------------------------

func _host_print_line(text: String) -> void:
	RbxLog.info(text, "print")


func _host_warn_line(text: String) -> void:
	RbxLog.warn(text, "print")


func _host_new_instance(rbx_class: String, parent: Variant) -> int:
	var instance := RBXInstance.new()
	instance.rbx_class = rbx_class
	if instance.is_a("BasePart"):
		instance.set_property("Size", Vector3(4.0, 1.2, 2.0))
		instance.set_property("Anchored", false)
	_register(instance)
	if parent != null:
		instance.parent = _resolve(parent)
	return instance.id


func _host_get(id: int, property: String) -> Variant:
	var instance := _resolve(id)
	if instance == null:
		return null
	if property == "Name":
		return instance.get_name()
	if property == "Parent":
		return instance.parent.id if instance.parent != null else null
	if property == "ClassName":
		return instance.rbx_class
	var value: Variant = instance.get_property(property)
	# Instance-valued properties cross as `{ __ref = id }` so the prelude can
	# hand back a wrapped object instead of a loose number.
	if value is RBXInstance:
		return {"__ref": (value as RBXInstance).id}
	return value


func _host_set(id: int, property: String, value: Variant) -> void:
	var instance := _resolve(id)
	if instance == null:
		return
	if property == "Name":
		instance.set_name(str(value))
		return
	var resolved := _resolve(value)
	if resolved != null:
		instance.set_property(property, resolved)
		return
	instance.set_property(property, _from_lua_value(value))


func _host_children(id: int) -> Array:
	var instance := _resolve(id)
	if instance == null:
		return []
	var ids: Array = []
	for child: RBXInstance in instance.children:
		_register(child)
		ids.append(child.id)
	return ids


func _host_parent(id: int) -> Variant:
	var instance := _resolve(id)
	if instance == null or instance.parent == null:
		return null
	_register(instance.parent)
	return instance.parent.id


func _host_set_parent(id: int, parent: Variant) -> void:
	var instance := _resolve(id)
	if instance == null:
		return
	var new_parent := _resolve(parent)
	if instance.parent != null:
		instance.parent.remove_child(instance)
	if new_parent != null:
		new_parent.add_child(instance)


func _host_class_name(id: int) -> String:
	var instance := _resolve(id)
	return instance.rbx_class if instance != null else ""


func _host_instance_name(id: int) -> String:
	var instance := _resolve(id)
	return instance.get_name() if instance != null else ""


func _host_find_child(id: int, wanted: String) -> Variant:
	var instance := _resolve(id)
	if instance == null:
		return null
	for child: RBXInstance in instance.children:
		if child.get_name() == wanted:
			_register(child)
			return child.id
	return null


func _host_destroy(id: int) -> void:
	var instance := _resolve(id)
	if instance == null:
		return
	if instance.parent != null:
		instance.parent.remove_child(instance)
	else:
		_instances.erase(id)
		instance.destroyed.emit()


func _host_is_a(id: int, wanted: String) -> bool:
	var instance := _resolve(id)
	return instance != null and instance.is_a(wanted)


func _host_full_name(id: int) -> String:
	var instance := _resolve(id)
	return instance.path() if instance != null and instance.has_method("path") else ""


func _host_clone(id: int) -> Variant:
	var instance := _resolve(id)
	if instance == null:
		return null
	var copy: RBXInstance = instance.clone() if instance.has_method("clone") else null
	if copy == null:
		return null
	_register(copy)
	return copy.id


## `game:GetService(name)` and the `workspace` global both come through here.
func _host_service(name: String) -> Variant:
	if _place == null:
		return null
	var service := _place.ensure_service(name)
	if service == null:
		return null
	_register(service)
	return service.id


func _register(instance: RBXInstance) -> void:
	if instance.id < 0:
		instance.id = _instances.size() + 1
	_instances[instance.id] = instance


## Luau has no Vector3 type of its own: the prelude builds one out of a table,
## so it arrives here as `{x, y, z}` and has to be folded back into the engine
## type the data model stores.
func _from_lua_value(value: Variant) -> Variant:
	if value is Dictionary:
		var table := value as Dictionary
		if table.has("x") and table.has("y") and table.has("z"):
			return Vector3(float(table["x"]), float(table["y"]), float(table["z"]))
	return value


## Accepts either an id or `{ __ref = id }` as handed out to Lua.
func _resolve(value: Variant) -> RBXInstance:
	if value is RBXInstance:
		return value
	var id := -1
	if value is int or value is float:
		id = int(value)
	elif value is Dictionary and (value as Dictionary).has("__ref"):
		id = int((value as Dictionary)["__ref"])
	if id < 0:
		return null
	return _instances.get(id, null)


# ---------------------------------------------------------------------------
# The Luau half of the API
# ---------------------------------------------------------------------------

const PRELUDE := """
-- Roblox-shaped object model, built on the host callables below.
local host = __rbxhost

local Instance = {}
Instance.__index = Instance

local function wrap(id)
	if id == nil then return nil end
	if type(id) == 'table' then id = id.__ref end
	if id == nil then return nil end
	return setmetatable({ __id = id }, Instance)
end

local function coerce(value)
	if type(value) == 'table' then
		if value.__ref then return wrap(value.__ref) end
		if value.x and value.y and value.z then return Vector3.new(value.x, value.y, value.z) end
	end
	return value
end

local function unwrap(value)
	if type(value) == 'table' then
		if value.__id then return value.__id end
		if value.__ref then return value.__ref end
	end
	return value
end

local methods = {}

function methods:GetChildren()
	local out = {}
	for _, id in host.children(self.__id) do
		table.insert(out, wrap(id))
	end
	return out
end

function methods:GetDescendants()
	local out = {}
	local function walk(parent)
		for _, child in parent:GetChildren() do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(self)
	return out
end

function methods:FindFirstChild(name)
	local id = host.find_child(self.__id, name)
	return wrap(id)
end

function methods:WaitForChild(name)
	local found = self:FindFirstChild(name)
	if found then return found end
	return nil
end

function methods:IsA(class)
	return host.is_a(self.__id, class)
end

function methods:GetFullName()
	return host.full_name(self.__id)
end

function methods:Destroy()
	host.destroy(self.__id)
end

function methods:Clone()
	return wrap(host.clone(self.__id))
end

Instance.__index = function(self, key)
	local method = methods[key]
	if method then return method end
	if key == 'ClassName' then return host.class_name(self.__id) end
	if key == 'Name' then return host.instance_name(self.__id) end
	if key == 'Parent' then return wrap(host.parent(self.__id)) end
	return coerce(host.get(self.__id, key))
end

Instance.__newindex = function(self, key, value)
	if key == 'Parent' then
		host.set_parent(self.__id, unwrap(value))
		return
	end
	if key == 'Name' then
		host.set(self.__id, 'Name', tostring(value))
		return
	end
	host.set(self.__id, key, unwrap(value))
end

Instance.__tostring = function(self)
	return host.instance_name(self.__id)
end

function Instance.new(class, parent)
	local id = host.new_instance(class, parent and parent.__id or nil)
	local object = wrap(id)
	if parent then host.set_parent(id, parent.__id) end
	return object
end

-- Vector3 with the arithmetic every Roblox script uses.
local Vector3 = {}
Vector3.__index = Vector3
Vector3.__add = function(a, b) return Vector3.new(a.x + b.x, a.y + b.y, a.z + b.z) end
Vector3.__sub = function(a, b) return Vector3.new(a.x - b.x, a.y - b.y, a.z - b.z) end
Vector3.__mul = function(a, b)
	if type(b) == 'number' then return Vector3.new(a.x * b, a.y * b, a.z * b) end
	return Vector3.new(a.x * b.x, a.y * b.y, a.z * b.z)
end
Vector3.__unm = function(a) return Vector3.new(-a.x, -a.y, -a.z) end
Vector3.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
Vector3.__tostring = function(a)
	return string.format('%.3f, %.3f, %.3f', a.x, a.y, a.z)
end
Vector3.__index = function(self, key)
	if key == 'Magnitude' then return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
	if key == 'Unit' then
		local m = math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2)
		if m == 0 then return Vector3.new(0, 0, 0) end
		return Vector3.new(self.x / m, self.y / m, self.z / m)
	end
	return rawget(Vector3, key)
end

function Vector3.new(x, y, z)
	return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vector3)
end

-- CFrame carries a position; rotation is still identity in the emulator.
local CFrame = {}
CFrame.__index = function(self, key)
	if key == 'Position' or key == 'p' then
		return Vector3.new(self.x, self.y, self.z)
	end
	return rawget(CFrame, key)
end
CFrame.__add = function(a, b) return CFrame.new(a.x + b.x, a.y + b.y, a.z + b.z) end
CFrame.__tostring = function(a) return string.format('CFrame(%.3f, %.3f, %.3f)', a.x, a.y, a.z) end

function CFrame.new(x, y, z)
	if type(x) == 'table' then return setmetatable({ x = x.x, y = x.y, z = x.z }, CFrame) end
	return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, CFrame)
end

-- The DataModel.
local game = setmetatable({}, {
	__index = function(_, key)
		local id = host.service(key)
		if id == nil then return nil end
		return wrap(id)
	end,
	__tostring = function() return 'game' end,
})

function game:GetService(name)
	local id = host.service(name)
	if id == nil then
		error('Unknown service: ' .. tostring(name), 2)
	end
	return wrap(id)
end

function game:IsLoaded() return true end

-- task/legacy scheduling: the runtime drives frames, so these are cooperative
-- stubs that keep scripts running instead of yielding forever.
local task = {}
function task.wait(seconds) return seconds or 0 end
function task.spawn(fn, ...) return fn(...) end
function task.defer(fn, ...) return fn(...) end
function task.delay(_, fn, ...) return fn(...) end

-- Hand the object model to scripts.  Every table above is a local, so
-- `Instance = Instance` would just write the local again (the name resolves to
-- the local in scope) and scripts would find empty globals -- which is exactly
-- what "attempt to index nil with 'new'" meant.  The global table has to be
-- named explicitly.
local exports = {
	Instance = Instance,
	Vector3 = Vector3,
	CFrame = CFrame,
	game = game,
	task = task,
	workspace = wrap(host.service('Workspace')),
}
for name, value in exports do
	_G[name] = value
end

function wait(seconds) return task.wait(seconds) end
function spawn(fn, ...) return task.spawn(fn, ...) end
function delay(seconds, fn, ...) return task.delay(seconds, fn, ...) end

function typeof(value)
	local t = type(value)
	if t == 'table' then
		if value.__id then return 'Instance' end
		if getmetatable(value) == Vector3 then return 'Vector3' end
		if getmetatable(value) == CFrame then return 'CFrame' end
	end
	return t
end

function tick()
	return os.clock()
end
"""
