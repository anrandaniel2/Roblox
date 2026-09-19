# luau_vm — Luau for Godot 4.7.2

A GDExtension that compiles the official Luau VM into Godot and exposes it as
`LuauVMState`. This is the scripting foundation for running Roblox game code; see
`docs/scripting.md` for the design and the phases that build on it.

## Layout

```
extensions/luau_vm/
├── SConstruct          # builds Luau's sources + src/ into bin/libluau_vm*.so
├── luau_vm.gdextension # what Godot loads
├── src/
│   ├── register_types.*   # GDExtension entry point
│   └── luau_vm_state.*    # the VM host class exposed to GDScript
└── extern/             # fetched dependencies (git-ignored)
    ├── godot-cpp/      # 10.0.0-stable, supports api_version=4.7
    └── luau/           # 0.739
```

## Building

```sh
pip install "scons>=4.6"
python3 tools/fetch_deps.py
cd extensions/luau_vm
scons -j"$(nproc)" platform=linux arch=x86_64 target=template_release api_version=4.7
```

Produces `bin/libluau_vm.linux.template_release.x86_64.so`, which
`luau_vm.gdextension` already points at. Android:

```sh
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_ROOT=$ANDROID_HOME/ndk/27.0.12077973
scons -j"$(nproc)" platform=android arch=arm64 target=template_release api_version=4.7
```

`api_version=4.7` is not optional: it selects which extension API JSON godot-cpp
generates bindings from, and we target Godot 4.7.2.

## Verifying

```sh
godot --headless --path ../.. --script res://tests/luau_smoke.gd
```

The smoke test checks that the class registers, that Luau-specific syntax
(type annotations, `continue`, backtick interpolation, compound assignment)
compiles and runs, that Variant values round-trip, that errors produce a
message and a traceback instead of a crash, and that `sandbox()` freezes the
globals. CI runs the same test on every push
(`.github/workflows/luau-extension.yml`).

## Not done yet

- Instance/userdata bridging, callables and signals (`LuauVMState` only carries
  value types today).
- Coroutines and the `task` scheduler — `run()` executes a chunk to completion.
- Threads (`lua_newthread`) and per-player contexts.
- A bytecode cache.
