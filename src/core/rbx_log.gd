extends Node
## Central log sink for the emulator.
##
## Everything the engine has to say goes through here: the importer, the Luau
## runtime, the physics session and the UI console.  Lines are kept in a small
## ring buffer so the in-game console can show them and, importantly, so a crash
## report can be copied off a phone without a debugger attached.
##
## Registered as the `RbxLog` autoload.

enum Level { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3 }

const MAX_LINES := 400
const LEVEL_NAMES: Array[String] = ["DEBUG", "INFO", "WARN", "ERROR"]
const LEVEL_COLORS: Array[Color] = [
	Color(0.62, 0.66, 0.75),
	Color(0.84, 0.88, 0.96),
	Color(1.0, 0.80, 0.35),
	Color(1.0, 0.45, 0.45),
]

## Emitted for every new line.  `entry` is `{ level, text, time, source }`.
signal line_added(entry: Dictionary)

var min_level: int = Level.DEBUG
var echo_to_stdout: bool = true

var _lines: Array[Dictionary] = []
var _counts: Array[int] = [0, 0, 0, 0]


func _ready() -> void:
	# Never clobber the user's console output, but keep the buffer tidy.
	set_process(false)


func clear() -> void:
	_lines.clear()
	_counts = [0, 0, 0, 0]
	line_added.emit({"level": Level.INFO, "text": "<cleared>", "time": Time.get_time_string_from_system(), "source": "log"})


func lines() -> Array[Dictionary]:
	return _lines


func lines_as_text() -> String:
	var out := PackedStringArray()
	for entry in _lines:
		out.append("[%s] %-5s %s" % [entry.get("time", ""), LEVEL_NAMES[int(entry.get("level", 1))], entry.get("text", "")])
	return "\n".join(out)


func counts() -> Dictionary:
	return {"debug": _counts[0], "info": _counts[1], "warn": _counts[2], "error": _counts[3]}


func debug(text: String, source: String = "engine") -> void:
	_write(Level.DEBUG, text, source)


func info(text: String, source: String = "engine") -> void:
	_write(Level.INFO, text, source)


func warn(text: String, source: String = "engine") -> void:
	_write(Level.WARN, text, source)


func error(text: String, source: String = "engine") -> void:
	_write(Level.ERROR, text, source)


func _write(level: int, text: String, source: String) -> void:
	if level < min_level:
		return
	_counts[level] += 1
	var entry := {
		"level": level,
		"text": text,
		"source": source,
		"time": Time.get_time_string_from_system(),
	}
	_lines.append(entry)
	if _lines.size() > MAX_LINES:
		_lines.remove_at(0)
	if echo_to_stdout:
		print("[%s] %-5s %s: %s" % [entry["time"], LEVEL_NAMES[level], source, text])
	line_added.emit(entry)
