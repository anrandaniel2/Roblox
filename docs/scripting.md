# Luau runtime

The scripting layer is what separates "place viewer" from "runs the game", so it
gets its own design document.

## Why a GDExtension

Godot has no scripting VM we can reuse: GDScript is not Lua, and Luau is not
plain Lua. Luau adds type annotations, `continue`, string interpolation,
generalised iteration and integer division, which stock Lua 5.4 rejects. Since
Roblox games ship Luau, we embed **Luau itself** (`luau-lang/luau`, MIT) — the
same VM, the same semantics, the same bytecode.

Luau is C++ and cannot be loaded into GDScript, so we build a GDExtension
(`extensions/luau_vm`) that compiles Luau's `Common`, `Ast`, `Compiler` and `VM`
sources straight into the library and registers a `LuauVMState` class with
Godot. There is no dependency on a third-party prebuilt binary: the extension is
built in CI against `godot-cpp` **10.0.0-stable**, which explicitly supports
`api_version=4.7`, so the produced binaries target our engine version.

## Why not a `ScriptLanguage`

Registering Luau as a Godot `ScriptLanguage` (as some addons do) makes Lua files
attachable to `Node`s. Roblox does not work that way: scripts are `Instance`s in
the data model, they run immediately when their context loads, and they talk to
services rather than their parent node. Modelling that on top of `Node`
attachments fights both engines. Instead:

- `LuauVMState` is a plain `RefCounted` wrapper around one `lua_State`.
- A runtime module (P3) owns the states, decides which script runs where, and
  registers the Roblox API as globals before sandboxing.

## VM host — `LuauVMState`

| Method | Purpose |
| --- | --- |
| `run(source, chunk_name)` | compile + execute a chunk, discard results |
| `load(source, chunk_name)` | compile + push a chunk, keep it for `call_loaded` |
| `call_global(name, args)` | call a global function with Variant arguments, return its results |
| `set_global(name, value)` / `get_global(name)` | inject and read API globals; works while sandboxed |
| `sandbox()` | `luaL_sandbox`: read-only globals, protected main thread |
| `is_sandboxed()`, `set_optimization_level()`, `get_memory_used()` | telemetry and tuning |
| `get_last_error()`, `get_last_traceback()`, `has_error()` | error reporting from `pcall` and `luau_load` |

Variant ↔ Lua conversion covers nil, bool, int, float, string, `Vector3` (as a
table, matching Roblox semantics), `Array` (1-based) and `Dictionary`. Objects,
Instance userdata and callables land with the API bridge.

Compilation uses the C entry points (`luau_compile`, `luau_load`) so errors come
back as values instead of exceptions: a syntax error in a game script must never
take the emulator down, it must land in the console with a traceback.

Sandboxing is explicit and must be called *after* the API globals are injected —
that mirrors Roblox, which sets up the environment and then freezes it.
`set_global` briefly lifts the read-only flag so late-bound globals still work.

## Still to build (P3)

1. **Contexts.** Server state (authoritative) plus one client state per player,
   matching `Script` / `LocalScript` / `ModuleScript` and `RunContext`.
2. **Scheduler.** `task.wait`/`spawn`/`defer`/`delay`, `RunService.Heartbeat` /
   `Stepped` / `RenderStepped`, thread resumption on the main thread, and a
   per-frame instruction budget so a runaway script cannot freeze the app.
3. **API surface.** Generated from the public Roblox API dump into a table
   (classes, members, enums, tags), then bound to native implementations. The
   generator belongs next to `tools/gen_data.py` and its output is committed as
   gzipped JSON, like the reflection tables.
4. **Instance bridging.** Luau sees Roblox `Instance`s (`.Name`, `.Parent`,
   index/newindex, `:FindFirstChild`, `:GetChildren`, signals); Godot owns the
   scene. The bridge keeps the two in sync and hides the Godot side entirely.
5. **Bytecode cache.** Compile once, store bytecode in `user://cache`, revalidate
   on source hash — mobile start-up cost is dominated by parsing.
