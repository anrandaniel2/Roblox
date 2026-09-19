extends SceneTree
## Headless smoke test for the `luau_vm` GDExtension.
##
##     godot --headless --path . --script res://tests/luau_smoke.gd
##
## It proves the extension builds, links and loads on this Godot build, that the
## Luau-specific syntax Roblox games use actually compiles, that values cross the
## GDScript/Luau boundary, and that a broken script reports an error instead of
## taking the process down.

const EXPECTED_CLASS := "LuauVMState"

var _failures: Array[String] = []


func _initialize() -> void:
	print("--- luau_vm smoke test ---")
	print("Godot %s" % Engine.get_version_info().get("string", "unknown"))

	if not ClassDB.class_exists(EXPECTED_CLASS):
		_fail("The GDExtension did not load: ClassDB has no `%s`." % EXPECTED_CLASS)
		_finish()
		return

	var vm: Variant = ClassDB.instantiate(EXPECTED_CLASS)
	if vm == null:
		_fail("`%s` exists but could not be instantiated." % EXPECTED_CLASS)
		_finish()
		return

	_check(vm.is_valid(), "a fresh state is valid")
	_test_luau_syntax(vm)
	_test_values(vm)
	_test_functions(vm)
	_test_errors_are_survivable(vm)
	_test_sandbox(vm)
	_finish()


## Type annotations, `continue`, compound assignment and backtick interpolation
## are all rejected by stock Lua 5.4 — they must work here.
func _test_luau_syntax(vm: Variant) -> void:
	var source := """
--!strict
local total: number = 0
for index = 1, 10 do
	if index % 2 == 0 then continue end
	total += index
end
local label: string = `odd total = {total}`
result = { total = total, label = label }
"""
	_check(vm.run(source, "syntax"), "Luau syntax compiles and runs: %s" % vm.get_last_error())
	var result: Variant = vm.get_global("result")
	if result is Dictionary:
		_check(result.get("total", -1) == 25, "compound assignment + continue gave 25 (got %s)" % result.get("total", "nil"))
		_check(result.get("label", "") == "odd total = 25", "backtick interpolation produced '%s'" % result.get("label", ""))
	else:
		_fail("expected a Dictionary from the chunk, got %s" % str(result))


func _test_values(vm: Variant) -> void:
	vm.set_global("payload", {"name": "part", "tags": ["a", "b"], "size": Vector3(4, 1.2, 2)})
	var payload: Variant = vm.get_global("payload")
	if payload is Dictionary:
		_check(payload.get("name", "") == "part", "strings survive the round trip")
		var size: Variant = payload.get("size", null)
		_check(size is Dictionary and is_equal_approx(size.get("x", 0.0), 4.0), "Vector3 becomes a table with x/y/z")
	else:
		_fail("expected a Dictionary back from Luau, got %s" % str(payload))

	_check(vm.run("round_tripped = { 1, 2, 3 }", "array"), "array literal runs")
	var array: Variant = vm.get_global("round_tripped")
	_check(array is Array and array.size() == 3 and array[2] == 3, "sequential tables come back as 1-based Arrays")
	_check(vm.get_memory_used() > 0, "the Luau allocator reports memory use")


func _test_functions(vm: Variant) -> void:
	vm.run("function add(a, b) return a + b, 'sum' end", "function")
	var results: Variant = vm.call_global("add", [2, 3])
	_check(results is Array and results.size() == 2, "call_global returns every value")
	if results is Array and results.size() == 2:
		_check(results[0] == 5, "arguments crossed into Luau and back (2 + 3 = %s)" % str(results[0]))
		_check(results[1] == "sum", "multiple return values are preserved")


func _test_errors_are_survivable(vm: Variant) -> void:
	var ok := vm.run("error('this chunk is broken')", "broken")
	_check(not ok, "a failing chunk reports failure")
	_check(vm.has_error(), "the failure is queryable")
	_check(String(vm.get_last_error()).contains("broken"), "the error message is preserved: %s" % vm.get_last_error())
	_check(not String(vm.get_last_traceback()).is_empty(), "a traceback was captured")
	# The state must stay usable afterwards: one bad script cannot poison the VM.
	_check(vm.run("recovered = 7", "recovered"), "the state still runs chunks after an error")
	_check(vm.get_global("recovered") == 7, "the state kept working after the error")
	_check(not vm.run("local =", "syntax error"), "a syntax error is reported, not fatal")
	_check(vm.has_error(), "the syntax error was captured")


func _test_sandbox(vm: Variant) -> void:
	vm.set_global("before_sandbox", 1)
	vm.sandbox()
	_check(vm.is_sandboxed(), "sandbox() reports the state as sandboxed")

	var escaped := vm.run("sneaky_global = 99", "escape")
	_check(not escaped, "writing a new global inside a sandbox fails")
	if not escaped:
		print("    sandbox refused: %s" % vm.get_last_error())

	# Injecting API globals from the host must keep working while sandboxed.
	vm.set_global("after_sandbox", 2)
	_check(vm.get_global("after_sandbox") == 2, "host-injected globals still work while sandboxed")
	_check(vm.get_global("before_sandbox") == 1, "globals injected before the sandbox are still readable")


func _check(condition: bool, description: String) -> void:
	if condition:
		print("  ok    %s" % description)
	else:
		_fail(description)


func _fail(description: String) -> void:
	_failures.append(description)
	printerr("  FAIL  %s" % description)


func _finish() -> void:
	if _failures.is_empty():
		print("--- luau_vm smoke test passed ---")
		quit(0)
	else:
		printerr("--- luau_vm smoke test failed (%d) ---" % _failures.size())
		for failure in _failures:
			printerr("  - %s" % failure)
		quit(1)
