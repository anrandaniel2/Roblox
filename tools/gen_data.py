#!/usr/bin/env python3
"""Generates the Roblox reflection database used by the emulator.

Inputs (either an rbx-dom source checkout, or pre-supplied files):
  * <rbx-dom>/rbx_reflection_database/database.msgpack
  * <rbx-dom>/rbx_types/src/brick_color.rs

Outputs (written to data/, gzip compressed):
  * reflection.json.gz   class hierarchy, properties (canonical <-> serialized
                         names, data types) and per class default values
  * enums.json.gz        Enum items and numeric values
  * brickcolors.json.gz  legacy BrickColor palette (number -> name, rgb)

Usage:
  python3 tools/gen_data.py --rbx-dom /path/to/rbx-dom

The generated data is derived from rbx-dom (MIT licensed) which in turn is
generated from Roblox's public API dump.  See NOTICE.md.
"""
from __future__ import annotations

import argparse
import gzip
import json
import msgpack
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "data")

# Properties we never need to carry around, they are pure engine bookkeeping.
SKIP_PROPS = {
    "AttributesSerialize",
    "Tags",
    "HistoryId",
    "UniqueId",
    "SourceAssetId",
    "DefinesCapabilities",
    "Capabilities",
    "Sandboxed",
    "SecurityCapabilities",
    "CoreGuiType",
    "MaxPlayersInternal",
    "PlaybackRegion",
}

# Hard cap on default-value nesting when serialising to keep the payload small.
MAX_DEFAULT_DEPTH = 6


def load_db(path: str):
    with open(path, "rb") as handle:
        return msgpack.unpackb(handle.read(), raw=False, strict_map_key=False)


def split_classes(raw):
    classes = {}
    enums = {}
    for section in raw:
        if not isinstance(section, dict):
            continue
        if "Part" in section and isinstance(section["Part"], list):
            classes = section
        elif "Material" in section:
            for enum_name, enum_entry in section.items():
                # Stored as [name, {item: value}]
                if isinstance(enum_entry, list) and len(enum_entry) == 2 and isinstance(enum_entry[1], dict):
                    enums[enum_name] = enum_entry[1]
                elif isinstance(enum_entry, dict):
                    enums[enum_name] = enum_entry
    return classes, enums


def prop_datatype(entry) -> str:
    """entry[2] is the data type descriptor produced by rbx-dom."""
    if len(entry) < 3:
        return "Unknown"
    desc = entry[2]
    if isinstance(desc, str):
        return desc
    if isinstance(desc, dict):
        if "Value" in desc:
            return str(desc["Value"])
        if "Enum" in desc:
            return "Enum." + str(desc["Enum"])
        if "EnumRef" in desc:
            return "Enum." + str(desc["EnumRef"])
    return "Unknown"


def prop_serialized_name(name: str, entry) -> str:
    """Where does rbx-dom write this property in a file?"""
    if len(entry) < 5 or not isinstance(entry[4], dict):
        return name
    meta = entry[4]
    if "Canonical" in meta:
        canon = meta["Canonical"]
        if canon == "Serializes" or canon == ["Serializes"]:
            return name
        if isinstance(canon, list):
            for item in canon:
                if isinstance(item, dict) and "SerializesAs" in item:
                    return str(item["SerializesAs"])
                if isinstance(item, dict) and "Migrate" in item:
                    # Migrated properties are written under their own name.
                    return name
    return name


def prop_kind(entry) -> str:
    if len(entry) < 5 or not isinstance(entry[4], dict):
        return "canonical"
    meta = entry[4]
    if "Canonical" in meta:
        return "canonical"
    if "Alias" in meta:
        return "alias"
    return "canonical"


def clamp(value, depth=0):
    if depth > MAX_DEFAULT_DEPTH:
        return None
    if isinstance(value, float):
        # Defaults do not need double precision.
        return round(value, 5)
    if isinstance(value, (bool, int, str)) or value is None:
        return value
    if isinstance(value, (list, tuple)):
        return [clamp(item, depth + 1) for item in value]
    if isinstance(value, dict):
        return {str(key): clamp(item, depth + 1) for key, item in value.items()}
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


def build_classes(classes):
    out = {}
    for name, entry in classes.items():
        superclass = entry[2] if len(entry) > 2 and isinstance(entry[2], str) else ""
        props = entry[3] if len(entry) > 3 else {}
        defaults = entry[4] if len(entry) > 4 else {}
        out_props = {}
        for prop_name, prop_entry in props.items():
            if prop_name in SKIP_PROPS:
                continue
            kind = prop_kind(prop_entry)
            serialized = prop_serialized_name(prop_name, prop_entry)
            datatype = prop_datatype(prop_entry)
            if kind == "alias":
                # Stored as: canonical name of the property this is an alias of.
                out_props[prop_name] = ["~", datatype, serialized, prop_entry_alias(prop_entry)]
            else:
                out_props[prop_name] = [serialized, datatype, kind]
        out_defaults = {}
        for prop_name, value in defaults.items():
            if prop_name in SKIP_PROPS:
                continue
            out_defaults[prop_name] = clamp(value)
        out[name] = {
            "super": superclass,
            "props": out_props,
            "defaults": out_defaults,
        }
    return out


def prop_entry_alias(entry):
    try:
        return str(entry[4]["Alias"][0])
    except Exception:
        return ""


def build_enums(enums):
    out = {}
    for name, items in enums.items():
        if not isinstance(items, dict):
            continue
        out[name] = {str(item): int(value) for item, value in items.items() if isinstance(value, int)}
    return out


BRICK_RE = re.compile(
    r"\[\s*(\w+)\s*,\s*\"([^\"]+)\"\s*,\s*(\d+)\s*,\s*\((\d+)\s*,\s*(\d+)\s*,\s*(\d+)\)\s*\]"
)


def build_brickcolors(path):
    with open(path, "r", encoding="utf-8") as handle:
        src = handle.read()
    out = {}
    for match in BRICK_RE.finditer(src):
        _, name, number, red, green, blue = match.groups()
        out[number] = [name, int(red), int(green), int(blue)]
    return out


def json_safe(value):
    """Replaces non-finite floats so the JSON stays readable.

    Godot's JSON parser rejects `Infinity`/`NaN` (Python happily writes both),
    and a single one of them made the whole reflection database unreadable.
    Roblox uses infinities for things like unbounded `NumberRange`s, where
    `null` is at least an honest "no value".
    """
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")):
            return None
        return value
    if isinstance(value, dict):
        return {key: json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    return value


def write_gz(path: str, payload) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    raw = json.dumps(json_safe(payload), separators=(",", ":"), sort_keys=True).encode("utf-8")
    with gzip.GzipFile(filename="", mode="wb", fileobj=open(path, "wb"), compresslevel=9, mtime=0) as handle:
        handle.write(raw)
    print(
        "wrote %-28s %8.1f KiB raw -> %7.1f KiB gz  (%d entries)"
        % (
            os.path.relpath(path, ROOT),
            len(raw) / 1024.0,
            os.path.getsize(path) / 1024.0,
            len(payload) if isinstance(payload, dict) else 0,
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rbx-dom", default=os.environ.get("RBX_DOM", "/tmp/ref/rbx-dom"))
    parser.add_argument("--keep-json", action="store_true", help="also write uncompressed json for inspection")
    args = parser.parse_args()

    db_path = os.path.join(args.rbx_dom, "rbx_reflection_database", "database.msgpack")
    brick_path = os.path.join(args.rbx_dom, "rbx_types", "src", "brick_color.rs")
    if not os.path.exists(db_path):
        print("error: %s not found" % db_path, file=sys.stderr)
        return 1

    classes, enums = split_classes(load_db(db_path))
    class_data = build_classes(classes)
    enum_data = build_enums(enums)
    brick_data = build_brickcolors(brick_path) if os.path.exists(brick_path) else {}

    reflection = {"version": 1, "classes": class_data}
    write_gz(os.path.join(OUT_DIR, "reflection.json.gz"), reflection)
    write_gz(os.path.join(OUT_DIR, "enums.json.gz"), enum_data)
    write_gz(os.path.join(OUT_DIR, "brickcolors.json.gz"), brick_data)

    if args.keep_json:
        write_gz(os.path.join(OUT_DIR, "reflection.json"), reflection) if False else None
        with open(os.path.join(OUT_DIR, "reflection.json"), "w") as handle:
            json.dump(reflection, handle, indent=1, sort_keys=True)

    print("classes: %d  enums: %d  brickcolors: %d" % (len(class_data), len(enum_data), len(brick_data)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
