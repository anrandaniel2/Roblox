#include "luau_vm_state.h"

#include <cstdlib>
#include <cstring>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/char_string.hpp>

// Luau's C API. The headers carry no C++ guards of their own and are meant to be
// included directly.
#include <lua.h>
#include <luacode.h>
#include <lualib.h>

using namespace godot;

LuauVMState::LuauVMState() {
	reset();
}

LuauVMState::~LuauVMState() {
	if (state != nullptr) {
		lua_close(state);
		state = nullptr;
	}
}

void LuauVMState::reset() {
	if (state != nullptr) {
		lua_close(state);
		state = nullptr;
	}
	sandboxed = false;
	last_error = String();
	last_traceback = String();

	state = luaL_newstate();
	if (state == nullptr) {
		last_error = "Could not allocate a Luau state.";
		return;
	}
	luaL_openlibs(state);
}

bool LuauVMState::is_valid() const {
	return state != nullptr;
}

bool LuauVMState::load(const String &p_source, const String &p_chunk_name) {
	last_error = String();
	last_traceback = String();
	if (state == nullptr) {
		last_error = "The Luau state is not available.";
		return false;
	}

	CharString source = p_source.utf8();
	CharString chunk_name = (p_chunk_name.is_empty() ? String("chunk") : p_chunk_name).utf8();

	lua_CompileOptions options;
	std::memset(&options, 0, sizeof(options));
	options.optimizationLevel = optimization_level;
	// Line info and function names are what make a traceback readable.
	options.debugLevel = debug_level;
	options.typeInfoLevel = 0;
	options.coverageLevel = 0;

	size_t bytecode_size = 0;
	char *bytecode = luau_compile(source.get_data(), static_cast<size_t>(source.length()), &options, &bytecode_size);
	if (bytecode == nullptr) {
		last_error = "Luau could not compile the chunk.";
		return false;
	}

	// A failed compile still returns a buffer; it holds the encoded error and
	// `luau_load` turns it back into a message on the stack.
	int status = luau_load(state, chunk_name.get_data(), bytecode, bytecode_size, 0);
	std::free(bytecode);

	if (status != 0) {
		_capture_error_from_stack();
		return false;
	}
	return true;
}

bool LuauVMState::run(const String &p_source, const String &p_chunk_name) {
	if (!load(p_source, p_chunk_name)) {
		return false;
	}
	if (!_execute(0, LUA_MULTRET)) {
		lua_settop(state, 0);
		return false;
	}
	lua_settop(state, 0);
	return true;
}

Array LuauVMState::call_global(const String &p_function, const Array &p_args) {
	Array results;
	last_error = String();
	last_traceback = String();

	if (state == nullptr) {
		last_error = "The Luau state is not available.";
		return results;
	}

	CharString name = p_function.utf8();
	lua_getfield(state, LUA_GLOBALSINDEX, name.get_data());
	if (!lua_isfunction(state, -1)) {
		lua_settop(state, 0);
		last_error = "`" + p_function + "` is not a function in this Luau state.";
		return results;
	}

	for (int index = 0; index < p_args.size(); index++) {
		_push_variant(p_args[index]);
	}

	if (!_execute(p_args.size(), LUA_MULTRET)) {
		lua_settop(state, 0);
		return results;
	}

	// `pcall` consumed the function and its arguments, so the results are the
	// whole stack.
	int returned = lua_gettop(state);
	results.resize(returned);
	for (int index = 1; index <= returned; index++) {
		results[index - 1] = _read_variant(index);
	}
	lua_settop(state, 0);
	return results;
}

void LuauVMState::set_global(const String &p_name, const Variant &p_value) {
	if (state == nullptr) {
		return;
	}
	// The global table is read-only once sandboxed; the runtime still needs to
	// register services lazily, so lift the flag for the write.
	if (sandboxed) {
		lua_setreadonly(state, LUA_GLOBALSINDEX, 0);
	}
	_push_variant(p_value);
	CharString name = p_name.utf8();
	lua_setfield(state, LUA_GLOBALSINDEX, name.get_data());
	if (sandboxed) {
		lua_setreadonly(state, LUA_GLOBALSINDEX, 1);
	}
}

Variant LuauVMState::get_global(const String &p_name) {
	if (state == nullptr) {
		return Variant();
	}
	CharString name = p_name.utf8();
	lua_getfield(state, LUA_GLOBALSINDEX, name.get_data());
	Variant value = _read_variant(-1);
	lua_pop(state, 1);
	return value;
}

void LuauVMState::sandbox() {
	if (state == nullptr) {
		return;
	}
	luaL_sandbox(state);
	sandboxed = true;
}

bool LuauVMState::is_sandboxed() const {
	return sandboxed;
}

void LuauVMState::set_optimization_level(int p_level) {
	optimization_level = p_level < 0 ? 0 : (p_level > 2 ? 2 : p_level);
}

int LuauVMState::get_optimization_level() const {
	return optimization_level;
}

String LuauVMState::get_last_error() const {
	return last_error;
}

String LuauVMState::get_last_traceback() const {
	return last_traceback;
}

bool LuauVMState::has_error() const {
	return !last_error.is_empty();
}

int64_t LuauVMState::get_memory_used() const {
	if (state == nullptr) {
		return 0;
	}
	int kilobytes = lua_gc(state, LUA_GCCOUNT, 0);
	int remainder = lua_gc(state, LUA_GCCOUNTB, 0);
	return static_cast<int64_t>(kilobytes) * 1024 + remainder;
}

bool LuauVMState::_execute(int p_arg_count, int p_result_count) {
	if (state == nullptr) {
		last_error = "The Luau state is not available.";
		return false;
	}
	if (lua_pcall(state, p_arg_count, p_result_count, 0) != 0) {
		_capture_error_from_stack();
		return false;
	}
	return true;
}

void LuauVMState::_capture_error_from_stack() {
	if (state == nullptr) {
		return;
	}
	const char *message = lua_tolstring(state, -1, nullptr);
	if (message != nullptr) {
		last_error = String::utf8(message);
	} else {
		last_error = "The chunk failed without a message.";
	}
	luaL_traceback(state, state, message, 1);
	const char *traceback = lua_tolstring(state, -1, nullptr);
	last_traceback = traceback != nullptr ? String::utf8(traceback) : String();
	lua_pop(state, 2);
}

void LuauVMState::_push_variant(const Variant &p_value) {
	switch (p_value.get_type()) {
		case Variant::NIL:
			lua_pushnil(state);
			break;
		case Variant::BOOL:
			lua_pushboolean(state, static_cast<bool>(p_value) ? 1 : 0);
			break;
		case Variant::INT:
			lua_pushnumber(state, static_cast<double>(static_cast<int64_t>(p_value)));
			break;
		case Variant::FLOAT:
			lua_pushnumber(state, static_cast<double>(static_cast<double>(p_value)));
			break;
		case Variant::STRING: {
			CharString text = static_cast<String>(p_value).utf8();
			lua_pushlstring(state, text.get_data(), static_cast<size_t>(text.length()));
		} break;
		case Variant::VECTOR3: {
			// Roblox exposes vectors as plain tables, so keep that shape.
			Vector3 vector = p_value;
			lua_createtable(state, 0, 3);
			lua_pushnumber(state, vector.x);
			lua_setfield(state, -2, "x");
			lua_pushnumber(state, vector.y);
			lua_setfield(state, -2, "y");
			lua_pushnumber(state, vector.z);
			lua_setfield(state, -2, "z");
		} break;
		case Variant::ARRAY: {
			Array array = p_value;
			lua_createtable(state, array.size(), 0);
			for (int index = 0; index < array.size(); index++) {
				_push_variant(array[index]);
				lua_rawseti(state, -2, index + 1);
			}
		} break;
		case Variant::DICTIONARY: {
			Dictionary dictionary = p_value;
			Array keys = dictionary.keys();
			lua_createtable(state, 0, keys.size());
			for (int index = 0; index < keys.size(); index++) {
				Variant key = keys[index];
				_push_variant(key);
				_push_variant(dictionary[key]);
				lua_rawset(state, -3);
			}
		} break;
		default:
			// Objects, callables and the other Godot types arrive with the
			// instance bridge; until then they surface as nil rather than
			// leaking engine-specific tables into game code.
			lua_pushnil(state);
			break;
	}
}

int LuauVMState::_absolute_index(lua_State *p_state, int p_index) {
	if (p_index > 0 || p_index <= LUA_REGISTRYINDEX) {
		return p_index;
	}
	return lua_gettop(p_state) + p_index + 1;
}

Variant LuauVMState::_read_variant(int p_index) {
	int index = _absolute_index(state, p_index);
	switch (lua_type(state, index)) {
		case LUA_TNIL:
		case LUA_TNONE:
			return Variant();
		case LUA_TBOOLEAN:
			return Variant(lua_toboolean(state, index) != 0);
		case LUA_TNUMBER:
			return Variant(lua_tonumber(state, index));
		case LUA_TSTRING: {
			size_t length = 0;
			const char *text = lua_tolstring(state, index, &length);
			return Variant(String::utf8(text, static_cast<int>(length)));
		}
		case LUA_TTABLE:
			return _read_table(index);
		default:
			return Variant();
	}
}

Variant LuauVMState::_read_table(int p_index) {
	// Everything below pushes onto the stack, so work from a pinned index:
	// a relative one would point at the iteration key instead of the table.
	const int index = _absolute_index(state, p_index);

	// `lua_next` and `lua_rawgeti` raise an *unprotected* error when they are
	// handed something that is not a table, and an unprotected error inside a
	// GDExtension callback has no handler to unwind to. Check first.
	if (lua_type(state, index) != LUA_TTABLE) {
		return Variant();
	}

	// Arrays are the common case: probe 1..n, and if the table holds nothing
	// else it becomes a Godot Array, otherwise a Dictionary.
	int array_length = 0;
	while (true) {
		lua_rawgeti(state, index, array_length + 1);
		bool is_nil = lua_isnil(state, -1);
		lua_pop(state, 1);
		if (is_nil) {
			break;
		}
		array_length++;
	}

	int entries = 0;
	lua_pushnil(state);
	while (lua_next(state, index) != 0) {
		entries++;
		lua_pop(state, 1);
	}

	if (array_length > 0 && array_length == entries) {
		Array array;
		array.resize(array_length);
		for (int slot = 1; slot <= array_length; slot++) {
			lua_rawgeti(state, index, slot);
			array[slot - 1] = _read_variant(-1);
			lua_pop(state, 1);
		}
		return array;
	}

	Dictionary dictionary;
	lua_pushnil(state);
	while (lua_next(state, index) != 0) {
		Variant key = _read_variant(-2);
		Variant value = _read_variant(-1);
		dictionary[key] = value;
		lua_pop(state, 1);
	}
	return dictionary;
}

void LuauVMState::_bind_methods() {
	ClassDB::bind_method(D_METHOD("reset"), &LuauVMState::reset);
	ClassDB::bind_method(D_METHOD("is_valid"), &LuauVMState::is_valid);

	ClassDB::bind_method(D_METHOD("load", "source", "chunk_name"), &LuauVMState::load, DEFVAL("chunk"));
	ClassDB::bind_method(D_METHOD("run", "source", "chunk_name"), &LuauVMState::run, DEFVAL("chunk"));
	ClassDB::bind_method(D_METHOD("call_global", "function", "args"), &LuauVMState::call_global, DEFVAL(Array()));

	ClassDB::bind_method(D_METHOD("set_global", "name", "value"), &LuauVMState::set_global);
	ClassDB::bind_method(D_METHOD("get_global", "name"), &LuauVMState::get_global);

	ClassDB::bind_method(D_METHOD("sandbox"), &LuauVMState::sandbox);
	ClassDB::bind_method(D_METHOD("is_sandboxed"), &LuauVMState::is_sandboxed);

	ClassDB::bind_method(D_METHOD("set_optimization_level", "level"), &LuauVMState::set_optimization_level);
	ClassDB::bind_method(D_METHOD("get_optimization_level"), &LuauVMState::get_optimization_level);

	ClassDB::bind_method(D_METHOD("get_last_error"), &LuauVMState::get_last_error);
	ClassDB::bind_method(D_METHOD("get_last_traceback"), &LuauVMState::get_last_traceback);
	ClassDB::bind_method(D_METHOD("has_error"), &LuauVMState::has_error);
	ClassDB::bind_method(D_METHOD("get_memory_used"), &LuauVMState::get_memory_used);
}
