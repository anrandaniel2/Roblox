#!/usr/bin/env python3
"""Builds the native API index that `tools/check_native_api.py` checks against.

The index is a trimmed copy of Godot's own `extension_api.json`: for every
engine class it keeps the class it inherits from plus the *complete* set of
member names that class exposes (its own members and every inherited one), so a
call like `Compression.decompress(...)` can be answered with a plain lookup.

    tools/gen_native_api.py --api extensions/luau_vm/extern/godot-cpp/gdextension/extension_api-4-7.json

The godot-cpp tarball that `tools/fetch_deps.py` downloads carries one of these
JSON files per supported engine version, which makes it the handiest source of
truth available without a Godot binary.  The result lands in
`data/native_api.json.gz` and is checked in, because CI needs it before Godot is
installed.
"""

from __future__ import annotations

import argparse
import gzip
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "data" / "native_api.json.gz"


def member_names(entry: dict) -> list[str]:
    """Every name a class or builtin type exposes as a member.

    Builtins carry methods, constants and enums, and may also have plain fields
    (`Vector3.x`); classes carry methods, properties, signals and constants.
    """
    names: set[str] = set()
    for key in ("methods", "properties", "signals", "constants"):
        for item in entry.get(key, []) or []:
            names.add(item["name"])
    for enum in entry.get("enums", []) or []:
        names.add(enum["name"])
        for value in enum.get("values", []) or []:
            names.add(value["name"])
    # Builtins store their fields as {"name": ..., "type": ...}.
    for item in entry.get("members", []) or []:
        names.add(item["name"])
    return sorted(names)


def build(api: dict) -> dict:
    classes = {entry["name"]: entry for entry in api["classes"]}
    resolved: dict[str, list[str]] = {}
    for name, entry in classes.items():
        names: set[str] = set()
        cursor = name
        seen: set[str] = set()
        while cursor and cursor not in seen and cursor in classes:
            seen.add(cursor)
            names.update(member_names(classes[cursor]))
            cursor = classes[cursor].get("inherits", "")
        resolved[name] = sorted(names)

    builtins = {entry["name"]: member_names(entry) for entry in api["builtin_classes"]}
    header = api["header"]
    return {
        "engine": f'{header["version_major"]}.{header["version_minor"]}.{header["version_patch"]}',
        "classes": resolved,
        "builtins": builtins,
        "global_enums": sorted(enum["name"] for enum in api.get("global_enums", []) or []),
        "global_enum_values": sorted(
            value["name"]
            for enum in api.get("global_enums", []) or []
            for value in enum.get("values", []) or []
        ),
        "singletons": sorted({entry["name"] for entry in api.get("singletons", []) or []}),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api", required=True, help="path to Godot's extension_api.json")
    parser.add_argument("--output", default=str(OUTPUT))
    args = parser.parse_args()

    api_path = pathlib.Path(args.api)
    if not api_path.exists():
        print(f"error: {api_path} not found (tools/fetch_deps.py downloads godot-cpp)", file=sys.stderr)
        return 2
    api = json.loads(api_path.read_text())

    index = build(api)
    raw = json.dumps(index, separators=(",", ":"), sort_keys=True).encode()
    out_path = pathlib.Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(out_path, "wb", compresslevel=9) as handle:
        handle.write(raw)
    print(
        f"wrote {out_path.relative_to(ROOT)}: Godot {index['engine']}, "
        f"{len(index['classes'])} classes, {len(index['builtins'])} builtins, "
        f"{len(raw)} bytes ({out_path.stat().st_size} gzipped)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
