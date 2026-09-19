#!/usr/bin/env python3
"""Fetches the two dependencies needed to build the Luau GDExtension.

    python3 tools/fetch_deps.py                 # fetch both
    python3 tools/fetch_deps.py --force         # re-fetch even if present
    python3 tools/fetch_deps.py --luau 0.739    # pin a different Luau release

They are downloaded from `codeload.github.com` (which works both in the CI
runner and in the development sandbox) and unpacked into
`extensions/luau_vm/extern/`.  The directory is ignored by git: sources are
reproducible from the pinned versions below.
"""
from __future__ import annotations

import argparse
import os
import shutil
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTERN = os.path.join(ROOT, "extensions", "luau_vm", "extern")

# `godot-cpp` 10.0.0-stable is the first release whose `api_version` option
# accepts "4.7", which is the engine version this project targets.
GODOT_CPP_VERSION = "10.0.0-stable"
LUAU_VERSION = "0.739"

TARBALL = "https://codeload.github.com/{repo}/tar.gz/refs/tags/{version}"


def _fetch(repo: str, version: str, destination: str, force: bool) -> None:
    if os.path.isdir(destination) and not force:
        print("already present: %s (%s)" % (os.path.relpath(destination, ROOT), version))
        return

    url = TARBALL.format(repo=repo, version=version)
    print("fetching %s @ %s" % (repo, version))
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "source.tar.gz")
        try:
            urllib.request.urlretrieve(url, archive)
        except urllib.error.URLError as error:
            raise SystemExit("could not download %s: %s" % (url, error))

        with tarfile.open(archive, "r:gz") as tar:
            members = tar.getnames()
            if not members:
                raise SystemExit("%s produced an empty archive" % url)
            prefix = members[0].split("/")[0] + "/"
            tar.extractall(tmp)
            extracted = os.path.join(tmp, prefix)
            if os.path.isdir(destination):
                shutil.rmtree(destination)
            shutil.move(extracted, destination)
    print("  -> %s" % os.path.relpath(destination, ROOT))


def _verify() -> None:
    checks = [
        (os.path.join(EXTERN, "luau", "VM", "include", "lua.h"), "Luau headers"),
        (os.path.join(EXTERN, "luau", "Compiler", "include", "luacode.h"), "Luau compiler C API"),
        (os.path.join(EXTERN, "godot-cpp", "SConstruct"), "godot-cpp build script"),
        (os.path.join(EXTERN, "godot-cpp", "tools", "godotcpp.py"), "godot-cpp tooling"),
    ]
    missing = [name for path, name in checks if not os.path.exists(path)]
    if missing:
        raise SystemExit("missing after fetch: %s" % ", ".join(missing))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luau", default=LUAU_VERSION, help="Luau release tag (default: %(default)s)")
    parser.add_argument("--godot-cpp", default=GODOT_CPP_VERSION, help="godot-cpp tag (default: %(default)s)")
    parser.add_argument("--force", action="store_true", help="re-download even if the directory exists")
    options = parser.parse_args()

    os.makedirs(EXTERN, exist_ok=True)
    _fetch("luau-lang/luau", options.luau, os.path.join(EXTERN, "luau"), options.force)
    _fetch("godotengine/godot-cpp", options.godot_cpp, os.path.join(EXTERN, "godot-cpp"), options.force)
    _verify()
    print("\nready: cd extensions/luau_vm && scons platform=linux arch=x86_64 target=template_release api_version=4.7")
    return 0


if __name__ == "__main__":
    sys.exit(main())
