#!/usr/bin/env python3
"""Generates the place files that ship with the emulator.

Two flavours are produced for every fixture:

* `.rbxlx` — the XML container (simple, human readable, used to test the XML
  reader and as a reference for what the place contains)
* `.rbxl`  — the binary container (LZ4 compressed chunks), used to test the
  binary reader and as the demo content inside the app

The writer here is intentionally small: it only implements the property types
the demo places need.  It doubles as executable documentation for how the
container is laid out.

Usage:
    python3 tools/make_fixtures.py [--out fixtures]
"""
from __future__ import annotations

import argparse
import base64
import math
import os
import struct

# ---------------------------------------------------------------------------
# Value wrappers
# ---------------------------------------------------------------------------


class Tagged:
    """A property value with an explicit Roblox type name."""

    def __init__(self, type_name: str, value):
        self.type_name = type_name
        self.value = value

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        return "Tagged(%s, %r)" % (self.type_name, self.value)


def S(value: str) -> Tagged:
    return Tagged("string", value)


def B(value: bool) -> Tagged:
    return Tagged("bool", value)


def I(value: int) -> Tagged:
    return Tagged("int", value)


def F(value: float) -> Tagged:
    return Tagged("float", value)


def V3(x: float, y: float, z: float) -> Tagged:
    return Tagged("Vector3", (x, y, z))


def V2(x: float, y: float) -> Tagged:
    return Tagged("Vector2", (x, y))


def COL(r: int, g: int, b: int) -> Tagged:
    return Tagged("Color3uint8", (r, g, b))


def TOKEN(value: int) -> Tagged:
    return Tagged("token", value)


def CF(x: float, y: float, z: float, rotation=None) -> Tagged:
    return Tagged("CFrame", ((x, y, z), rotation))


def BRICK(number: int) -> Tagged:
    return Tagged("BrickColor", number)


def UDIM2(xs: float, xo: int, ys: float, yo: int) -> Tagged:
    return Tagged("UDim2", (xs, xo, ys, yo))


def NUMSEQ(points) -> Tagged:
    return Tagged("NumberSequence", points)


def COLORSEQ(points) -> Tagged:
    return Tagged("ColorSequence", points)


def NUMRANGE(low: float, high: float) -> Tagged:
    return Tagged("NumberRange", (low, high))


def RECT(minx: float, miny: float, maxx: float, maxy: float) -> Tagged:
    return Tagged("Rect2D", (minx, miny, maxx, maxy))


def PHYS(density=0.7, friction=0.3, elasticity=0.5) -> Tagged:
    return Tagged("PhysicalProperties", (density, friction, elasticity))


def REF(target) -> Tagged:
    return Tagged("Ref", target)  # target is an Item or None


def BOOL_ATTRS(mapping) -> Tagged:
    """Attributes blob (binary string) - only listed on the XML path."""
    payload = bytearray()
    payload += struct.pack("<I", len(mapping))
    for key, value in mapping.items():
        encoded = key.encode("utf-8")
        payload += struct.pack("<I", len(encoded))
        payload += encoded
        if isinstance(value, bool):
            payload += bytes([0x03, 1 if value else 0])
        elif isinstance(value, int):
            payload += bytes([0x04]) + struct.pack("<i", value)
        elif isinstance(value, float):
            payload += bytes([0x06]) + struct.pack("<d", value)
        elif isinstance(value, str):
            encoded_value = value.encode("utf-8")
            payload += bytes([0x02]) + struct.pack("<I", len(encoded_value)) + encoded_value
        else:
            raise TypeError("unsupported attribute type: %r" % type(value))
    return Tagged("AttributesSerialize", bytes(payload))


class Item:
    def __init__(self, class_name: str, name: str = "", **props):
        self.class_name = class_name
        self.name = name or class_name
        self.props = {"Name": props.pop("Name", S(self.name))}
        self.props.update(props)
        self.children: list[Item] = []
        self.referent: int = -1

    def add(self, *children: "Item") -> "Item":
        self.children.extend(children)
        return self

    # convenience ---------------------------------------------------------
    @property
    def properties(self) -> dict:
        return self.props


def part(name, size, position, color=(163, 162, 165), material=256, shape=1, **extra) -> Item:
    props = {
        "size": V3(*size),
        "CFrame": CF(position[0], position[1], position[2], extra.pop("rotation", None)),
        "Color3uint8": COL(*color),
        "Material": TOKEN(material),
        "Anchored": B(True),
        "CanCollide": B(True),
        "shape": TOKEN(shape),
    }
    props.update(extra)
    return Item("Part", name, **props)


def spawn(name, position) -> Item:
    return Item(
        "SpawnLocation", name,
        size=V3(12, 1, 12),
        CFrame=CF(position[0], position[1], position[2]),
        Color3uint8=COL(196, 40, 28),
        Anchored=B(True),
        Material=TOKEN(256),
        Transparency=F(0.0),
        CanCollide=B(True),
        Duration=I(0),
        Neutral=B(True),
    )


# ---------------------------------------------------------------------------
# XML writer
# ---------------------------------------------------------------------------

XML_ESCAPES = {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}


def xml_escape(text: str) -> str:
    return "".join(XML_ESCAPES.get(char, char) for char in text)


def float_text(value: float) -> str:
    if value == int(value) and abs(value) < 1e15:
        return str(int(value))
    return repr(float(value))


def value_xml(tagged: Tagged | str | int | float | bool) -> str:
    if isinstance(tagged, Tagged):
        type_name, value = tagged.type_name, tagged.value
    else:
        type_name, value = ("string", tagged) if isinstance(tagged, str) else ("float", tagged)

    if type_name == "string":
        return "<string>%s</string>" % xml_escape(str(value))
    if type_name == "ProtectedString":
        return "<ProtectedString><![CDATA[%s]]></ProtectedString>" % value
    if type_name == "bool":
        return "<bool>%s</bool>" % ("true" if value else "false")
    if type_name == "int":
        return "<int>%d</int>" % int(value)
    if type_name == "int64":
        return "<int64>%d</int64>" % int(value)
    if type_name == "token":
        return "<token>%d</token>" % int(value)
    if type_name == "float":
        return "<float>%s</float>" % float_text(float(value))
    if type_name == "double":
        return "<double>%s</double>" % float_text(float(value))
    if type_name == "BrickColor":
        return "<int>%d</int>" % int(value)
    if type_name == "Color3uint8":
        red, green, blue = value
        return "<Color3uint8>%d</Color3uint8>" % (0xFF000000 | (red << 16) | (green << 8) | blue)
    if type_name == "Color3":
        red, green, blue = value
        return "<Color3><R>%s</R><G>%s</G><B>%s</B></Color3>" % (float_text(red), float_text(green), float_text(blue))
    if type_name in ("Vector2", "Vector3"):
        names = "XYZ"[: len(value)]
        inner = "".join("<%s>%s</%s>" % (axis, float_text(component), axis) for axis, component in zip(names, value))
        return "<%s>%s</%s>" % (type_name, inner, type_name)
    if type_name == "CFrame":
        position, rotation = value
        rows = rotation or ((1, 0, 0), (0, 1, 0), (0, 0, 1))
        inner = "<X>%s</X><Y>%s</Y><Z>%s</Z>" % tuple(float_text(c) for c in position)
        for row_index, row in enumerate(rows):
            for column, component in enumerate(row):
                inner += "<R%d%d>%s</R%d%d>" % (row_index, column, float_text(component), row_index, column)
        return "<CoordinateFrame>%s</CoordinateFrame>" % inner
    if type_name == "UDim2":
        xs, xo, ys, yo = value
        return "<UDim2><XS>%s</XS><XO>%d</XO><YS>%s</YS><YO>%d</YO></UDim2>" % (
            float_text(xs), int(xo), float_text(ys), int(yo),
        )
    if type_name == "UDim":
        scale, offset = value
        return "<UDim><S>%s</S><O>%d</O></UDim>" % (float_text(scale), int(offset))
    if type_name == "UDim":
        scale_bytes = bytearray()
        offset_bytes = bytearray()
        for item in items:
            scale, offset = value_for(item, prop_name)
            scale_bytes += struct.pack(">I", roblox_float_bits(scale))
            offset_bytes += struct.pack(">I", transform32(int(offset)))
        return 0x06, _columns(scale_bytes, count, 4) + _columns(offset_bytes, count, 4)
    if type_name == "UDim2":
        xs = bytearray()
        ys = bytearray()
        xo = bytearray()
        yo = bytearray()
        for item in items:
            x_scale, x_offset, y_scale, y_offset = value_for(item, prop_name)
            xs += struct.pack(">I", roblox_float_bits(x_scale))
            ys += struct.pack(">I", roblox_float_bits(y_scale))
            xo += struct.pack(">I", transform32(int(x_offset)))
            yo += struct.pack(">I", transform32(int(y_offset)))
        return 0x07, _columns(xs, count, 4) + _columns(ys, count, 4) + _columns(xo, count, 4) + _columns(yo, count, 4)
    if type_name == "NumberSequence":
        body = " ".join(
            "%s %s %s" % (float_text(point[0]), float_text(point[1]), float_text(point[2] if len(point) > 2 else 0.0))
            for point in value
        )
        return "<NumberSequence>%s </NumberSequence>" % body
    if type_name == "ColorSequence":
        body = " ".join(
            "%s %s %s %s 0" % (float_text(point[0]), float_text(point[1][0]), float_text(point[1][1]), float_text(point[1][2]))
            for point in value
        )
        return "<ColorSequence>%s </ColorSequence>" % body
    if type_name == "NumberRange":
        return "<NumberRange>%s %s </NumberRange>" % (float_text(value[0]), float_text(value[1]))
    if type_name == "Rect2D":
        return "<Rect2D><min><X>%s</X><Y>%s</Y></min><max><X>%s</X><Y>%s</Y></max></Rect2D>" % tuple(
            float_text(v) for v in value
        )
    if type_name == "PhysicalProperties":
        density, friction, elasticity = value
        return (
            "<PhysicalProperties><CustomPhysics>true</CustomPhysics>"
            "<Density>%s</Density><Friction>%s</Friction><Elasticity>%s</Elasticity>"
            "<FrictionWeight>1</FrictionWeight><ElasticityWeight>1</ElasticityWeight>"
            "<AcousticAbsorption>1</AcousticAbsorption></PhysicalProperties>"
        ) % (float_text(density), float_text(friction), float_text(elasticity))
    if type_name == "Ref":
        if value is None:
            return "<Ref>null</Ref>"
        return "<Ref>RBX%d</Ref>" % value.referent
    if type_name == "AttributesSerialize":
        return "<BinaryString>%s</BinaryString>" % base64.b64encode(value).decode("ascii")
    if type_name == "Content":
        if not value:
            return "<Content><null></null></Content>"
        return "<Content><uri>%s</uri></Content>" % xml_escape(str(value))
    raise ValueError("XML writer does not support %s" % type_name)


def write_xml(roots: list[Item], path: str) -> None:
    lines = ['<roblox version="4">']
    lines.append('\t<Meta name="ExplicitAutoJoints">true</Meta>')
    lines.append("\t<External>null</External>")
    lines.append("\t<External>nil</External>")

    def emit(item: Item, depth: int) -> None:
        indent = "\t" * depth
        lines.append('%s<Item class="%s" referent="RBX%d">' % (indent, item.class_name, item.referent))
        lines.append("%s\t<Properties>" % indent)
        for key, value in item.properties.items():
            encoded = value_xml(value) if value is not None else "<string></string>"
            head, _, tail = encoded.partition(">")
            lines.append('%s\t\t%s name="%s">%s' % (indent, head, xml_escape(key), tail))
        lines.append("%s\t</Properties>" % indent)
        for child in item.children:
            emit(child, depth + 1)
        lines.append("%s</Item>" % indent)

    for root in roots:
        emit(root, 1)
    lines.append("</roblox>")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# Binary writer
# ---------------------------------------------------------------------------

BASIC_ROTATIONS = {
    (1, 0, 0, 0, 1, 0, 0, 0, 1): 0x02,
}


def transform32(value: int) -> int:
    """Zigzag: 0, -1, 1, -2, 2 ... -> 0, 1, 2, 3, 4 ...

    The value has to stay signed: pre-masking it to 32 bits turns -1 into
    0xFFFFFFFF, which decodes back as -2147483648 and breaks every reference.
    """
    return ((value << 1) ^ (value >> 31)) & 0xFFFFFFFF


def delta_referents(values: list[int]) -> bytes:
    """Encodes a referent array the way the format wants it.

    Readers accumulate referents ("the actual value is the read value plus the
    preceding one"), so a writer has to store differences.
    """
    payload = bytearray()
    previous = 0
    for value in values:
        payload += struct.pack(">I", transform32(value - previous))
        previous = value
    return bytes(payload)


def transform64(value: int) -> int:
    return ((value << 1) ^ (value >> 63)) & 0xFFFFFFFFFFFFFFFF


def roblox_float_bits(value: float) -> int:
    """Encodes an IEEE float the way Roblox stores Float32 values."""
    bits = struct.unpack("<I", struct.pack("<f", value))[0]
    return ((bits << 1) | (bits >> 31)) & 0xFFFFFFFF


def interleave(values: list[bytes], width: int) -> bytes:
    out = bytearray()
    for byte_index in range(width):
        for value in values:
            out.append(value[byte_index])
    return bytes(out)


def encode_values(items: list[Item], prop_name: str, tagged: Tagged) -> tuple[int, bytes]:
    """Returns (type id, payload) for a property shared by every `items`."""
    type_name = tagged.type_name
    count = len(items)

    if type_name == "string":
        payload = bytearray()
        for item in items:
            encoded = value_for(item, prop_name).encode("utf-8")
            payload += struct.pack("<I", len(encoded)) + encoded
        return 0x01, bytes(payload)
    if type_name == "ProtectedString":
        payload = bytearray()
        for item in items:
            encoded = value_for(item, prop_name).encode("utf-8")
            payload += struct.pack("<I", len(encoded)) + encoded
        return 0x01, bytes(payload)
    if type_name == "bool":
        return 0x02, bytes(1 if value_for(item, prop_name) else 0 for item in items)
    if type_name == "int":
        payload = bytearray()
        for item in items:
            payload += struct.pack(">I", transform32(int(value_for(item, prop_name))))
        return 0x03, _columns(payload, count, 4)
    if type_name == "int64":
        payload = bytearray()
        for item in items:
            payload += struct.pack(">Q", transform64(int(value_for(item, prop_name))))
        return 0x1B, _columns(payload, count, 8)
    if type_name == "token":
        payload = bytearray()
        for item in items:
            payload += struct.pack(">I", int(value_for(item, prop_name)) & 0xFFFFFFFF)
        return 0x12, _columns(payload, count, 4)
    if type_name == "float":
        payload = bytearray()
        for item in items:
            payload += struct.pack(">I", roblox_float_bits(float(value_for(item, prop_name))))
        return 0x04, _columns(payload, count, 4)
    if type_name == "double":
        payload = bytearray()
        for item in items:
            payload += struct.pack("<d", float(value_for(item, prop_name)))
        return 0x05, bytes(payload)
    if type_name == "BrickColor":
        payload = bytearray()
        for item in items:
            payload += struct.pack(">I", int(value_for(item, prop_name)) & 0xFFFFFFFF)
        return 0x0B, _columns(payload, count, 4)
    if type_name == "Color3uint8":
        reds = bytes(value_for(item, prop_name)[0] for item in items)
        greens = bytes(value_for(item, prop_name)[1] for item in items)
        blues = bytes(value_for(item, prop_name)[2] for item in items)
        return 0x1A, reds + greens + blues
    if type_name == "Color3":
        payload = bytearray()
        for channel in range(3):
            for item in items:
                payload += struct.pack(">I", roblox_float_bits(value_for(item, prop_name)[channel]))
        return 0x0C, _columns_multiplex(payload, count, 4, 3)
    if type_name == "Vector2":
        payload = bytearray()
        for axis in range(2):
            for item in items:
                payload += struct.pack(">I", roblox_float_bits(value_for(item, prop_name)[axis]))
        return 0x0D, _columns_multiplex(payload, count, 4, 2)
    if type_name == "Vector3":
        payload = bytearray()
        for axis in range(3):
            for item in items:
                payload += struct.pack(">I", roblox_float_bits(value_for(item, prop_name)[axis]))
        return 0x0E, _columns_multiplex(payload, count, 4, 3)
    if type_name == "CFrame":
        rotation_payload = bytearray()
        for item in items:
            position, rotation = value_for(item, prop_name)
            if rotation is None:
                rotation_payload += bytes([0x02])
            else:
                rotation_payload += bytes([0])
                for row in rotation:
                    for component in row:
                        rotation_payload += struct.pack("<f", component)
        position_payload = bytearray()
        for axis in range(3):
            for item in items:
                position_payload += struct.pack(">I", roblox_float_bits(value_for(item, prop_name)[0][axis]))
        return 0x10, bytes(rotation_payload) + _columns_multiplex(position_payload, count, 4, 3)
    if type_name == "Ref":
        referents = []
        for item in items:
            target = value_for(item, prop_name)
            referents.append(-1 if target is None else target.referent)
        return 0x13, _columns(delta_referents(referents), count, 4)
    if type_name == "UDim":
        scale_bytes = bytearray()
        offset_bytes = bytearray()
        for item in items:
            scale, offset = value_for(item, prop_name)
            scale_bytes += struct.pack(">I", roblox_float_bits(scale))
            offset_bytes += struct.pack(">I", transform32(int(offset)))
        return 0x06, _columns(scale_bytes, count, 4) + _columns(offset_bytes, count, 4)
    if type_name == "UDim2":
        xs = bytearray()
        ys = bytearray()
        xo = bytearray()
        yo = bytearray()
        for item in items:
            x_scale, x_offset, y_scale, y_offset = value_for(item, prop_name)
            xs += struct.pack(">I", roblox_float_bits(x_scale))
            ys += struct.pack(">I", roblox_float_bits(y_scale))
            xo += struct.pack(">I", transform32(int(x_offset)))
            yo += struct.pack(">I", transform32(int(y_offset)))
        return 0x07, _columns(xs, count, 4) + _columns(ys, count, 4) + _columns(xo, count, 4) + _columns(yo, count, 4)
    if type_name == "NumberSequence":
        payload = bytearray()
        for item in items:
            points = value_for(item, prop_name)
            payload += struct.pack("<I", len(points))
            for point in points:
                payload += struct.pack("<3f", point[0], point[1], point[2] if len(point) > 2 else 0.0)
        return 0x15, bytes(payload)
    if type_name == "ColorSequence":
        payload = bytearray()
        for item in items:
            points = value_for(item, prop_name)
            payload += struct.pack("<I", len(points))
            for point in points:
                payload += struct.pack("<3f", point[0], point[1][0], point[1][1])
                payload += struct.pack("<f", point[1][2])
                payload += struct.pack("<f", 0.0)
        return 0x16, bytes(payload)
    if type_name == "NumberRange":
        payload = bytearray()
        for item in items:
            payload += struct.pack("<2f", value_for(item, prop_name)[0], value_for(item, prop_name)[1])
        return 0x17, bytes(payload)
    if type_name == "Rect2D":
        payload = bytearray()
        for item in items:
            payload += struct.pack("<4f", *value_for(item, prop_name))
        return 0x18, bytes(payload)
    if type_name == "PhysicalProperties":
        payload = bytearray()
        for item in items:
            value = value_for(item, prop_name)
            if value == "Default" or value is None:
                payload += bytes([0x00])
                continue
            density, friction, elasticity = value
            payload += bytes([0x01])
            payload += struct.pack("<5f", density, friction, elasticity, 1.0, 1.0)
        return 0x19, bytes(payload)
    if type_name == "AttributesSerialize":
        payload = bytearray()
        for item in items:
            blob = value_for(item, prop_name)
            payload += struct.pack("<I", len(blob)) + blob
        return 0x01, bytes(payload)
    if type_name == "Content":
        payload = bytearray()
        for item in items:
            uri = value_for(item, prop_name)
            kinds = [1] if uri else []
            payload += struct.pack("<I", len(kinds))
            for kind in kinds:
                payload += struct.pack("<I", kind)
            payload += struct.pack("<I", len(kinds))
            if uri:
                encoded = str(uri).encode("utf-8")
                payload += struct.pack("<I", len(encoded)) + encoded
            payload += struct.pack("<I", 0)  # object referents
            payload += struct.pack("<I", 0)  # external referents
        return 0x22, bytes(payload)
    raise ValueError("binary writer does not support %s" % type_name)


DEFAULT_PROPERTIES = {
    "Name": S("Instance"),
    "AttributesSerialize": Tagged("AttributesSerialize", b""),
    "CustomPhysicalProperties": Tagged("PhysicalProperties", "Default"),
    "Size": UDIM2(0, 100, 0, 100),
    "Position": UDIM2(0, 0, 0, 0),
    "Text": S(""),
    "TextSize": F(14.0),
    "TextColor3": Tagged("Color3", (0, 0, 0)),
    "BackgroundColor3": Tagged("Color3", (0.64, 0.64, 0.64)),
    "Font": TOKEN(0),
    "BorderSizePixel": I(1),
    "ZIndex": I(1),
    "Visible": B(True),
    "Brightness": F(1.0),
    "Range": F(8.0),
    "Color": Tagged("Color3", (1, 1, 1)),
    "AmbientReverb": TOKEN(0),
    "RespawnTime": F(5.0),
    "CharacterAutoLoads": B(True),
    "Technology": TOKEN(2),
    "ClockTime": F(14.0),
    "GlobalShadows": B(True),
    "Ambient": Tagged("Color3", (0.0, 0.0, 0.0)),
    "OutdoorAmbient": Tagged("Color3", (0.5, 0.5, 0.5)),
    "Neutral": B(True),
    "Duration": I(0),
    "size": V3(4, 1.2, 2),
    "CFrame": CF(0, 0, 0),
    "Color3uint8": COL(163, 162, 165),
    "Material": TOKEN(256),
    "shape": TOKEN(1),
    "Anchored": B(False),
    "CanCollide": B(True),
    "Transparency": F(0.0),
    "Reflectance": F(0.0),
    "Locked": B(False),
    "Disabled": B(False),
    "Source": Tagged("ProtectedString", ""),
    "Value": I(0),
    "Text": S(""),
    "BackgroundTransparency": F(0.0),
}


def value_for(item: Item, prop_name: str):
    """Value of `prop_name` on `item`, falling back to the class default.

    The binary container requires every instance of a class to carry the same
    property set, so instances that omit a property are written with the
    default value instead.
    """
    if prop_name not in item.props:
        fallback = DEFAULT_PROPERTIES.get(prop_name)
        if fallback is None:
            raise KeyError("%s has no `%s` and no default is known" % (item.class_name, prop_name))
        return fallback.value
    tagged = item.props[prop_name]
    return tagged.value


def _columns(payload: bytearray, count: int, width: int) -> bytes:
    """Interleaves a flat list of big endian fixed width values."""
    return interleave([bytes(payload[i * width:(i + 1) * width]) for i in range(count)], width)


def _columns_multiplex(payload: bytearray, count: int, width: int, groups: int) -> bytes:
    """Same as `_columns` but for structs made of several component arrays."""
    out = bytearray()
    stride = count * width
    for group in range(groups):
        chunk = payload[group * stride:(group + 1) * stride]
        out += _columns(chunk, count, width)
    return bytes(out)


def lz4_compress(data: bytes) -> bytes:
    """Very small LZ4 block compressor (greedy, hash table based)."""
    out = bytearray()
    table: dict[bytes, int] = {}
    anchor = 0
    index = 0
    length = len(data)
    while index < length - 4:
        key = data[index:index + 4]
        candidate = table.get(key, -1)
        table[key] = index
        if candidate >= 0 and index - candidate < 65536:
            match_length = 4
            while (index + match_length < length
                   and data[candidate + match_length] == data[index + match_length]
                   and match_length < 65539):
                match_length += 1
            literal_length = index - anchor
            token_literal = min(literal_length, 15)
            token_match = min(match_length - 4, 15)
            out.append((token_literal << 4) | token_match)
            remaining = literal_length - 15
            while remaining >= 255:
                out.append(255)
                remaining -= 255
            if literal_length >= 15:
                out.append(remaining)
            out += data[anchor:index]
            offset = index - candidate
            out.append(offset & 0xFF)
            out.append((offset >> 8) & 0xFF)
            remaining = match_length - 4 - 15
            while remaining >= 255:
                out.append(255)
                remaining -= 255
            if match_length - 4 >= 15:
                out.append(remaining)
            index += match_length
            anchor = index
        else:
            index += 1
    literal_length = length - anchor
    out.append(min(literal_length, 15) << 4)
    remaining = literal_length - 15
    while remaining >= 255:
        out.append(255)
        remaining -= 255
    if literal_length >= 15:
        out.append(remaining)
    out += data[anchor:]
    return bytes(out)


def zstd_compress(data: bytes) -> bytes:
    try:
        import zstandard  # type: ignore
    except ImportError as error:  # pragma: no cover
        raise RuntimeError("pip install zstandard to write zstd fixtures") from error
    return zstandard.ZstdCompressor(level=10).compress(data)


def assign_referents(items: list[Item]) -> list[Item]:
    """Depth first post-order, which is what Roblox Studio writes."""
    ordered: list[Item] = []

    def visit(item: Item) -> None:
        for child in item.children:
            visit(child)
        item.referent = len(ordered)
        ordered.append(item)

    for item in items:
        visit(item)
    return ordered


def build_binary(roots: list[Item], compression: str = "lz4") -> bytes:
    ordered = assign_referents(roots)
    by_class: dict[str, list[Item]] = {}
    for item in ordered:
        by_class.setdefault(item.class_name, []).append(item)

    # Chunks are written grouped per class, mirroring Studio's output.
    chunks: list[bytes] = []

    for class_index, (class_name, items) in enumerate(sorted(by_class.items())):
        payload = bytearray()
        payload += struct.pack("<I", class_index)
        encoded = class_name.encode("utf-8")
        payload += struct.pack("<I", len(encoded)) + encoded
        payload += bytes([0])
        payload += struct.pack("<I", len(items))
        payload += _columns(delta_referents([item.referent for item in items]), len(items), 4)
        chunks.append(frame(b"INST", bytes(payload), compression))

        property_names: list[str] = []
        for item in items:
            for key in item.properties.keys():
                if key not in property_names:
                    property_names.append(key)
        property_names.sort()
        for prop_name in property_names:
            sample = _sample_tagged(items, prop_name)
            type_id, encoded_values = encode_values(items, prop_name, sample)
            prop_payload = bytearray()
            prop_payload += struct.pack("<I", class_index)
            encoded_name = prop_name.encode("utf-8")
            prop_payload += struct.pack("<I", len(encoded_name)) + encoded_name
            prop_payload += bytes([type_id])
            prop_payload += encoded_values
            chunks.append(frame(b"PROP", bytes(prop_payload), compression))

    parent_payload = bytearray()
    parent_payload += bytes([0])
    parent_payload += struct.pack("<I", len(ordered))
    children = [item.referent for item in ordered]
    parents = []
    for item in ordered:
        parent = find_parent(roots, item)
        parents.append(-1 if parent is None else parent.referent)
    parent_payload += _columns(delta_referents(children), len(ordered), 4)
    parent_payload += _columns(delta_referents(parents), len(ordered), 4)
    chunks.append(frame(b"PRNT", bytes(parent_payload), compression))

    meta_payload = bytearray()
    meta_payload += struct.pack("<I", 1)
    key = b"ExplicitAutoJoints"
    value = b"true"
    meta_payload += struct.pack("<I", len(key)) + key
    meta_payload += struct.pack("<I", len(value)) + value
    chunks.insert(0, frame(b"META", bytes(meta_payload), compression))

    header = bytearray()
    header += b"<roblox!"
    header += bytes([0x89, 0xFF, 0x0D, 0x0A, 0x1A, 0x0A])
    header += struct.pack("<H", 0)
    header += struct.pack("<i", len(by_class))
    header += struct.pack("<i", len(ordered))
    header += bytes(8)

    end_chunk = b"END\x00" + struct.pack("<III", 0, 9, 0) + b"</roblox>"
    return bytes(header) + b"".join(chunks) + end_chunk


def _sample_tagged(items: list[Item], prop_name: str) -> Tagged:
    """A tagged value describing the type of `prop_name` for a whole class."""
    for item in items:
        if prop_name in item.props:
            return item.props[prop_name]
    fallback = DEFAULT_PROPERTIES.get(prop_name)
    if fallback is None:
        raise KeyError("no sample value for `%s`" % prop_name)
    return fallback


def find_parent(roots: list[Item], target: Item) -> Item | None:
    for root in roots:
        if root is target:
            return None
        found = _find_parent(root, target)
        if found is not None:
            return found
    return None


def _find_parent(node: Item, target: Item) -> Item | None:
    for child in node.children:
        if child is target:
            return node
        found = _find_parent(child, target)
        if found is not None:
            return found
    return None


def frame(name: bytes, payload: bytes, compression: str) -> bytes:
    name = name.ljust(4, b"\x00")
    if compression == "none":
        return name + struct.pack("<III", 0, len(payload), 0) + payload
    compressed = lz4_compress(payload) if compression == "lz4" else zstd_compress(payload)
    if len(compressed) >= len(payload):
        return name + struct.pack("<III", 0, len(payload), 0) + payload
    return name + struct.pack("<III", len(compressed), len(payload), 0) + compressed


# ---------------------------------------------------------------------------
# The actual fixtures
# ---------------------------------------------------------------------------


def build_all_types() -> list[Item]:
    values_folder = Item("Folder", "Values").add(
        Item("StringValue", "String", Value=S("hello \u2603")),
        Item("BoolValue", "Bool", Value=B(True)),
        Item("IntValue", "Int", Value=I(-42)),
        Item("NumberValue", "Number", Value=F(0.15625)),
        Item("BrickColorValue", "BrickColor", Value=BRICK(194)),
        Item("Color3Value", "Color", Value=Tagged("Color3", (0.25, 0.5, 0.75))),
        Item("Vector3Value", "Vector", Value=V3(1.5, -2.25, 3.0)),
        Item("CFrameValue", "Transform", Value=CF(1, 2, 3)),
        Item("NumberRangeValue", "Range", Value=NUMRANGE(0.25, 0.75)),
    )

    sequences = Item("Folder", "Sequences").add(
        Item("ParticleEmitter", "Emitter",
             Transparency=NUMSEQ(((0.0, 1.0, 0.0), (0.5, 0.25, 0.1), (1.0, 0.0, 0.0))),
             Color=COLORSEQ(((0.0, (1.0, 0.0, 0.0)), (1.0, (0.0, 0.0, 1.0))))),
        Item("ImageLabel", "Image", SliceCenter=RECT(0.0, 0.0, 32.0, 32.0)),
    )

    physics_part = part("PhysicsPart", (4, 1, 2), (10, 5, 0), color=(196, 40, 28), material=256)
    physics_part.props["CustomPhysicalProperties"] = PHYS(0.9, 0.6, 0.4)
    physics_part.props["Transparency"] = F(0.5)
    physics_part.props["Reflectance"] = F(0.25)

    referenced = Item("Part", "Referenced", size=V3(2, 2, 2), CFrame=CF(4, 4, 4), Anchored=B(True),
                      Color3uint8=COL(13, 105, 172), Material=TOKEN(256), CanCollide=B(True))
    link = Item("ObjectValue", "Link", Value=REF(referenced))

    attributed = Item("Part", "Attributed", size=V3(3, 3, 3), CFrame=CF(-6, 3, 0), Anchored=B(True),
                      Color3uint8=COL(245, 205, 48), Material=TOKEN(256), CanCollide=B(True))
    attributed.props["AttributesSerialize"] = BOOL_ATTRS({"Health": 100, "Friendly": True, "Label": "test", "Speed": 1.5})

    script = Item("Script", "Hello", Name=S("Hello"), Disabled=B(False),
                  Source=Tagged("ProtectedString", 'print("hello from Luau")'))

    return [
        Item("Folder", "AllTypes").add(
            values_folder,
            sequences,
            physics_part,
            referenced,
            link,
            attributed,
            script,
        )
    ]


def build_showcase() -> list[Item]:
    workspace = Item("Workspace", "Workspace")
    base = part("Baseplate", (512, 20, 512), (0, -10, 0), color=(99, 95, 98), material=816)
    base.props["Locked"] = B(True)
    workspace.add(base)

    spawn_location = spawn("SpawnLocation", (0, 0.5, 0))
    workspace.add(spawn_location)

    shapes = [
        ("Block", 1, (0, 1, -24), (163, 162, 165), 256),
        ("Wedge", 3, (12, 1, -24), (196, 40, 28), 256),
        ("CornerWedge", 4, (24, 1, -24), (13, 105, 172), 256),
        ("Cylinder", 2, (36, 1, -24), (245, 205, 48), 256),
        ("Ball", 0, (48, 3, -24), (40, 127, 71), 256),
    ]
    shape_model = Item("Model", "Shapes")
    for name, shape, position, color, material in shapes:
        shape_model.add(part(name, (6, 6, 6) if shape == 0 else (6, 3, 6), position, color=color,
                             material=material, shape=shape))
    workspace.add(shape_model)

    materials = [
        ("Plastic", 256), ("Wood", 512), ("Slate", 800), ("Concrete", 816), ("Brick", 848),
        ("Granite", 832), ("Metal", 1088), ("Grass", 1280), ("Sand", 1296), ("Fabric", 1312),
        ("Ice", 1536), ("Glass", 1568), ("Neon", 288), ("DiamondPlate", 1056), ("Foil", 1072),
    ]
    material_model = Item("Model", "Materials")
    for index, (name, material) in enumerate(materials):
        x = -60.0 + index * 9.0
        material_model.add(part(name, (8, 4, 8), (x, 2, 20), color=(220, 220, 220), material=material))
    workspace.add(material_model)

    tower = Item("Model", "Tower")
    for level in range(12):
        angle = level * 0.35
        tower.add(part("Step%02d" % level, (6, 1, 6),
                       (math.cos(angle) * 30.0, 3.0 + level * 3.0, math.sin(angle) * 30.0),
                       color=(13, 105, 172) if level % 2 == 0 else (13, 105, 172),
                       material=256, rotation=((1, 0, 0), (0, math.cos(angle), -math.sin(angle)), (0, math.sin(angle), math.cos(angle)))))
    workspace.add(tower)

    neon = part("NeonSign", (24, 6, 1), (0, 12, -40), color=(255, 0, 128), material=288)
    neon.add(Item("PointLight", "Glow", Color=Tagged("Color3", (1.0, 0.1, 0.5)), Brightness=F(3.0), Range=F(48.0)))
    workspace.add(neon)

    gui = Item("ScreenGui", "Hud")
    frame = Item("Frame", "Panel",
                 Size=UDIM2(0.35, 0, 0.16, 0), Position=UDIM2(0.02, 0, 0.04, 0),
                 BackgroundColor3=Tagged("Color3", (0.09, 0.11, 0.16)), BackgroundTransparency=F(0.15),
                 BorderSizePixel=I(0))
    frame.add(Item("TextLabel", "Title",
                   Size=UDIM2(1.0, 0, 0.5, 0), Position=UDIM2(0, 0, 0, 0),
                   Text=S("Imported from Roblox"), TextColor3=Tagged("Color3", (1, 1, 1)),
                   TextSize=F(24), BackgroundTransparency=F(1), Font=TOKEN(2)))
    frame.add(Item("TextButton", "Action",
                   Size=UDIM2(0.5, 0, 0.35, 0), Position=UDIM2(0.5, 0, 0.55, 0),
                   Text=S("Press"), TextColor3=Tagged("Color3", (1, 1, 1)), TextSize=F(18),
                   BackgroundColor3=Tagged("Color3", (0.31, 0.55, 1.0)), BackgroundTransparency=F(0.1),
                   BorderSizePixel=I(0)))
    gui.add(frame)

    starter_gui = Item("StarterGui", "StarterGui").add(gui)

    lighting = Item("Lighting", "Lighting",
                    Ambient=Tagged("Color3", (0.27, 0.27, 0.27)),
                    Brightness=F(2.0),
                    ClockTime=F(14.5),
                    OutdoorAmbient=Tagged("Color3", (0.5, 0.5, 0.5)),
                    GlobalShadows=B(True),
                    Technology=TOKEN(2))

    players = Item("Players", "Players",
                   RespawnTime=F(5.0),
                   CharacterAutoLoads=B(True))

    sound = Item("SoundService", "SoundService", AmbientReverb=TOKEN(0))

    return [workspace, lighting, starter_gui, players, sound]


def build_obby() -> list[Item]:
    workspace = Item("Workspace", "Workspace")
    workspace.add(part("Baseplate", (256, 20, 256), (0, -10, 0), color=(99, 95, 98), material=816))
    workspace.add(spawn("Start", (0, 0.5, 0)))

    course = Item("Model", "Course")
    for index in range(24):
        x = (index % 6 - 2.5) * 18.0
        z = -20.0 - (index // 6) * 20.0
        y = 1.0 + (index // 6) * 2.0
        hue = float(index) / 24.0
        color = (
            int(120 + 120 * math.sin(hue * 6.283)),
            int(120 + 120 * math.sin((hue + 0.33) * 6.283)),
            int(120 + 120 * math.sin((hue + 0.66) * 6.283)),
        )
        platform = part("Platform%02d" % index, (10, 1, 10), (x, y, z), color=color,
                        material=256 if index % 3 else 288)
        if index % 5 == 4:
            platform.props["Transparency"] = F(0.35)
        course.add(platform)
    workspace.add(course)

    finish = part("Finish", (16, 1, 16), (0, 12, -140), color=(245, 205, 48), material=288)
    finish.add(Item("PointLight", "Glow", Color=Tagged("Color3", (1.0, 0.85, 0.3)), Brightness=F(2.0), Range=F(40.0)))
    workspace.add(finish)

    lighting = Item("Lighting", "Lighting", Brightness=F(2.0), ClockTime=F(15.0),
                    Ambient=Tagged("Color3", (0.3, 0.3, 0.35)))
    players = Item("Players", "Players")
    starter_gui = Item("StarterGui", "StarterGui")
    return [workspace, lighting, players, starter_gui]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "fixtures"))
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    fixtures = {
        "all_types": build_all_types,
        "demo_showcase": build_showcase,
        "demo_obby": build_obby,
    }
    for name, builder in fixtures.items():
        roots = builder()
        xml_path = os.path.join(args.out, name + ".rbxlx")
        bin_path = os.path.join(args.out, name + ".rbxl")
        write_xml(roots, xml_path)
        with open(bin_path, "wb") as handle:
            handle.write(build_binary(roots, "lz4"))
        print("%-16s xml %6d bytes   binary %6d bytes" % (
            name, os.path.getsize(xml_path), os.path.getsize(bin_path)))

    # A zstd compressed copy so both decompressors are covered by the tests.
    roots = build_all_types()
    with open(os.path.join(args.out, "all_types_zstd.rbxl"), "wb") as handle:
        handle.write(build_binary(roots, "zstd"))
    print("all_types_zstd   binary %6d bytes (zstd)" % os.path.getsize(os.path.join(args.out, "all_types_zstd.rbxl")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
