class_name RBXFileLoader
extends RefCounted
## Entry point for reading Roblox place and model files.
##
## Sniffs the container format (binary, XML, gzip) so callers can accept any of
## `.rbxl`, `.rbxlx`, `.rbxm`, `.rbxmx` without caring which is which, and turns
## anything unexpected into a readable error instead of a crash.

const SUPPORTED_EXTENSIONS := ["rbxl", "rbxlx", "rbxm", "rbxmx"]


static func is_supported(path: String) -> bool:
	return SUPPORTED_EXTENSIONS.has(path.get_extension().to_lower())


## Detects the container format from the file's first bytes.
static func detect_format(bytes: PackedByteArray) -> String:
	if bytes.size() >= 8:
		var head := bytes.slice(0, 8).get_string_from_utf8()
		if head == "<roblox!":
			return "binary"
		if bytes.size() >= 2 and bytes[0] == 0x1F and bytes[1] == 0x8B:
			return "gzip"
	# Some files start with a byte order mark or whitespace before `<roblox`.
	var prefix := bytes.slice(0, mini(bytes.size(), 512)).get_string_from_utf8()
	if prefix.contains("<roblox"):
		return "xml"
	return "unknown"


static func load_file(path: String) -> RBXPlace:
	var place := RBXPlace.new()
	place.path = path
	place.name = path.get_file().get_basename()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		place.load_error = "Could not open '%s' (%s)." % [path, error_string(FileAccess.get_open_error())]
		return place
	var bytes := file.get_buffer(file.get_length())
	file.close()
	place.file_size = bytes.size()
	return parse_bytes(bytes, place.name, path, place)


## Parses an in-memory buffer (used by the web file picker, drag & drop and tests).
static func parse_bytes(bytes: PackedByteArray, display_name: String = "Untitled", path: String = "", place: RBXPlace = null) -> RBXPlace:
	if place == null:
		place = RBXPlace.new()
	place.name = display_name
	place.path = path
	place.file_size = bytes.size()
	if bytes.is_empty():
		place.load_error = "The file is empty."
		return place

	var format := detect_format(bytes)
	if format == "gzip":
		var decompressed := Compression.decompress(bytes, Compression.MODE_GZIP)
		if decompressed.is_empty():
			place.load_error = "Could not decompress the gzip container."
			return place
		bytes = decompressed
		format = detect_format(bytes)

	place.format = format
	var started := Time.get_ticks_msec()
	match format:
		"binary":
			var reader := RBXBinaryReader.new()
			if not reader.parse(bytes, place):
				place.load_error = "This is not a readable Roblox binary model."
		"xml":
			var xml_reader := RBXXmlReader.new()
			if not xml_reader.parse(bytes, place):
				place.load_error = "This is not a readable Roblox XML model."
		_:
			place.load_error = "Unknown file format. Expected a .rbxl/.rbxlx/.rbxm/.rbxmx file."
	place.stats["parse_ms"] = Time.get_ticks_msec() - started
	place.stats["bytes"] = bytes.size()
	if place.load_error.is_empty() and place.roots.is_empty():
		place.load_error = "The file parsed but contains no instances."
	if place.load_error.is_empty():
		RbxLog.info("Parsed %s (%s) with %d instances in %d ms." % [
			place.name, place.format, place.total_instances(), place.stats["parse_ms"]
		], "importer")
	return place


## Saves a place back out.  Currently only the XML and uncompressed binary
## containers are written, see `RBXPlaceWriter`.
static func save_file(place: RBXPlace, path: String) -> String:
	var writer := load("res://src/rbx/place_writer.gd")
	if writer == null:
		return "Place writing is not available in this build."
	return writer.new().write_place(place, path)
