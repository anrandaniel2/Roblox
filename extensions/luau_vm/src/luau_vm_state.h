#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

struct lua_State;

namespace godot {

/**
 * One Luau virtual machine.
 *
 * The emulator creates one state per script context (server, and one per client
 * in the future) and injects the Roblox API as globals before calling
 * `sandbox()` to freeze them, mirroring how Roblox sets up an environment.
 */
class LuauVMState : public RefCounted {
	GDCLASS(LuauVMState, RefCounted)

	lua_State *state = nullptr;
	bool sandboxed = false;
	int optimization_level = 1;
	int debug_level = 1;
	String last_error;
	String last_traceback;

	void _capture_error_from_stack();
	bool _execute(int p_arg_count, int p_result_count);
	void _push_variant(const Variant &p_value);
	Variant _read_variant(int p_index);
	Variant _read_table(int p_index);

protected:
	static void _bind_methods();

public:
	LuauVMState();
	~LuauVMState() override;

	/** Drops the current state and starts a fresh, empty one. */
	void reset();
	bool is_valid() const;

	/** Compiles `p_source` and leaves the resulting function on the stack. */
	bool load(const String &p_source, const String &p_chunk_name = "chunk");
	/** Compiles and runs `p_source` to completion. */
	bool run(const String &p_source, const String &p_chunk_name = "chunk");
	/** Calls a global function and returns its results as an Array. */
	Array call_global(const String &p_function, const Array &p_args = Array());

	/** Injects a global; safe to call while sandboxed. */
	void set_global(const String &p_name, const Variant &p_value);
	Variant get_global(const String &p_name);

	/** Freezes globals (`luaL_sandbox`). Call after injecting the API. */
	void sandbox();
	bool is_sandboxed() const;

	void set_optimization_level(int p_level);
	int get_optimization_level() const;

	String get_last_error() const;
	String get_last_traceback() const;
	bool has_error() const;

	/** Bytes currently held by the Luau allocator. */
	int64_t get_memory_used() const;
};

} // namespace godot
