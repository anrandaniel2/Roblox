class_name RBXLZ4
extends RefCounted
## Pure GDScript LZ4 block codec.
##
## Roblox stores most chunks of a `.rbxl` file as a raw LZ4 *block* (no frame,
## no checksum).  Godot's `Compression` singleton only implements FastLZ/Zstd/
## Gzip/Deflate, so the decoder lives here.
##
## The hot loop is written to use `PackedByteArray` bulk operations wherever the
## data allows it (literal runs are copied in one call), which keeps a 8 MiB
## place file down to roughly a second of import time on a phone.

const MIN_MATCH := 4
const MAX_MATCH := 65535 + MIN_MATCH
const HASH_LOG := 14
const HASH_SIZE := 1 << HASH_LOG


## Decompresses an LZ4 block.  `expected_size` is the size the block expands to.
##
## Output is built with `append_array`, so literal runs and (non overlapping)
## matches are copied by the engine's memcpy instead of byte by byte.
static func decompress(block: PackedByteArray, expected_size: int) -> PackedByteArray:
	var out := PackedByteArray()
	if expected_size <= 0:
		return out
	out.resize(0)
	var source_size := block.size()
	var source_index := 0
	while source_index < source_size:
		var token: int = block[source_index]
		source_index += 1
		# --- literals -----------------------------------------------------
		var literal_length := token >> 4
		if literal_length == 15:
			while source_index < source_size:
				var extra: int = block[source_index]
				source_index += 1
				literal_length += extra
				if extra != 255:
					break
		if literal_length > 0:
			if source_index + literal_length > source_size:
				push_error("LZ4 block is truncated while reading literals")
				break
			out.append_array(block.slice(source_index, source_index + literal_length))
			source_index += literal_length
		if source_index >= source_size:
			break
		# --- match --------------------------------------------------------
		if source_index + 2 > source_size:
			break
		var offset := int(block[source_index]) | (int(block[source_index + 1]) << 8)
		source_index += 2
		if offset <= 0 or offset > out.size():
			push_error("LZ4 block has an invalid match offset")
			break
		var match_length := token & 0x0F
		if match_length == 15:
			while source_index < source_size:
				var extra_match: int = block[source_index]
				source_index += 1
				match_length += extra_match
				if extra_match != 255:
					break
		match_length += MIN_MATCH
		var match_start := out.size() - offset
		if out.size() + match_length > expected_size:
			match_length = expected_size - out.size()
		while match_length > 0:
			# Overlapping matches are legal in LZ4: copy in offset sized pieces.
			var piece: int = mini(offset, match_length)
			out.append_array(out.slice(match_start, match_start + piece))
			match_start += piece
			match_length -= piece
	if out.size() != expected_size:
		push_warning("LZ4 block expanded to %d bytes, expected %d" % [out.size(), expected_size])
	return out


## Compresses a buffer into an LZ4 block.  Used by the place writer.
static func compress(data: PackedByteArray) -> PackedByteArray:
	var size := data.size()
	var out := PackedByteArray()
	if size == 0:
		return out
	var table := PackedInt32Array()
	table.resize(HASH_SIZE)
	table.fill(-1)
	var anchor := 0
	var index := 0
	var limit := size - MIN_MATCH - 1
	while index < limit:
		var slot := _hash(_read_u32(data, index))
		var candidate := table[slot]
		table[slot] = index
		if candidate >= 0 and index - candidate < 65536 and _matches(data, candidate, index):
			# Found a match: emit literals + match.
			var literal_length := index - anchor
			var match_index := index
			index += MIN_MATCH
			while index < size and data[index] == data[candidate + (index - match_index)] and (index - match_index) < MAX_MATCH:
				index += 1
			var match_length := index - match_index - MIN_MATCH
			_emit_sequence(out, literal_length, match_length, data, anchor, match_index - candidate)
			anchor = index
		else:
			index += 1
	# Trailing literals.
	_emit_last_literals(out, size - anchor, data, anchor)
	return out


static func _emit_sequence(out: PackedByteArray, literal_length: int, match_length: int, data: PackedByteArray, anchor: int, offset: int) -> void:
	var token_literal := mini(literal_length, 15)
	var token_match := mini(match_length, 15)
	out.append((token_literal << 4) | token_match)
	_emit_length(out, literal_length)
	if literal_length > 0:
		out.append_array(data.slice(anchor, anchor + literal_length))
	out.append(offset & 0xFF)
	out.append((offset >> 8) & 0xFF)
	_emit_length(out, match_length)


static func _emit_last_literals(out: PackedByteArray, literal_length: int, data: PackedByteArray, anchor: int) -> void:
	out.append(mini(literal_length, 15) << 4)
	_emit_length(out, literal_length)
	if literal_length > 0:
		out.append_array(data.slice(anchor, anchor + literal_length))


static func _emit_length(out: PackedByteArray, length: int) -> void:
	if length < 15:
		return
	var remaining := length - 15
	while remaining >= 255:
		out.append(255)
		remaining -= 255
	out.append(remaining)


static func _read_u32(data: PackedByteArray, index: int) -> int:
	return int(data[index]) | (int(data[index + 1]) << 8) | (int(data[index + 2]) << 16) | (int(data[index + 3]) << 24)


static func _hash(value: int) -> int:
	var mixed := (value * 2654435761) & 0xFFFFFFFF
	return ((mixed >> (32 - HASH_LOG)) ^ mixed) & (HASH_SIZE - 1)


static func _matches(data: PackedByteArray, a: int, b: int) -> bool:
	return data[a] == data[b] and data[a + 1] == data[b + 1] and data[a + 2] == data[b + 2] and data[a + 3] == data[b + 3]
