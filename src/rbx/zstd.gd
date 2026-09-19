class_name RBXZstd
extends RefCounted
## Zstandard frames, decompressed with the zstd Godot already ships.
##
## Godot 4.7 removed the `Compression` class: the compression modes moved to
## `FileAccess` and the work is done by `PackedByteArray`.  That entry point
## (`decompress(buffer_size, mode)`) wants the final size up front, while Roblox
## writes its zstd frames with no content size in the frame header — so the size
## has to come from somewhere else.  The binary container's chunk header carries
## the uncompressed length, which is exactly what is needed; for a frame without
## that hint this falls back to guessing with a growing buffer.

## The four frame magic bytes, little endian in the file: `28 b5 2f fd`.
const MAGIC_0 := 0x28
const MAGIC_1 := 0xB5
const MAGIC_2 := 0x2F
const MAGIC_3 := 0xFD

const MIN_GUESS := 16 * 1024
const MAX_GUESS := 512 * 1024 * 1024


## True when `bytes` starts with a zstd frame magic at `offset`.
static func looks_like_zstd(bytes: PackedByteArray, offset: int = 0) -> bool:
	if offset + 4 > bytes.size():
		return false
	return bytes[offset] == MAGIC_0 and bytes[offset + 1] == MAGIC_1 \
		and bytes[offset + 2] == MAGIC_2 and bytes[offset + 3] == MAGIC_3


## Inflates one or more concatenated zstd frames.
##
## `expected` is the size the caller already knows (the chunk header's
## uncompressed length); pass `0` when it is unknown and the result is found by
## growing the destination buffer.  Returns an empty array when the data is not
## a zstd stream.
static func decompress(body: PackedByteArray, expected: int = 0) -> PackedByteArray:
	if body.is_empty() or not looks_like_zstd(body):
		return PackedByteArray()
	if expected > 0:
		# Exact size: zstd decompresses in one shot and Godot trims the buffer.
		var sized := body.decompress(expected, FileAccess.COMPRESSION_ZSTD)
		if sized.size() == expected:
			return sized
		return PackedByteArray()

	var guess := MIN_GUESS
	while guess <= MAX_GUESS:
		var grown := body.decompress(guess, FileAccess.COMPRESSION_ZSTD)
		if not grown.is_empty():
			return grown
		guess <<= 1
	return PackedByteArray()
