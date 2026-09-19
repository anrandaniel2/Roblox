extends Node
## Platform abstraction (`RbxPlatform` autoload).
##
## The emulator ships for desktop, Android/iOS and the web, and the three have
## very different ideas about file systems, windows and threads.  Everything
## that differs is funnelled through this node so the rest of the code base can
## stay platform agnostic.

signal files_selected(paths: PackedStringArray)

const LIBRARY_DIR := "user://places"

var _dialog: FileDialog = null
var _web_bridge: Node = null


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(LIBRARY_DIR)
	if is_web():
		_web_bridge = load("res://src/core/web_bridge.gd").new()
		_web_bridge.name = "WebBridge"
		add_child(_web_bridge)
	get_window().files_dropped.connect(_on_files_dropped)


func is_web() -> bool:
	return OS.has_feature("web")


func is_mobile() -> bool:
	return OS.has_feature("mobile")


func is_desktop() -> bool:
	return not is_web() and not is_mobile()


## Web builds without `thread_support` (the default in this project so it runs
## in any browser without SharedArrayBuffer) cannot use `Thread`.
func has_threads() -> bool:
	if is_web():
		return OS.has_feature("threads")
	return true


func supports_native_dialogs() -> bool:
	if is_web():
		return false
	return DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG) or is_desktop()


func device_name() -> String:
	var os_name := OS.get_name()
	if is_mobile():
		return "%s (%s)" % [os_name, DisplayServer.screen_get_size()]
	return os_name


## The display scale factor, used to grow the UI on high DPI phones.
func ui_scale() -> float:
	if not is_mobile():
		return 1.0
	var scale := DisplayServer.screen_get_scale(DisplayServer.SCREEN_OF_MAIN_WINDOW)
	return clampf(scale, 1.0, 2.5)


## Usable screen area (accounts for notches, cutouts and the status bar).
func safe_area() -> Rect2i:
	if not is_mobile():
		return Rect2i(Vector2i.ZERO, DisplayServer.window_get_size())
	return DisplayServer.get_display_safe_area()


func screen_size() -> Vector2i:
	return DisplayServer.window_get_size()


func library_dir() -> String:
	return LIBRARY_DIR


## Every place file inside the on device library, newest first.
func library_entries() -> Array:
	var entries: Array = []
	var dir := DirAccess.open(LIBRARY_DIR)
	if dir == null:
		return entries
	for file in dir.get_files():
		var lower := file.to_lower()
		if not (lower.ends_with(".rbxl") or lower.ends_with(".rbxlx") or lower.ends_with(".rbxm") or lower.ends_with(".rbxmx")):
			continue
		var path := LIBRARY_DIR.path_join(file)
		var size := 0
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			size = int(f.get_length())
		entries.append({
			"path": path,
			"name": file.get_basename(),
			"file": file,
			"size": size,
			"modified": FileAccess.get_modified_time(path),
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["modified"]) > int(b["modified"]))
	return entries


## Bundled example places (used by the demo browser and by tests).
func bundled_places() -> Array:
	var entries: Array = []
	var dir := DirAccess.open("res://fixtures")
	if dir == null:
		return entries
	for file in dir.get_files():
		if file.ends_with(".import"):
			continue
		var lower := file.to_lower()
		if not (lower.ends_with(".rbxl") or lower.ends_with(".rbxlx") or lower.ends_with(".rbxm") or lower.ends_with(".rbxmx")):
			continue
		entries.append({
			"path": "res://fixtures/" + file,
			"name": _prettify(file),
			"file": file,
			"size": 0,
			"modified": 0,
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["file"]) < String(b["file"]))
	return entries


func _prettify(file: String) -> String:
	var base := file.get_basename().replace("_", " ").replace("-", " ")
	var parts := base.split(" ", false)
	var out := PackedStringArray()
	for part in parts:
		out.append(part.substr(0, 1).to_upper() + part.substr(1))
	return " ".join(out)


## Copies an external file into the library so it can be reopened later.  On the
## web there is no real file system, so dropped/selected files are written into
## the emulator's virtual one.
func import_into_library(source_path: String, display_name: String = "") -> String:
	var source := FileAccess.open(source_path, FileAccess.READ)
	if source == null:
		RbxLog.error("Could not open '%s'." % source_path, "platform")
		return ""
	var file_name := display_name if not display_name.is_empty() else source_path.get_file()
	var target := LIBRARY_DIR.path_join(file_name)
	var destination := FileAccess.open(target, FileAccess.WRITE)
	if destination == null:
		RbxLog.error("Could not write to '%s'." % target, "platform")
		return ""
	destination.store_buffer(source.get_buffer(source.get_length()))
	destination.close()
	source.close()
	return target


func write_library_file(file_name: String, bytes: PackedByteArray) -> String:
	var target := LIBRARY_DIR.path_join(file_name)
	var destination := FileAccess.open(target, FileAccess.WRITE)
	if destination == null:
		RbxLog.error("Could not write '%s'." % target, "platform")
		return ""
	destination.store_buffer(bytes)
	destination.close()
	return target


func delete_library_file(path: String) -> bool:
	if not path.begins_with(LIBRARY_DIR):
		return false
	return DirAccess.remove_absolute(path) == OK


## Opens the platform file picker.  On the web this goes through JavaScript and
## hands the bytes of the picked file straight back.
func pick_files(file_name: String = "Places", extensions: PackedStringArray = PackedStringArray(["rbxl", "rbxlx", "rbxm", "rbxmx"])) -> void:
	if is_web() and _web_bridge != null:
		_web_bridge.pick_files(extensions, func(file_name_selected: String, bytes: PackedByteArray) -> void:
			var target := write_library_file(file_name_selected.get_file(), bytes)
			if not target.is_empty():
				files_selected.emit(PackedStringArray([target]))
		)
		return
	if _dialog == null or not is_instance_valid(_dialog):
		_dialog = FileDialog.new()
		_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_dialog.use_native_dialog = supports_native_dialogs()
		_dialog.title = "Open a Roblox place or model"
		_dialog.add_filter("*.rbxl,*.rbxlx,*.rbxm,*.rbxmx", "Roblox place / model")
		_dialog.add_filter("*.*", "All files")
		_dialog.size = Vector2i(900, 620)
		_dialog.file_selected.connect(func(path: String) -> void: files_selected.emit(PackedStringArray([path])))
		_dialog.files_selected.connect(func(paths: PackedStringArray) -> void: files_selected.emit(paths))
		get_tree().root.add_child(_dialog)
	_dialog.popup_centered()


func show_message(message: String, title: String = "Rbx Engine") -> void:
	var dialog := AcceptDialog.new()
	dialog.title = title
	dialog.dialog_text = message
	get_tree().root.add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()


## Nudge the browser to open `url` (used by the "help" buttons).
func open_url(url: String) -> void:
	if is_web() and _web_bridge != null:
		_web_bridge.open_url(url)
		return
	OS.shell_open(url)


func clipboard_set(text: String) -> void:
	DisplayServer.clipboard_set(text)


func vibrate(duration_ms: int = 40) -> void:
	if is_mobile():
		Input.vibrate_handheld(duration_ms)


func _on_files_dropped(paths: PackedStringArray) -> void:
	var kept := PackedStringArray()
	for path in paths:
		if path.to_lower().ends_with(".rbxl") or path.to_lower().ends_with(".rbxlx") \
				or path.to_lower().ends_with(".rbxm") or path.to_lower().ends_with(".rbxmx") \
				or path.to_lower().ends_with(".lua") or path.to_lower().ends_with(".luau"):
			kept.append(path)
	if not kept.is_empty():
		files_selected.emit(kept)
