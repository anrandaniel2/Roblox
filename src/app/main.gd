extends Control
## The application shell: header, place picker, status line and the log drawer.
##
## The 3D view and the runtime panels (explorer, properties, touch controls) are
## added by later phases; this scene is what proves the project boots, the
## autoloads come up in order and a place can be opened on every platform.

const LEVEL_COLORS: Array[Color] = [
	Color(0.62, 0.66, 0.74),
	Color(0.86, 0.89, 0.94),
	Color(0.98, 0.78, 0.35),
	Color(0.98, 0.45, 0.42),
]

var _scale: float = 1.0
var _accent: Color = Color(0.31, 0.55, 1.0)

var _header_title: Label
var _place_label: Label
var _status_label: Label
var _progress: ProgressBar
var _log_panel: PanelContainer
var _log_view: RichTextLabel
var _home_panel: PanelContainer
var _demos_box: VBoxContainer
var _recent_box: VBoxContainer
var _place_view: RBXPlaceView


func _ready() -> void:
	_scale = clampf(RbxPlatform.ui_scale(), 0.85, 1.6)
	_accent = RbxSettings.accent_color()
	_build()
	_refresh_lists()

	RbxApp.place_loading.connect(_on_place_loading)
	RbxApp.place_loaded.connect(_on_place_loaded)
	RbxApp.place_failed.connect(_on_place_failed)
	RbxApp.place_closed.connect(_on_place_closed)
	RbxApp.busy_changed.connect(_on_busy_changed)
	RbxLog.line_added.connect(_on_log_line)
	for line in RbxLog.lines():
		_append_log_line(line)

	_set_status("Open a place to get started.")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_console"):
		_log_panel.visible = not _log_panel.visible
		accept_event()


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var background := ColorRect.new()
	background.color = Color(0.043, 0.055, 0.078)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var glow := ColorRect.new()
	glow.color = Color(_accent.r, _accent.g, _accent.b, 0.10)
	glow.anchor_right = 1.0
	glow.anchor_bottom = 0.28
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(glow)

	# The viewport sits behind the panels so the imported place is always the
	# backdrop; the panels themselves are what the player interacts with.
	_place_view = RBXPlaceView.new()
	_place_view.scene_built.connect(_on_scene_built)
	add_child(_place_view)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	var pad := int(round(22.0 * _scale))
	margin.add_theme_constant_override("margin_left", pad)
	margin.add_theme_constant_override("margin_right", pad)
	margin.add_theme_constant_override("margin_top", int(round(16.0 * _scale)))
	margin.add_theme_constant_override("margin_bottom", int(round(16.0 * _scale)))
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", int(round(12.0 * _scale)))
	margin.add_child(column)

	column.add_child(_build_header())
	column.add_child(_build_home())
	column.add_child(_build_footer())
	_log_panel = _build_log_panel()
	_log_panel.visible = false
	column.add_child(_log_panel)
	column.add_child(_spacer())


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(round(12.0 * _scale)))

	_header_title = _label("Rbx Engine", 30, Color(0.96, 0.97, 0.99))
	row.add_child(_header_title)

	var chip := _label("%s · %s" % [RbxPlatform.device_name(), RbxApp.quality_preset_name()], 12, Color(0.62, 0.66, 0.74))
	chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(chip)
	row.add_child(_spacer())

	var open_button := _button("Open")
	open_button.pressed.connect(func() -> void: RbxPlatform.pick_files())
	row.add_child(open_button)

	var home_button := _button("Library")
	home_button.pressed.connect(func() -> void: _toggle_home())
	row.add_child(home_button)

	var log_button := _button("Log")
	log_button.pressed.connect(func() -> void: _log_panel.visible = not _log_panel.visible)
	row.add_child(log_button)

	_place_label = _label("No place loaded", 14, Color(0.72, 0.76, 0.84))
	var wrapper := VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 2)
	wrapper.add_child(row)
	wrapper.add_child(_place_label)
	return wrapper


func _build_home() -> Control:
	_home_panel = PanelContainer.new()
	_home_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.086, 0.10, 0.14, 0.94), Color(1, 1, 1, 0.06)))

	var pad := MarginContainer.new()
	var inset := int(round(20.0 * _scale))
	pad.add_theme_constant_override("margin_left", inset)
	pad.add_theme_constant_override("margin_right", inset)
	pad.add_theme_constant_override("margin_top", inset)
	pad.add_theme_constant_override("margin_bottom", inset)
	_home_panel.add_child(pad)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", int(round(10.0 * _scale)))
	pad.add_child(column)

	column.add_child(_label("Open a Roblox place", 20, Color(0.94, 0.96, 0.99)))
	column.add_child(_label(
		"Binary .rbxl / .rbxm and XML .rbxlx / .rbxmx files. You can also drop a file onto the window.",
		13, Color(0.66, 0.70, 0.78)))

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", int(round(10.0 * _scale)))
	var open_button := _button("Open place file…", true)
	open_button.pressed.connect(func() -> void: RbxPlatform.pick_files())
	actions.add_child(open_button)
	var reload_button := _button("Reload")
	reload_button.pressed.connect(func() -> void: RbxApp.reload())
	actions.add_child(reload_button)
	var close_button := _button("Close")
	close_button.pressed.connect(func() -> void: RbxApp.close_place())
	actions.add_child(close_button)
	actions.add_child(_spacer())
	column.add_child(actions)

	column.add_child(_section_label("Bundled demos"))
	_demos_box = VBoxContainer.new()
	_demos_box.add_theme_constant_override("separation", int(round(6.0 * _scale)))
	column.add_child(_demos_box)

	column.add_child(_section_label("Recent"))
	_recent_box = VBoxContainer.new()
	_recent_box.add_theme_constant_override("separation", int(round(6.0 * _scale)))
	column.add_child(_recent_box)
	return _home_panel


func _build_footer() -> Control:
	var wrapper := VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", int(round(6.0 * _scale)))

	_status_label = _label("", 13, Color(0.70, 0.75, 0.84))

	_progress = ProgressBar.new()
	_progress.min_value = 0.0
	_progress.max_value = 1.0
	_progress.value = 0.0
	_progress.visible = false
	_progress.custom_minimum_size = Vector2(0, int(round(4.0 * _scale)))
	var fill := StyleBoxFlat.new()
	fill.bg_color = _accent
	fill.set_corner_radius_all(int(round(2.0 * _scale)))
	_progress.add_theme_stylebox_override("fill", fill)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.08)
	track.set_corner_radius_all(int(round(2.0 * _scale)))
	_progress.add_theme_stylebox_override("background", track)

	var hint := _label("Drop a file anywhere · F1 log", 11, Color(0.50, 0.55, 0.64))
	wrapper.add_child(_status_label)
	wrapper.add_child(_progress)
	wrapper.add_child(hint)
	return wrapper


func _build_log_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.05, 0.06, 0.09, 0.96), Color(1, 1, 1, 0.06)))
	panel.custom_minimum_size = Vector2(0, int(round(220.0 * _scale)))

	var pad := MarginContainer.new()
	var inset := int(round(14.0 * _scale))
	pad.add_theme_constant_override("margin_left", inset)
	pad.add_theme_constant_override("margin_right", inset)
	pad.add_theme_constant_override("margin_top", inset)
	pad.add_theme_constant_override("margin_bottom", inset)
	panel.add_child(pad)

	_log_view = RichTextLabel.new()
	_log_view.bbcode_enabled = true
	_log_view.scroll_following = true
	_log_view.selection_enabled = true
	_log_view.add_theme_font_size_override("normal_font_size", int(round(12.0 * _scale)))
	pad.add_child(_log_view)
	return panel


# ---------------------------------------------------------------------------
# Small widget helpers
# ---------------------------------------------------------------------------

func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", int(round(float(size) * _scale)))
	label.add_theme_color_override("font_color", color)
	return label


func _section_label(text: String) -> Label:
	var label := _label(text.to_upper(), 11, Color(0.52, 0.58, 0.68))
	label.add_theme_constant_override("line_spacing", 0)
	return label


func _button(text: String, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", int(round(14.0 * _scale)))
	button.custom_minimum_size = Vector2(0, int(round(38.0 * _scale)))

	var normal := StyleBoxFlat.new()
	normal.bg_color = _accent if primary else Color(1, 1, 1, 0.07)
	normal.set_corner_radius_all(int(round(7.0 * _scale)))
	normal.content_margin_left = 16.0 * _scale
	normal.content_margin_right = 16.0 * _scale
	normal.content_margin_top = 8.0 * _scale
	normal.content_margin_bottom = 8.0 * _scale

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = normal.bg_color.lightened(0.12)

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = normal.bg_color.darkened(0.14)

	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_color_override("font_color", Color(0.06, 0.07, 0.10) if primary else Color(0.90, 0.93, 0.97))
	return button


func _panel_style(color: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(int(round(10.0 * _scale)))
	style.border_color = border
	style.set_border_width_all(1)
	return style


func _spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return spacer


# ---------------------------------------------------------------------------
# Lists
# ---------------------------------------------------------------------------

func _refresh_lists() -> void:
	for child in _demos_box.get_children():
		child.queue_free()
	for child in _recent_box.get_children():
		child.queue_free()

	var demos: Array = RbxPlatform.bundled_places()
	if demos.is_empty():
		_demos_box.add_child(_label("No bundled files in res://fixtures.", 12, Color(0.55, 0.60, 0.68)))
	for entry: Dictionary in demos:
		_demos_box.add_child(_picker_row(entry))

	var entries: Array = RbxPlatform.library_entries()
	if entries.is_empty():
		_recent_box.add_child(_label("Nothing loaded yet.", 12, Color(0.55, 0.60, 0.68)))
	for entry: Dictionary in entries.slice(0, 5):
		_recent_box.add_child(_picker_row(entry))


func _picker_row(entry: Dictionary) -> Button:
	var display_name := String(entry.get("name", "Untitled"))
	var byte_size := int(entry.get("size", 0))
	var button := _button("%s%s" % [display_name, "  (%s)" % _human_size(byte_size) if byte_size > 0 else ""])
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.pressed.connect(func() -> void: RbxApp.open_entry(entry))
	return button


func _human_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.0f KiB" % (float(bytes) / 1024.0)
	return "%.1f MiB" % (float(bytes) / (1024.0 * 1024.0))


# ---------------------------------------------------------------------------
# Reacting to the application state
# ---------------------------------------------------------------------------

func _on_place_loading(path: String) -> void:
	_set_status("Loading %s…" % path.get_file())
	_progress.visible = true
	_progress.value = 0.35


func _on_place_loaded(place: RBXPlace) -> void:
	_progress.visible = false
	_place_label.text = "%s · %s · %d instances · %s" % [
		place.name,
		place.format,
		place.total_instances(),
		_human_size(place.file_size),
	]
	_set_status(RbxApp.describe_current())
	_home_panel.visible = false
	_refresh_lists()


func _on_place_failed(path: String, message: String) -> void:
	_progress.visible = false
	_place_label.text = "No place loaded"
	_set_status("%s — %s" % [path.get_file(), message])
	RbxPlatform.vibrate(60)


func _on_place_closed() -> void:
	_place_label.text = "No place loaded"
	_set_status("Place closed.")
	_home_panel.visible = true
	_refresh_lists()


func _toggle_home() -> void:
	_home_panel.visible = not _home_panel.visible


func _on_scene_built(stats: Dictionary) -> void:
	if stats.is_empty():
		return
	_set_status("%s · %d parts in the viewport" % [
		RbxApp.describe_current(), int(stats.get("parts", 0))])


func _on_busy_changed(busy: bool) -> void:
	_progress.visible = busy
	_progress.value = 0.5 if busy else 0.0


func _set_status(text: String) -> void:
	_status_label.text = text


# ---------------------------------------------------------------------------
# Log drawer
# ---------------------------------------------------------------------------

func _on_log_line(entry: Dictionary) -> void:
	_append_log_line(entry)


func _append_log_line(entry: Dictionary) -> void:
	if _log_view == null:
		return
	var level := int(entry.get("level", 1))
	var color: Color = LEVEL_COLORS[level] if level >= 0 and level < LEVEL_COLORS.size() else LEVEL_COLORS[1]
	_log_view.append_text("[color=#%s]%s %-4s[/color] [color=#8a93a6]%s[/color] %s\n" % [
		color.to_html(false),
		String(entry.get("time", "")),
		RbxLog.LEVEL_NAMES[level] if level >= 0 and level < RbxLog.LEVEL_NAMES.size() else "INFO",
		String(entry.get("source", "")),
		String(entry.get("text", "")).replace("[", "[lb]"),
	])
