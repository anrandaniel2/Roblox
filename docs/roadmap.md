# Roadmap

Goal: open a Roblox `.rbxl` place in Godot 4.7.2 and get as close to the real
game as we can — on desktop and on mobile — without pretending the hard parts
are easy.

## What "supporting a game" actually means

| Layer | Examples | Status |
| --- | --- | --- |
| Container parsing | binary `.rbxl`/`.rbxm`, XML `.rbxlx`/`.rbxmx`, LZ4/zstd chunks | reference reader validated; GDScript port written, unverified |
| Scene reconstruction | parts, CFrames, models, folders, joins, values, attributes, tags | not started |
| Look and feel | colours, materials, surfaces, lighting, skybox, fog | not started |
| Assets | `rbxassetid://` meshes, textures, sounds, animations | needs a local asset cache; CDN access is unreliable and ToS-bound |
| Interface | `ScreenGui` + `Frame`/`TextLabel`/`ImageLabel`/layouts | not started |
| Character | Humanoid rig, R6/R15, animations, camera modes | not started |
| Scripting | Luau VM + Roblox API surface + scheduler | extension scaffold (this milestone) |
| Non-visual services | DataStore, HttpService, Marketplace, networking | emulated locally at best; never truly compatible |

Terrain (voxel chunks), CSG (`UnionOperation` blobs), skinned meshes and
Roblox's UI constraint solver are each a project of their own and are tracked
separately below.

## Phases

**P0 — make it run (current).** Validate the GDScript readers with static
analysis, build the missing bootstrap (`src/app/main.gd`, `main.tscn`,
`rbx_app.gd`, `web_bridge.gd`, default environment), and prove in CI that Godot
4.7.2 opens the project headlessly and imports `fixtures/parts-1000.rbxm` with a
JSON output identical to `tools/rbxl_dump.py`.

**P1 — importer.** `RBXPlace` → Godot scene: instance tree, parts with correct
CFrame/size/colour/material, `Part` shapes, spawn locations, joins, `Model` and
`Folder` grouping, collision layers from `CanCollide`/`CanTouch`/`CanQuery`,
`RbxSettings` caps so a 60k-instance place still opens on a phone (spread across
frames, low-detail fallback).

**P2 — runtime services.** `game`, `workspace`, `Players`, `RunService`,
`Debris`, `TweenService`, `CollectionService`, tags/attributes, the character
controller, camera, and the Roblox-ish event model (`Changed`, `ChildAdded`,
`:Connect`, `:Wait`, `task.*`).

**P3 — Luau.** Embed Luau (this milestone provides the build), then: one state
per script context (server / per client), `Script`/`LocalScript`/`ModuleScript`
loading with `require`, the API bridge generated from the public API dump, a
`task` scheduler with `Heartbeat`/`Stepped`/`wait`, sandboxing, and bytecode
caching. See `docs/scripting.md`.

**P4 — fidelity.** Terrain, CSG unions, MeshParts with a downloadable asset
cache, particle emitters, `UIGridLayout`/`UIListLayout`/constraints, tweening
parity, animations.

**P5 — mobile.** Touch controls (virtual thumbstick, jump/sprint buttons,
camera drag), safe-area aware UI, quality presets, Android export in CI, and a
device-appropriate import budget.

## Where Godot runs

There is no Godot binary in the development sandbox and the release hosts are
not reachable from it. Everything that needs the engine runs **in GitHub
Actions** (`ubuntu-latest`, Godot 4.7.2 downloaded from the official release,
`--headless`). CI is therefore the test harness: it must stay green and it must
own the import diff against the Python oracle.

## Rules we hold ourselves to

- Never claim compatibility we have not measured. "Imports and renders" is the
  claim; "runs your game" is earned script by script, class by class.
- Roblox data we cannot faithfully reproduce is surfaced in `RBXPlace.warnings`
  and in the UI, not silently dropped.
- Anything that only works because of a hack is listed in the docs with the
  reason.
