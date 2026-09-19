class_name RBXByteReader
extends RefCounted
## Byte level cursor over a `PackedByteArray` with the primitives the Roblox
## binary model format needs.
##
## Scalar reads are done with explicit shift arithmetic instead of relying on
## platform endianness.  Array reads de-interleave into a temporary buffer and
## hand it to Godot's vectorised `Packed*Array` conversions, which is what keeps
## big place files fast enough to import on a phone.
##
## Reference: https://github.com/rojo-rbx/rbx-dom/blob/master/docs/binary.md

var data: PackedByteArray
var pos: int = 0
var limit: int = 0

## Set when a read runs past the end of the buffer.  Callers can finish early
## instead of erroring out on slightly truncated files.
var truncated: bool = false


func _init(buffer: PackedByteArray = PackedByteArray(), start: int = 0, length: int = -1) -> void:
	assign(buffer, start, length)


func assign(buffer: PackedByteArray, start: int = 0, length: int = -1) -> void:
	data = buffer
	pos = start
	if length < 0:
		limit = buffer.size()
	else:
		limit = mini(buffer.size(), start + length)
	truncated = false


func remaining() -> int:
	return limit - pos


func eof() -> bool:
	return pos >= limit


func has(count: int) -> bool:
	return remaining() >= count


func skip(count: int) -> void:
	var next := pos + count
	if next > limit:
		truncated = true
		pos = limit
		return
	pos = next


func seek(target: int) -> void:
	pos = clampi(target, 0, limit)


## Reads `count` raw bytes.
func take(count: int) -> PackedByteArray:
	if count <= 0:
		return PackedByteArray()
	var end := pos + count
	if end > limit:
		truncated = true
		var partial := data.slice(pos, limit)
		pos = limit
		return partial
	var slice := data.slice(pos, end)
	pos = end
	return slice


func u8() -> int:
	if pos >= limit:
		truncated = true
		return 0
	var value := int(data[pos])
	pos += 1
	return value


func i8() -> int:
	var value := u8()
	return value - 256 if value > 127 else value


func u16_le() -> int:
	if not has(2):
		return _fail_int(2)
	var value := int(data[pos]) | (int(data[pos + 1]) << 8)
	pos += 2
	return value


func u32_le() -> int:
	if not has(4):
		return _fail_int(4)
	var value := int(data[pos]) | (int(data[pos + 1]) << 8) | (int(data[pos + 2]) << 16) | (int(data[pos + 3]) << 24)
	pos += 4
	return value


func i32_le() -> int:
	var value := u32_le()
	return value - 4294967296 if value >= 2147483648 else value


func u32_be() -> int:
	if not has(4):
		return _fail_int(4)
	var value := (int(data[pos]) << 24) | (int(data[pos + 1]) << 16) | (int(data[pos + 2]) << 8) | int(data[pos + 3])
	pos += 4
	return value


func i64_le() -> int:
	if not has(8):
		return _fail_int(8)
	var value := 0
	for index in 8:
		value |= int(data[pos + index]) << (8 * index)
	pos += 8
	return value


func f32_le() -> float:
	if not has(4):
		_fail_int(4)
		return 0.0
	var value: float = data.slice(pos, pos + 4).to_float32_array()[0]
	pos += 4
	return value


func f64_le() -> float:
	if not has(8):
		_fail_int(8)
		return 0.0
	var value: float = data.slice(pos, pos + 8).to_float64_array()[0]
	pos += 8
	return value


## Roblox stores most 32 bit floats big endian with the sign bit moved to the end
## of the word.  See "Roblox Float Format" in the binary format documentation.
func roblox_f32() -> float:
	var raw := u32_be()
	var bits := ((raw >> 1) | ((raw & 1) << 31)) & 0xFFFFFFFF
	var buffer := PackedByteArray()
	buffer.resize(4)
	buffer[0] = bits & 0xFF
	buffer[1] = (bits >> 8) & 0xFF
	buffer[2] = (bits >> 16) & 0xFF
	buffer[3] = (bits >> 24) & 0xFF
	return buffer.to_float32_array()[0]


## Length prefixed UTF-8 string (`u32` length in bytes).
func string_utf8() -> String:
	var length := u32_le()
	if length <= 0:
		return ""
	var bytes := take(length)
	if bytes.size() != length:
		truncated = true
	return bytes.get_string_from_utf8()


## Raw, still interleaved bytes of `count` values of `width` bytes each.
func raw_values(count: int, width: int) -> PackedByteArray:
	return take(count * width)


## De-interleaves `count` values of `width` bytes into little endian element
## order, ready for Godot's `to_*_array()` helpers.
func deinterleave_le(count: int, width: int) -> PackedByteArray:
	var out := PackedByteArray()
	if count <= 0:
		return out
	var raw := take(count * width)
	out.resize(count * width)
	if raw.size() < count * width:
		truncated = true
	for element in count:
		var target := element * width
		for byte_index in width:
			# Big endian on disk, little endian in the output buffer.
			out[target + byte_index] = raw[(width - 1 - byte_index) * count + element]
	return out


## `count` transformed, big endian 32 bit integers.
func read_i32_array(count: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	if count <= 0:
		return out
	var raw := deinterleave_le(count, 4).to_int32_array()
	out.resize(count)
	for index in count:
		out[index] = untransform32(raw[index])
	return out


## `count` referents: transformed big endian 32 bit integers stored as deltas.
##
## The spec is explicit about this one — "when reading an array of Referent
## values, they must be read accumulatively; the actual value is the read value
## plus the preceding one" — and reading them as plain integers collapses most
## of the file into a handful of referents, which is exactly what a 1001
## instance fixture looked like (2 instances, 2 roots).
func read_referent_array(count: int) -> PackedInt64Array:
	var out := read_i32_array(count)
	var total := 0
	for index in out.size():
		total += int(out[index])
		out[index] = total
	return out


## `count` raw (not transformed) big endian 32 bit integers.
func read_u32_array(count: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	if count <= 0:
		return out
	var raw := deinterleave_le(count, 4).to_int32_array()
	out.resize(count)
	for index in count:
		out[index] = raw[index] & 0xFFFFFFFF
	return out


## `count` transformed, big endian 64 bit integers.
func read_i64_array(count: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	if count <= 0:
		return out
	var raw := deinterleave_le(count, 8).to_int64_array()
	out.resize(count)
	for index in count:
		out[index] = (raw[index] >> 1) ^ -(raw[index] & 1)
	return out


## `count` big endian 64 bit values, kept unsigned.
func read_u64_array(count: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	if count <= 0:
		return out
	var raw := deinterleave_le(count, 8).to_int64_array()
	out.resize(count)
	for index in count:
		out[index] = raw[index]
	return out


## `count` floats in the Roblox on-disk format (rotated sign bit, big endian).
func read_roblox_f32_array(count: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if count <= 0:
		return out
	var raw := take(count * 4)
	if raw.size() < count * 4:
		truncated = true
		count = raw.size() >> 2
		out.resize(count)
		return out
	var ordered := PackedByteArray()
	ordered.resize(count * 4)
	for element in count:
		var bits := (int(raw[element]) << 24) \
			| (int(raw[count + element]) << 16) \
			| (int(raw[count * 2 + element]) << 8) \
			| int(raw[count * 3 + element])
		var rotated := ((bits >> 1) | ((bits & 1) << 31)) & 0xFFFFFFFF
		var target := element * 4
		ordered[target] = rotated & 0xFF
		ordered[target + 1] = (rotated >> 8) & 0xFF
		ordered[target + 2] = (rotated >> 16) & 0xFF
		ordered[target + 3] = (rotated >> 24) & 0xFF
	return ordered.to_float32_array()


## `count` little endian doubles stored back to back.
func read_f64_array(count: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	if count <= 0:
		return out
	var bytes := take(count * 8)
	if bytes.size() < count * 8:
		truncated = true
		return out
	return bytes.to_float64_array()


## `count` little endian 16 bit integers (stored back to back) widened to 32 bit.
func read_i16_array(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if count <= 0:
		return out
	var bytes := take(count * 2)
	out.resize(count)
	if bytes.size() < count * 2:
		truncated = true
		count = bytes.size() >> 1
		out.resize(count)
	for index in count:
		var raw := int(bytes[index * 2]) | (int(bytes[index * 2 + 1]) << 8)
		out[index] = raw - 65536 if raw > 32767 else raw
	return out


static func untransform32(value: int) -> int:
	## Undoes the integer transformation Roblox applies to signed integers.
	var unsigned := value & 0xFFFFFFFF
	return (unsigned >> 1) ^ -(unsigned & 1)


static func transform32(value: int) -> int:
	return (value << 1) ^ (value >> 31)


static func transform64(value: int) -> int:
	return ((value << 1) ^ (value >> 63)) & 0xFFFFFFFFFFFFFFFF


func _fail_int(_count: int) -> int:
	truncated = true
	pos = limit
	return 0
