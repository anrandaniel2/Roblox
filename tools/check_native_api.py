#!/usr/bin/env python3
"""Catches GDScript that calls engine API this Godot version does not have.

    tools/check_native_api.py src tests

Godot only reports a bad engine call when it compiles the script — which, in
this project, happens on the CI runner, minutes after the mistake.  Godot 4.7
went and deleted a class the parsers used (`Compression`), which is exactly the
kind of drift a static check can catch in a second: the index written by
`tools/gen_native_api.py` knows every class, builtin type and member name in
4.7, so `Compression.decompress(...)` is answerable without running anything.

The check is deliberately conservative — it only looks at `Name.member` where
`Name` resolves to nothing the file declares itself, and it never looks inside
strings, comments or `.`-chained sub-expressions.  Anything it cannot resolve is
reported.  Lines it should stop reporting can be listed in
`tools/native_api_allow.txt` as `Name` or `Name.member`.
"""

from __future__ import annotations

import argparse
import gzip
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
INDEX = ROOT / "data" / "native_api.json.gz"
ALLOWLIST = ROOT / "tools" / "native_api_allow.txt"

# `Name.member`, not preceded by a dot (a chain) or a word character (an
# identifier), not followed by `(` immediately after the name (a call is the
# same thing to us, but the capture stays on the member).
REFERENCE = re.compile(r"(?<![\w.$])(?P<base>[A-Z][A-Za-z0-9_]*)\.(?P<member>[A-Za-z_][A-Za-z0-9_]*)")
# Anything declared on a line: a local, a parameter, a loop variable, a closure.
LOCAL_DECL = re.compile(
    r"\b(?:var|const|func|class_name|class|enum|signal)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
# Anything declared at file scope: constants (`PART_CLASSES`), enums (`Level`),
# inner classes and so on.  Project style keeps those flush left, and function
# bodies indented, which is what tells the two apart.
FILE_SCOPE = re.compile(
    r"^(?:static\s+|@[^\n]*\n\s*)*(?:class_name|class|enum|const|var|signal|func)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)
CLASS_NAME = re.compile(r"^\s*class_name\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)
AUTOLOAD_SECTION = re.compile(r"^\[autoload\]\s*$", re.MULTILINE)

STRING_NOTE = "engine class is missing from this Godot version"
MEMBER_NOTE = "engine member is missing from this Godot version"


def code_lines(text: str) -> list[tuple[int, str]]:
    """Strips comments and string literals, keeping the line numbering.

    A Roblox prelude written as a multi-line Luau string is a large part of some
    of these files, and it contains code (`Instance.new`, `Vector3.__index`) that
    would otherwise look like engine calls that do not exist.  Strings are
    therefore tracked across lines rather than line by line.
    """
    lines: list[tuple[int, str]] = []
    buffer: list[str] = []
    quote = ""
    triple = False
    number = 1
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if char == "\n":
            lines.append((number, "".join(buffer)))
            buffer = []
            number += 1
            index += 1
            continue
        if triple:
            if text.startswith(quote * 3, index):
                triple = False
                quote = ""
                index += 3
                continue
            index += 1
            continue
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = ""
            index += 1
            continue
        if char == "#":
            while index < length and text[index] != "\n":
                index += 1
            continue
        if char in "\"'":
            if text.startswith(char * 3, index):
                triple = True
                quote = char
                index += 3
                continue
            quote = char
            index += 1
            continue
        buffer.append(char)
        index += 1
    lines.append((number, "".join(buffer)))
    return lines


def load_index() -> dict:
    if not INDEX.exists():
        print(f"error: {INDEX} not found; run tools/gen_native_api.py", file=sys.stderr)
        raise SystemExit(2)
    with gzip.open(INDEX, "rb") as handle:
        return json.loads(handle.read())


def load_allowlist() -> tuple[set[str], set[str]]:
    """Returns the allowed bare names and `Name.member` pairs."""
    names: set[str] = set()
    pairs: set[str] = set()
    if not ALLOWLIST.exists():
        return names, pairs
    for line in ALLOWLIST.read_text().splitlines():
        entry = line.split("#", 1)[0].strip()
        if not entry:
            continue
        if "." in entry:
            pairs.add(entry)
        else:
            names.add(entry)
    return names, pairs


def project_globals(api_names: set[str]) -> set[str]:
    """Class names, autoloads and inner classes the project itself defines."""
    names: set[str] = {"Enum"}
    for script in ROOT.rglob("*.gd"):
        if ".godot" in script.parts:
            continue
        match = CLASS_NAME.search(script.read_text(errors="replace"))
        if match:
            names.add(match.group(1))
    settings = (ROOT / "project.godot").read_text(errors="replace").splitlines()
    in_autoload = False
    for line in settings:
        if line.startswith("["):
            in_autoload = line.strip().lower() == "[autoload]"
            continue
        if in_autoload and "=" in line:
            names.add(line.split("=", 1)[0].strip().lstrip("*"))
    # `RBXValues.BrickColorUtil` is an inner class of a project class, so its
    # name is reached through a base we already allow.
    for script in ROOT.rglob("*.gd"):
        if ".godot" in script.parts:
            continue
        for match in re.finditer(r"^class\s+([A-Za-z_][A-Za-z0-9_]*)", script.read_text(errors="replace"), re.MULTILINE):
            names.add(match.group(1))
    # `Enum.Value` is a project convention for the reflection tables.
    for script in ROOT.rglob("*.gd"):
        if ".godot" in script.parts:
            continue
        for match in re.finditer(r'"(Enum\.[A-Za-z0-9_]+)"', script.read_text(errors="replace")):
            names.add(match.group(1))
    return names


def check_file(path: pathlib.Path, index: dict, allowed_names: set[str], allowed_pairs: set[str], known: set[str]) -> list[str]:
    classes = index["classes"]
    builtins = index["builtins"]
    global_enums = set(index["global_enums"])
    global_values = set(index["global_enum_values"])
    problems: list[str] = []

    text = path.read_text(errors="replace")
    stripped = code_lines(text)
    declared = {match.group(1) for match in FILE_SCOPE.finditer("\n".join(code for _, code in stripped))}

    for number, line in stripped:
        if "." not in line:
            continue
        locals_here = {match.group(1) for match in LOCAL_DECL.finditer(line)}
        for match in REFERENCE.finditer(line):
            base, member = match.group("base"), match.group("member")
            if base in locals_here or base in declared or base in known or base in allowed_names:
                continue
            if f"{base}.{member}" in allowed_pairs or base in allowed_pairs:
                continue
            if base in global_enums or base in global_values:
                continue
            is_class = True
            members = classes.get(base)
            if members is None:
                is_class = False
                members = builtins.get(base)
            if members is None:
                problems.append(
                    f"{path.relative_to(ROOT)}:{number}: '{base}.{member}' — unknown engine class ({STRING_NOTE})"
                )
                continue
            if member in members or (is_class and member == "new"):
                continue
            problems.append(f"{path.relative_to(ROOT)}:{number}: '{base}.{member}' — {MEMBER_NOTE}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", default=["src", "tests"], help="files or directories to check")
    args = parser.parse_args()

    index = load_index()
    allowed_names, allowed_pairs = load_allowlist()
    known = project_globals(set(index["classes"]) | set(index["builtins"]))

    targets: list[pathlib.Path] = []
    for entry in args.paths or ["src", "tests"]:
        target = (ROOT / entry).resolve()
        if target.is_dir():
            targets.extend(sorted(target.rglob("*.gd")))
        elif target.suffix == ".gd":
            targets.append(target)

    problems: list[str] = []
    for target in targets:
        problems.extend(check_file(target, index, allowed_names, allowed_pairs, known))

    engine = index.get("engine", "?")
    if problems:
        print(f"checked {len(targets)} scripts against Godot {engine}: {len(problems)} problem(s)")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print(f"checked {len(targets)} scripts against Godot {engine}: no unknown engine API")
    return 0


if __name__ == "__main__":
    sys.exit(main())
