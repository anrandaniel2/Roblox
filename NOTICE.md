# Third party notices

Rbx Engine is an independent, clean-room implementation.  It does not contain
code from Roblox Corporation and is not affiliated with or endorsed by Roblox
Corporation.  "Roblox", "Roblox Studio", "RBXL" and "Luau" are trademarks of
Roblox Corporation; they are used here only to describe file formats and
behaviour for interoperability.

The following open source projects were used as reference material, test data
or in the build pipeline:

| Project | License | What we use |
| --- | --- | --- |
| [rbx-dom](https://github.com/rojo-rbx/rbx-dom) (rojo-rbx) | MIT | Format documentation (`docs/binary.md`, `docs/xml.md`), the reflection database and legacy BrickColor palette that are converted into `data/*.gz` by `tools/gen_data.py`, and the sample `.rbxm` files in `fixtures/`. |
| [Roblox-File-Format](https://github.com/MaximumADHD/Roblox-File-Format) (MaximumADHD) | MIT | Cross-checking of binary chunk and property encodings. |
| [rblx-godot](https://github.com/rblx-godot/rblx-godot) (radiantgurl) | Apache-2.0 | Prior art: the idea of embedding a Luau VM plus a Roblox `Instance` model into a Godot node. Our implementation is GDScript only and shares no code. |
| [godot_luaAPI](https://github.com/WeaselGames/godot_luaAPI) (WeaselGames, archived) | MIT | Prior art for Godot/Luau interop. |
| [Uniblox](https://github.com/EmK530/Uniblox) (EmK530) | MIT | Prior art for `.rbxl` importers in a Godot-era engine. |
| [Luau](https://github.com/luau-lang/luau) (Roblox Corporation / luau-lang) | MIT | The scripting VM compiled into `extensions/luau_vm` by `tools/fetch_deps.py`; game code will run on this VM rather than stock Lua. |
| [godot-cpp](https://github.com/godotengine/godot-cpp) | MIT | C++ bindings used to build the `luau_vm` GDExtension for Godot 4.7. |
| [Luau-Godot](https://github.com/v3nn7/Luau-Godot) (v3nn7) | MIT | Reference for compiling Luau's sources into a GDExtension with SCons. No code is copied. |
| [Godot Engine](https://godotengine.org) | MIT | The engine the emulator is built on. |

Data files generated from rbx-dom (`data/reflection.json.gz`, `data/enums.json.gz`,
`data/brickcolors.json.gz`) are derived from publicly published Roblox API
metadata and are redistributed under the same MIT terms as rbx-dom.
