extends Node
## RbxApp — the application object.
##
## Owns the loaded place and the load pipeline: files come from `RbxPlatform`
## (picker, drag & drop, library, bundled demos), parsing comes from
## `RBXFileLoader`, and the UI reacts to the signals here instead of doing the
## work itself. The scene importer hooks into `_finish_load()`.

signal place_loading(path: String)
signal place_loaded(place: RBXPlace)
signal place_failed(path: String, message: String)
signal place_closed()
signal busy_changed(busy: bool)

var current_place: RBXPlace = null
var busy: bool = false
var last_error: String = ""
var last_source: String = ""


func _ready() -> void:
	RbxSettings.apply_runtime()
	RbxPlatform.files_selected.connect(_on_files_selected)
	RbxLog.info("Rbx Engine %s on %s." % [
		str(ProjectSettings.get_setting("application/config/version", "1.0.0")),
		RbxPlatform.device_name(),
	], "app")
	RbxLog.info("Input: %s. Quality: %s." % [
		"touch" if RbxSettings.is_touch_device() else "mouse + keyboard",
		quality_preset_name(),
	], "app")


## Name of the quality preset that will actually be used on this device.
func quality_preset_name() -> String:
	var names := RbxSettings.QualityPreset.keys()
	var preset := RbxSettings.resolved_preset()
	if preset >= 0 and preset < names.size():
		return String(names[preset])
	return "AUTO"


## Loads a place from anywhere: `res://fixtures/...`, `user://places/...`, an
## absolute path from the file dialog, or a path handed over on the command line.
func open_path(path: String) -> void:
	if path.is_empty():
		return
	if not RBXFileLoader.is_supported(path):
		_fail(path, "Unsupported file type '.%s'. Expected .rbxl, .rbxlx, .rbxm or .rbxmx." % path.get_extension())
		return

	_set_busy(true)
	last_source = path
	place_loading.emit(path)
	RbxLog.info("Opening %s (%s)…" % [path.get_file(), _describe_size(path)], "app")
	var place := RBXFileLoader.load_file(path)
	_finish_load(place)


## Loads a place from memory — used by the web file picker, drag & drop on web
## and by tests, none of which have a real filesystem path to hand over.
func open_bytes(bytes: PackedByteArray, display_name: String = "Untitled", path: String = "") -> void:
	var source := path
	if source.is_empty():
		source = RbxPlatform.write_library_file(display_name.get_file(), bytes)
	_set_busy(true)
	last_source = source
	place_loading.emit(display_name)
	RbxLog.info("Opening %s (%s)…" % [display_name.get_file(), _human_size(bytes.size())], "app")
	var place := RBXFileLoader.parse_bytes(bytes, display_name.get_file(), source)
	_finish_load(place)


## Opens one entry of `RbxPlatform.bundled_places()` / `library_entries()`.
func open_entry(entry: Dictionary) -> void:
	open_path(String(entry.get("path", "")))


## Re-reads whatever was loaded last, which is what the UI's reload button does.
func reload() -> void:
	if last_source.is_empty():
		return
	if not FileAccess.file_exists(last_source):
		_fail(last_source, "The file is no longer there: %s" % last_source)
		return
	open_path(last_source)


func close_place() -> void:
	if current_place == null:
		return
	RbxLog.info("Closed %s." % current_place.name, "app")
	current_place = null
	last_error = ""
	place_closed.emit()


func is_loaded() -> bool:
	return current_place != null


## One-line description of what is currently open, for the title bar and logs.
func describe_current() -> String:
	if current_place == null:
		return "No place loaded"
	return "%s — %d instances" % [current_place.name, current_place.total_instances()]


func _finish_load(place: RBXPlace) -> void:
	_set_busy(false)
	if not place.load_error.is_empty():
		_fail(place.path if not place.path.is_empty() else place.name, place.load_error)
		return

	current_place = place
	last_error = ""
	for warning in place.warnings:
		RbxLog.warn(warning, "importer")
	if not place.path.is_empty():
		RbxSettings.add_recent(place.path, place.name)
	RbxLog.info(place.summary(), "importer")
	if place.renderable_count() > 0:
		RbxLog.info("%d renderable instances across %d root nodes." % [
			place.renderable_count(), place.roots.size(),
		], "importer")
	place_loaded.emit(place)


func _fail(path: String, message: String) -> void:
	_set_busy(false)
	last_error = message
	RbxLog.error(message, "app")
	place_failed.emit(path, message)


func _set_busy(value: bool) -> void:
	if busy == value:
		return
	busy = value
	busy_changed.emit(busy)


func _on_files_selected(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	open_path(paths[0])


func _describe_size(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "unknown size"
	var size := int(file.get_length())
	file.close()
	return _human_size(size)


func _human_size(bytes: int) -> String:
	if bytes <= 0:
		return "0 B"
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.1f KiB" % (float(bytes) / 1024.0)
	return "%.1f MiB" % (float(bytes) / (1024.0 * 1024.0))
