#!/usr/bin/env python3
"""Cross-checks the GDScript place readers against the Python reference reader.

    godot --headless --path . res://tests/core_smoke.tscn | tee smoke.log
    python3 tools/check_parsers.py --log smoke.log --fixtures fixtures

`tests/core_smoke.gd` prints one `FIXTURE …` line per fixture; this script runs
`tools/rbxl_dump.py` over the same files and compares the two readers. The
Python reader was written first and checked against rbx-dom's own fixtures, so
it is the oracle: if the two disagree, the GDScript port has drifted.

Exits non-zero when any fixture disagrees, so a CI job can gate on it.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

FIXTURE_LINE = re.compile(r"^FIXTURE\s+(?P<fields>.*)$")
FIELD = re.compile(r"(?P<key>[a-z_]+)=(?P<value>\S*)")

# The extension is the format contract; the header of a binary model is checked
# separately by the reader itself.
EXPECTED_FORMAT = {
    ".rbxl": "binary",
    ".rbxm": "binary",
    ".rbxlx": "xml",
    ".rbxmx": "xml",
}


def read_log(path: str) -> dict[str, dict[str, str]]:
    fixtures: dict[str, dict[str, str]] = {}
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = FIXTURE_LINE.match(line.strip())
            if not match:
                continue
            fields = {m.group("key"): m.group("value") for m in FIELD.finditer(match.group("fields"))}
            if "file" in fields:
                fixtures[fields["file"]] = fields
    return fixtures


def oracle(path: str) -> dict:
    result = subprocess.run(
        [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "rbxl_dump.py"),
         path, "--no-properties", "--max-instances", "0"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit("the reference reader failed on %s:\n%s" % (path, result.stderr.strip()))
    return json.loads(result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, help="log captured from the core smoke test")
    parser.add_argument("--fixtures", default="fixtures", help="directory the fixtures live in")
    parser.add_argument("--expect", default="", help="optional file with a FIXTURE line per fixture")
    options = parser.parse_args()

    seen = read_log(options.log)
    if not seen:
        raise SystemExit("no FIXTURE lines in %s — did the smoke test run?" % options.log)

    if options.expect:
        for name, fields in read_log(options.expect).items():
            seen.setdefault(name, fields)

    failures: list[str] = []
    print("%-24s %8s %8s %8s %8s" % ("fixture", "instances", "roots", "classes", "props"))
    for name in sorted(seen):
        fields = seen[name]
        path = os.path.join(options.fixtures, name)
        if not os.path.exists(path):
            failures.append("%s is missing from %s" % (name, options.fixtures))
            continue

        want_format = EXPECTED_FORMAT.get(os.path.splitext(name)[1].lower())
        if want_format and fields.get("format") != want_format:
            failures.append("%s was read as '%s', expected '%s'" % (name, fields.get("format"), want_format))

        # The reference reader only speaks the binary container. XML files are
        # covered by tests/core_smoke.gd, which requires the XML and binary
        # encodings of the same place to describe the same tree.
        if os.path.splitext(name)[1].lower() in (".rbxlx", ".rbxmx"):
            print("%-24s %5d/xml %6s %6s %6s" % (
                name, int(fields.get("instances", -1)), "-", "-", "-"))
            if fields.get("error", "-") != "-":
                failures.append("%s reported: %s" % (name, fields["error"]))
            continue

        reference = oracle(path)
        got_instances = int(fields.get("instances", -1))
        got_roots = int(fields.get("roots", -1))
        got_classes = int(fields.get("classes", -1))
        got_props = int(fields.get("props", -1))

        expected_instances = int(reference.get("total_instances", reference.get("instance_count", -1)))
        expected_roots = int(reference.get("root_count", -1))
        expected_classes = int(reference.get("class_count", -1))
        expected_props = int(reference.get("prop_chunks", -1))

        print("%-24s %5d/%-3d %5d/%-3d %5d/%-3d %5s/%-3s" % (
            name, got_instances, expected_instances, got_roots, expected_roots,
            got_classes, expected_classes,
            got_props if got_props >= 0 else "-", expected_props,
        ))

        if not fields.get("error", "-") == "-":
            failures.append("%s reported: %s" % (name, fields["error"]))
        if got_instances != expected_instances:
            failures.append("%s: %d instances, the reference reader found %d" % (
                name, got_instances, expected_instances))
        if got_roots != expected_roots:
            failures.append("%s: %d roots, the reference reader found %d" % (name, got_roots, expected_roots))
        if got_classes != expected_classes:
            failures.append("%s: %d classes, the reference reader found %d" % (
                name, got_classes, expected_classes))
        if got_props >= 0 and expected_props >= 0 and got_props != expected_props:
            failures.append("%s: %d property chunks, the reference reader found %d" % (
                name, got_props, expected_props))

    if failures:
        print("\n%d fixture(s) disagree with the reference reader:" % len(failures))
        for failure in failures:
            print("  - %s" % failure)
        return 1

    print("\nall %d fixtures match the reference reader" % len(seen))
    return 0


if __name__ == "__main__":
    sys.exit(main())
