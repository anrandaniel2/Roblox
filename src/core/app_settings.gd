extends Node
## Persistent, platform aware settings for the emulator (`RbxSettings` autoload).
##
## Everything that a phone owner might reasonably want to change lives here:
## the renderer quality preset, touch control layout, importer limits (a 300k
## part place will not run on a mid range phone, so we cap and merge instead of
## freezing) and the scripting sandbox switches.
##
## Settings are stored in `user://settings.cfg`, which works on desktop, Android,
## iOS and in the browser (IndexedDB backed filesystem).

const CONFIG_PATH := "user://settings.cfg"
const CONFIG_VERSION := 2

signal changed(key: String, value: Variant)

enum QualityPreset { AUTO, LOW, MEDIUM, HIGH, ULTRA }

## Renderer quality.
var quality_preset: int = QualityPreset.AUTO
var max_fps: int = 0
var vsync: bool = true
var shadows: bool = true
var shadow_atlas_size: int = 2048
var msaa: int = 2 # 0 = off, 1 = 2x, 2 = 4x, 3 = 8x
var draw_distance: float = 2048.0
var fog_enabled: bool = true
var viewport_scale: float = 1.0
var texture_quality: int = 2 # 0 = low, 1 = medium, 2 = high

## Camera & movement.
var fov: float = 70.0
var camera_sensitivity_mouse: float = 0.25
var camera_sensitivity_touch: float = 0.35
var invert_y: bool = false
var shift_lock: bool = false
var walk_speed_multiplier: float = 1.0

## Touch controls.
var touch_mode: String = "auto" # auto | always | never
var joystick_side: String = "left" # left | right
var touch_opacity: float = 0.55
var touch_scale: float = 1.0
var joystick_size: float = 168.0
var jump_button_size: float = 92.0
var touch_camera_drag: bool = true

## Importer limits (this is what keeps big places playable on phones).
var max_instances: int = 250000
var build_collision: bool = true
var collision_mode: String = "all" # all | near_spawn | none
var collision_radius: float = 1200.0
var simulate_unanchored: bool = true
var max_dynamic_bodies: int = 96
var load_gui: bool = true
var load_decals: bool = true
var instances_per_frame: int = 900
var import_timeout_seconds: float = 60.0

## Scripting.
var scripting_enabled: bool = true
var scripting_sandbox: bool = true
var script_steps_per_frame: int = 200000
var script_print_to_console: bool = true

## Interface.
var ui_scale: float = 1.0
var accent: String = "blue" # blue | violet | emerald | amber | rose
var show_fps: bool = true
var show_stats: bool = true
var developer_mode: bool = false
var recent_places: Array = []

const ACCENTS := {
	"blue": Color(0.31, 0.55, 1.0),
	"violet": Color(0.55, 0.36, 1.0),
	"emerald": Color(0.15, 0.78, 0.55),
	"amber": Color(1.0, 0.65, 0.20),
	"rose": Color(1.0, 0.33, 0.45),
}

var _config := ConfigFile.new()
var _loaded := false


func _ready() -> void:
	load_settings()
	if OS.has_feature("mobile"):
		quality_preset = QualityPreset.AUTO
		ui_scale = clampf(ui_scale, 0.9, 1.6)


func accent_color() -> Color:
	return ACCENTS.get(accent, ACCENTS["blue"])


func is_touch_device() -> bool:
	if touch_mode == "always":
		return true
	if touch_mode == "never":
		return false
	return DisplayServer.is_touchscreen_available() or OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")


func resolved_preset() -> int:
	if quality_preset != QualityPreset.AUTO:
		return quality_preset
	if OS.has_feature("mobile"):
		return QualityPreset.MEDIUM
	if OS.has_feature("web"):
		return QualityPreset.MEDIUM
	return QualityPreset.HIGH


func apply_preset(preset: int) -> void:
	match preset:
		QualityPreset.LOW:
			shadows = false
			shadow_atlas_size = 1024
			msaa = 0
			draw_distance = 1024.0
			fog_enabled = false
			viewport_scale = 0.85
			texture_quality = 0
			max_fps = 45
			max_dynamic_bodies = 32
			instances_per_frame = 600
		QualityPreset.MEDIUM:
			shadows = true
			shadow_atlas_size = 2048
			msaa = 1
			draw_distance = 2048.0
			fog_enabled = true
			viewport_scale = 1.0
			texture_quality = 1
			max_fps = 60
			max_dynamic_bodies = 96
			instances_per_frame = 900
		QualityPreset.HIGH:
			shadows = true
			shadow_atlas_size = 4096
			msaa = 2
			draw_distance = 4096.0
			fog_enabled = true
			viewport_scale = 1.0
			texture_quality = 2
			max_fps = 0
			max_dynamic_bodies = 256
			instances_per_frame = 1500
		QualityPreset.ULTRA:
			shadows = true
			shadow_atlas_size = 4096
			msaa = 3
			draw_distance = 8192.0
			fog_enabled = true
			viewport_scale = 1.0
			texture_quality = 2
			max_fps = 0
			max_dynamic_bodies = 512
			instances_per_frame = 2400


## Applies everything that can be changed while the game is running.
func apply_runtime() -> void:
	if max_fps > 0:
		Engine.max_fps = max_fps
	else:
		Engine.max_fps = 0
	RenderingServer.directional_shadow_atlas_set_size(shadow_atlas_size, true)


func get_value(key: String, fallback: Variant = null) -> Variant:
	return get(key) if key in self else fallback


func set_value(key: String, value: Variant, save_now: bool = true) -> void:
	if not (key in self):
		return
	set(key, value)
	changed.emit(key, value)
	if save_now:
		save_settings()


func set_touch_mode(mode: String) -> void:
	set_value("touch_mode", mode)


func set_accent(name: String) -> void:
	set_value("accent", name)


func add_recent(path: String, display_name: String = "") -> void:
	var entry := {
		"path": path,
		"name": display_name if not display_name.is_empty() else path.get_file(),
		"time": Time.get_unix_time_from_system(),
	}
	var filtered: Array = []
	for item in recent_places:
		if item is Dictionary and item.get("path", "") != path:
			filtered.append(item)
	filtered.insert(0, entry)
	if filtered.size() > 12:
		filtered.resize(12)
	recent_places = filtered
	save_settings()


func load_settings() -> void:
	_loaded = true
	if not FileAccess.file_exists(CONFIG_PATH):
		apply_preset(resolved_preset())
		save_settings()
		return
	var err := _config.load(CONFIG_PATH)
	if err != OK:
		RbxLog.warn("Could not read %s (error %d), using defaults." % [CONFIG_PATH, err], "settings")
		return
	for key in _config.get_section_keys("settings"):
		if key in self:
			set(key, _config.get_value("settings", key))
	if int(_config.get_value("meta", "version", 0)) < CONFIG_VERSION:
		apply_preset(resolved_preset())
		save_settings()


func save_settings() -> void:
	if not _loaded:
		return
	for key in _known_keys():
		_config.set_value("settings", key, get(key))
	_config.set_value("meta", "version", CONFIG_VERSION)
	var err := _config.save(CONFIG_PATH)
	if err != OK:
		RbxLog.warn("Could not save settings (error %d)." % err, "settings")


func _known_keys() -> PackedStringArray:
	return PackedStringArray([
		"quality_preset", "max_fps", "vsync", "shadows", "shadow_atlas_size", "msaa",
		"draw_distance", "fog_enabled", "viewport_scale", "texture_quality",
		"fov", "camera_sensitivity_mouse", "camera_sensitivity_touch", "invert_y",
		"shift_lock", "walk_speed_multiplier",
		"touch_mode", "joystick_side", "touch_opacity", "touch_scale", "joystick_size",
		"jump_button_size", "touch_camera_drag",
		"max_instances", "build_collision", "collision_mode", "collision_radius",
		"simulate_unanchored", "max_dynamic_bodies", "load_gui", "load_decals",
		"instances_per_frame", "import_timeout_seconds",
		"scripting_enabled", "scripting_sandbox", "script_steps_per_frame", "script_print_to_console",
		"ui_scale", "accent", "show_fps", "show_stats", "developer_mode", "recent_places",
	])


func reset_to_defaults() -> void:
	quality_preset = QualityPreset.AUTO
	max_fps = 0
	vsync = true
	msaa = 2
	draw_distance = 2048.0
	fog_enabled = true
	viewport_scale = 1.0
	texture_quality = 2
	fov = 70.0
	camera_sensitivity_mouse = 0.25
	camera_sensitivity_touch = 0.35
	invert_y = false
	shift_lock = false
	walk_speed_multiplier = 1.0
	touch_mode = "auto"
	joystick_side = "left"
	touch_opacity = 0.55
	touch_scale = 1.0
	joystick_size = 168.0
	jump_button_size = 92.0
	touch_camera_drag = true
	max_instances = 250000
	build_collision = true
	collision_mode = "all"
	collision_radius = 1200.0
	simulate_unanchored = true
	max_dynamic_bodies = 96
	load_gui = true
	load_decals = true
	instances_per_frame = 900
	import_timeout_seconds = 60.0
	scripting_enabled = true
	scripting_sandbox = true
	script_steps_per_frame = 200000
	script_print_to_console = true
	ui_scale = 1.0
	accent = "blue"
	show_fps = true
	show_stats = true
	developer_mode = false
	apply_preset(resolved_preset())
	save_settings()
