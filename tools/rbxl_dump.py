#!/usr/bin/env python3
"""Reference implementation of the Roblox binary model reader (.rbxl/.rbxm).

This is a *tooling* script: it exists so the GDScript importer can be validated
against an independent implementation.  `tools/rbxl_dump.py` prints a JSON
summary of a place file and the CI pipeline diffs it against the summary
produced by the engine's own parser (`tests/dump_place.gd`).

Usage:
    python3 tools/rbxl_dump.py place.rbxl [--json] [--max-instances N]
"""
from __future__ import annotations

import argparse
import json
import struct
import sys

MAGIC = b"<roblox!"
SIGNATURE = b"\x89\xff\x0d\x0a\x1a\x0a"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"

# ---------------------------------------------------------------------------
# LZ4 block decoding (pure python reference)
# ---------------------------------------------------------------------------


def lz4_decompress(src: bytes, expected: int) -> bytes:
    out = bytearray()
    i = 0
    n = len(src)
    while i < n:
        token = src[i]
        i += 1
        literal = token >> 4
        if literal == 15:
            while True:
                extra = src[i]
                i += 1
                literal += extra
                if extra != 255:
                    break
        out += src[i:i + literal]
        i += literal
        if i >= n:
            break
        offset = src[i] | (src[i + 1] << 8)
        i += 2
        match = token & 0x0F
        if match == 15:
            while True:
                extra = src[i]
                i += 1
                match += extra
                if extra != 255:
                    break
        match += 4
        start = len(out) - offset
        if offset >= match:
            out += out[start:start + match]
        else:
            for k in range(match):
                out.append(out[start + k])
    if len(out) != expected:
        raise ValueError("LZ4 size mismatch: %d != %d" % (len(out), expected))
    return bytes(out)


def maybe_zstd(data: bytes, expected: int) -> bytes:
    try:
        import zstandard  # type: ignore
    except ImportError:  # pragma: no cover
        raise RuntimeError("zstandard is required to read zstd chunks")
    return zstandard.ZstdDecompressor().decompress(data, max_output_size=expected)


# ---------------------------------------------------------------------------
# Reader helpers
# ---------------------------------------------------------------------------


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def take(self, count: int) -> bytes:
        out = self.data[self.pos:self.pos + count]
        self.pos += count
        return out

    def u8(self) -> int:
        value = self.data[self.pos]
        self.pos += 1
        return value

    def u16(self) -> int:
        return struct.unpack_from("<H", self.data, self._advance(2))[0]

    def u32(self) -> int:
        return struct.unpack_from("<I", self.data, self._advance(4))[0]

    def i32(self) -> int:
        return struct.unpack_from("<i", self.data, self._advance(4))[0]

    def f32(self) -> float:
        return struct.unpack_from("<f", self.data, self._advance(4))[0]

    def f64(self) -> float:
        return struct.unpack_from("<d", self.data, self._advance(8))[0]

    def _advance(self, count: int) -> int:
        pos = self.pos
        self.pos += count
        return pos

    def string(self) -> str:
        length = self.u32()
        return self.take(length).decode("utf-8", "replace")

    def interleaved(self, count: int, width: int) -> list[bytes]:
        raw = self.take(count * width)
        return [bytes(raw[j * count + i] for j in range(width)) for i in range(count)]


def untransform32(value: int) -> int:
    return (value >> 1) ^ -(value & 1)


def untransform64(value: int) -> int:
    return (value >> 1) ^ -(value & 1)


def roblox_float(raw_be: bytes) -> float:
    bits = int.from_bytes(raw_be, "big")
    rotated = ((bits >> 1) | ((bits & 1) << 31)) & 0xFFFFFFFF
    return struct.unpack("<f", rotated.to_bytes(4, "little"))[0]


# CFrame rotation ids -> euler angles in degrees, applied Y -> X -> Z
CFRAME_ROTATIONS = {
    0x02: (0, 0, 0), 0x03: (90, 0, 0), 0x05: (0, 180, 180), 0x06: (-90, 0, 0),
    0x07: (0, 180, 90), 0x09: (0, 90, 90), 0x0A: (0, 0, 90), 0x0C: (0, -90, 90),
    0x0D: (-90, -90, 0), 0x0E: (0, -90, 0), 0x10: (90, -90, 0), 0x11: (0, 90, 180),
    0x14: (0, 180, 0), 0x15: (-90, -180, 0), 0x17: (0, 0, 180), 0x18: (90, 180, 0),
    0x19: (0, 0, -90), 0x1B: (0, -90, -90), 0x1C: (0, -180, -90), 0x1E: (0, 90, -90),
    0x1F: (90, 90, 0), 0x20: (0, 90, 0), 0x22: (-90, 90, 0), 0x23: (0, -90, 180),
}


def read_cframe_rotation(reader: Reader, count: int) -> list:
    """Reads the per value CFrame rotation part.

    The encoding interleaves the id byte with the optional raw matrix, i.e.
    `[id][36 bytes of raw IEEE floats if id == 0]` repeated per value.
    """
    rotations = []
    for _ in range(count):
        value_id = reader.u8()
        if value_id == 0:
            floats = [reader.f32() for _ in range(9)]
            rotations.append(("raw", floats))
        else:
            rotations.append(("id", CFRAME_ROTATIONS.get(value_id, (0, 0, 0))))
    return rotations


def read_values(reader: Reader, type_id: int, count: int, shared_strings: list[str]) -> list:
    """Decodes `count` values of `type_id` (see the binary format spec)."""
    if type_id == 0x01:
        return [reader.string() for _ in range(count)]
    if type_id == 0x02:
        return [reader.u8() != 0 for _ in range(count)]
    if type_id == 0x03:
        return [untransform32(int.from_bytes(raw, "big")) for raw in reader.interleaved(count, 4)]
    if type_id == 0x04:
        return [roblox_float(raw) for raw in reader.interleaved(count, 4)]
    if type_id == 0x05:
        return [reader.f64() for _ in range(count)]
    if type_id == 0x06:
        scales = reader.interleaved(count, 4)
        offsets = reader.interleaved(count, 4)
        return [
            (roblox_float(scales[i]), untransform32(int.from_bytes(offsets[i], "big")))
            for i in range(count)
        ]
    if type_id == 0x07:
        xs = reader.interleaved(count, 4)
        ys = reader.interleaved(count, 4)
        xo = reader.interleaved(count, 4)
        yo = reader.interleaved(count, 4)
        return [
            (
                roblox_float(xs[i]), roblox_float(ys[i]),
                untransform32(int.from_bytes(xo[i], "big")), untransform32(int.from_bytes(yo[i], "big")),
            )
            for i in range(count)
        ]
    if type_id == 0x08:
        return [tuple(struct.unpack("<6f", reader.take(24))) for _ in range(count)]
    if type_id == 0x09 or type_id == 0x0A:
        return [reader.u8() for _ in range(count)]
    if type_id == 0x0B:
        return [int.from_bytes(raw, "big") for raw in reader.interleaved(count, 4)]
    if type_id == 0x0C:
        reds = reader.interleaved(count, 4)
        greens = reader.interleaved(count, 4)
        blues = reader.interleaved(count, 4)
        return [
            (roblox_float(reds[i]), roblox_float(greens[i]), roblox_float(blues[i]))
            for i in range(count)
        ]
    if type_id == 0x0D:
        xs = reader.interleaved(count, 4)
        ys = reader.interleaved(count, 4)
        return [(roblox_float(xs[i]), roblox_float(ys[i])) for i in range(count)]
    if type_id == 0x0E:
        xs = reader.interleaved(count, 4)
        ys = reader.interleaved(count, 4)
        zs = reader.interleaved(count, 4)
        return [
            (roblox_float(xs[i]), roblox_float(ys[i]), roblox_float(zs[i]))
            for i in range(count)
        ]
    if type_id == 0x10:
        rotations = read_cframe_rotation(reader, count)
        positions = read_values(reader, 0x0E, count, shared_strings)
        return list(zip(rotations, positions))
    if type_id == 0x12:
        return [int.from_bytes(raw, "big") for raw in reader.interleaved(count, 4)]
    if type_id == 0x13:
        values = []
        total = 0
        for raw in reader.interleaved(count, 4):
            total += untransform32(int.from_bytes(raw, "big"))
            values.append(total)
        return values
    if type_id == 0x14:
        return [struct.unpack("<3h", reader.take(6)) for _ in range(count)]
    if type_id == 0x15:
        out = []
        for _ in range(count):
            keypoints = reader.u32()
            out.append([tuple(struct.unpack("<3f", reader.take(12))) for _ in range(keypoints)])
        return out
    if type_id == 0x16:
        out = []
        for _ in range(count):
            keypoints = reader.u32()
            out.append([tuple(struct.unpack("<5f", reader.take(20))) for _ in range(keypoints)])
        return out
    if type_id == 0x17:
        return [tuple(struct.unpack("<2f", reader.take(8))) for _ in range(count)]
    if type_id == 0x18:
        return [tuple(struct.unpack("<4f", reader.take(16))) for _ in range(count)]
    if type_id == 0x19:
        out = []
        for _ in range(count):
            bits = reader.u8()
            value = {"custom": bool(bits & 1), "absorption": bool(bits & 2)}
            if bits & 1:
                fields = 6 if bits & 2 else 5
                value["props"] = struct.unpack("<%df" % fields, reader.take(fields * 4))
            out.append(value)
        return out
    if type_id == 0x1A:
        reds = reader.take(count)
        greens = reader.take(count)
        blues = reader.take(count)
        return [(reds[i], greens[i], blues[i]) for i in range(count)]
    if type_id == 0x1B:
        return [untransform64(int.from_bytes(raw, "big")) for raw in reader.interleaved(count, 8)]
    if type_id == 0x1C:
        out = []
        for raw in reader.interleaved(count, 4):
            index = int.from_bytes(raw, "big")
            out.append(shared_strings[index] if index < len(shared_strings) else "")
        return out
    if type_id == 0x1D:
        return [reader.string() for _ in range(count)]
    if type_id == 0x1E:
        inner = reader.u8()
        assert inner == 0x10, "OptionalCFrame must contain a CFrame"
        values = read_values(reader, 0x10, count, shared_strings)
        present = read_values(reader, 0x02, count, shared_strings)
        return [values[i] if present[i] else None for i in range(count)]
    if type_id == 0x1F:
        indices = reader.interleaved(count, 4)
        times = reader.interleaved(count, 4)
        randoms = reader.interleaved(count, 8)
        return [
            {
                "index": int.from_bytes(indices[i], "big"),
                "time": int.from_bytes(times[i], "big"),
                "random": int.from_bytes(randoms[i], "big", signed=True),
            }
            for i in range(count)
        ]
    if type_id == 0x20:
        out = []
        for _ in range(count):
            family = reader.string()
            weight = reader.u16()
            style = reader.u8()
            cached = reader.string()
            out.append((family, weight, style, cached))
        return out
    if type_id == 0x21:
        return reader.interleaved(count, 8)
    if type_id == 0x22:
        out = []
        for _ in range(count):
            source_count = reader.u32()
            kinds = [reader.u32() for _ in range(source_count)]
            uri_count = reader.u32()
            uris = [reader.string() for _ in range(uri_count)]
            object_count = reader.u32()
            objects = read_values(reader, 0x13, object_count, shared_strings)
            external_count = reader.u32()
            externals = read_values(reader, 0x13, external_count, shared_strings)
            out.append({"kinds": kinds, "uris": uris, "objects": objects, "external": externals})
        return out
    raise ValueError("Unsupported property type id 0x%02x" % type_id)


# ---------------------------------------------------------------------------
# Place parsing
# ---------------------------------------------------------------------------


class Instance:
    __slots__ = ("referent", "class_name", "properties", "children", "parent")

    def __init__(self, referent: int, class_name: str):
        self.referent = referent
        self.class_name = class_name
        self.properties = {}
        self.children = []
        self.parent = None

    @property
    def name(self) -> str:
        return str(self.properties.get("Name", self.class_name))


def parse(data: bytes) -> dict:
    reader = Reader(data)
    if reader.take(8) != MAGIC:
        raise ValueError("not a Roblox binary file")
    reader.take(6)
    version = reader.u16()
    class_count = reader.i32()
    instance_count = reader.i32()
    reader.take(8)

    instances: dict[int, Instance] = {}
    class_ids: dict[int, dict] = {}
    shared_strings: list[str] = []
    metadata: dict = {}
    parents: list[tuple[int, int]] = []
    props_seen = 0

    while True:
        name = reader.take(4).rstrip(b"\x00").decode("ascii", "replace")
        compressed_len = reader.u32()
        uncompressed_len = reader.u32()
        reader.take(4)
        if compressed_len == 0:
            chunk = reader.take(uncompressed_len)
        else:
            body = reader.take(compressed_len)
            if body[:4] == ZSTD_MAGIC:
                chunk = maybe_zstd(body, uncompressed_len)
            else:
                chunk = lz4_decompress(body, uncompressed_len)

        if name == "END":
            break

        chunk_reader = Reader(chunk)
        if name == "META":
            count = chunk_reader.u32()
            for _ in range(count):
                key = chunk_reader.string()
                metadata[key] = chunk_reader.string()
        elif name == "SSTR":
            chunk_reader.u32()
            count = chunk_reader.u32()
            for _ in range(count):
                chunk_reader.take(16)
                shared_strings.append(chunk_reader.string())
        elif name == "INST":
            class_index = chunk_reader.u32()
            class_name = chunk_reader.string()
            object_format = chunk_reader.u8()
            count = chunk_reader.u32()
            referents = read_values(chunk_reader, 0x13, count, shared_strings)
            services = [chunk_reader.u8() for _ in range(count)] if object_format == 1 else []
            class_ids[class_index] = {
                "name": class_name,
                "referents": referents,
                "services": services,
            }
            for referent in referents:
                instances[referent] = Instance(referent, class_name)
        elif name == "PROP":
            class_index = chunk_reader.u32()
            prop_name = chunk_reader.string()
            type_id = chunk_reader.u8()
            info = class_ids[class_index]
            values = read_values(chunk_reader, type_id, len(info["referents"]), shared_strings)
            props_seen += 1
            for referent, value in zip(info["referents"], values):
                instances[referent].properties[prop_name] = value
        elif name == "PRNT":
            chunk_reader.u8()
            count = chunk_reader.u32()
            children = read_values(chunk_reader, 0x13, count, shared_strings)
            parents = list(zip(children, read_values(chunk_reader, 0x13, count, shared_strings)))
        elif name == "SIGN":
            pass
        else:
            raise ValueError("unknown chunk %r" % name)

    roots = []
    for child, parent in parents:
        instance = instances.get(child)
        if instance is None:
            continue
        if parent == -1:
            instance.parent = None
            roots.append(instance)
        else:
            parent_instance = instances.get(parent)
            if parent_instance is None:
                roots.append(instance)
                continue
            instance.parent = parent_instance
            parent_instance.children.append(instance)

    return {
        "version": version,
        "class_count": class_count,
        "instance_count": instance_count,
        "metadata": metadata,
        "roots": roots,
        "instances": instances,
        "prop_chunks": props_seen,
        "shared_strings": len(shared_strings),
    }


def summarize(result: dict, max_instances: int = 0, sample_properties: bool = True) -> dict:
    roots = result["roots"]

    def describe(instance: Instance, depth: int = 0) -> dict:
        entry = {
            "class": instance.class_name,
            "name": instance.name,
            "children": [describe(child, depth + 1) for child in instance.children],
        }
        if sample_properties:
            keep = {}
            for key in ("Size", "size", "Position", "CFrame", "Color", "Color3uint8", "Material",
                        "Anchored", "Transparency", "Shape", "shape", "BrickColor", "CanCollide",
                        "Source", "Value", "Text"):
                if key in instance.properties:
                    value = instance.properties[key]
                    keep[key] = _jsonable(value)
            entry["properties"] = keep
        return entry

    summary = {
        "version": result["version"],
        "class_count": result["class_count"],
        "instance_count": result["instance_count"],
        "prop_chunks": result["prop_chunks"],
        "shared_strings": result["shared_strings"],
        "metadata": result["metadata"],
        "root_count": len(roots),
        "roots": [describe(root) for root in roots[:max_instances or len(roots)]],
    }
    return summary


def _jsonable(value, depth: int = 0):
    if depth > 4:
        return "..."
    if isinstance(value, (str, int, float, bool)) or value is None:
        if isinstance(value, float):
            return round(value, 5)
        return value
    if isinstance(value, (list, tuple)):
        return [_jsonable(item, depth + 1) for item in value]
    if isinstance(value, dict):
        return {str(key): _jsonable(item, depth + 1) for key, item in value.items()}
    return str(value)


def count_instances(result: dict) -> int:
    return len(result["instances"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("--max-instances", type=int, default=6)
    parser.add_argument("--no-properties", action="store_true")
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args()

    with open(args.path, "rb") as handle:
        data = handle.read()
    result = parse(data)
    summary = summarize(result, args.max_instances, not args.no_properties)
    summary["total_instances"] = count_instances(result)
    print(json.dumps(summary, indent=2 if args.pretty else None, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
