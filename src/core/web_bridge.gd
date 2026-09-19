extends Node
## Browser-only bridge.
##
## `RbxPlatform` instantiates this when the project runs as a web build. On
## desktop and mobile it is never created, so everything here can assume a
## browser environment — but every entry point still checks, and all JavaScript
## access goes through `Engine.get_singleton("JavaScriptBridge")` instead of the
## `JavaScriptBridge` global, so this file also compiles on platforms where that
## singleton does not exist.

const JS_SINGLETON := "JavaScriptBridge"

var _callback: Callable = Callable()
var _bridge: Object = null


func _ready() -> void:
	_bridge = Engine.get_singleton(JS_SINGLETON)


## Opens the browser's file picker and hands the chosen file's bytes back.
func pick_files(extensions: PackedStringArray, on_selected: Callable) -> void:
	if not _available():
		RbxLog.warn("The browser file picker is unavailable in this build.", "platform")
		return

	_callback = on_selected
	var accept := ""
	if not extensions.is_empty():
		accept = "." + ",".join(extensions)

	# A real <input type=file> is the only way to read a local file in a browser.
	# It is kept off-screen, and the GDScript callable is parked on a window
	# global because the injected script cannot hold a Godot reference.
	var window: Variant = _bridge.call("get_interface", "window")
	if window == null:
		RbxLog.warn("The browser window interface is unavailable.", "platform")
		return
	window.set("__rbxFilePicked", _bridge.call("create_callback", _on_file_picked))

	var script := """
(function (accept) {
	var input = document.createElement('input');
	input.type = 'file';
	input.accept = accept;
	input.style.position = 'fixed';
	input.style.left = '-1000px';
	document.body.appendChild(input);
	input.addEventListener('change', function () {
		var file = input.files && input.files[0];
		document.body.removeChild(input);
		if (!file) { return; }
		var reader = new FileReader();
		reader.onload = function () {
			window.__rbxFilePicked([file.name, new Uint8Array(reader.result)]);
		};
		reader.readAsArrayBuffer(file);
	});
	input.click();
})(%s);
""" % JSON.stringify(accept)

	_bridge.call("eval", script, true)


## Opens a URL in a new browser tab.
func open_url(url: String) -> void:
	if not _available():
		return
	var window: Variant = _bridge.call("get_interface", "window")
	if window == null:
		RbxLog.warn("The browser window interface is unavailable.", "platform")
		return
	window.call("open", url, "_blank")


## True when the project really is running in a browser with the JS bridge.
func _available() -> bool:
	if _bridge == null:
		_bridge = Engine.get_singleton(JS_SINGLETON)
	return _bridge != null


## Called from JavaScript as `__rbxFilePicked([name, bytes])`: the bridge always
## hands the arguments over as one array, and typed arrays arrive as bytes.
func _on_file_picked(arguments: Array) -> void:
	if arguments.size() < 2 or not _callback.is_valid():
		return
	var file_name := String(arguments[0])
	var bytes := PackedByteArray()
	var payload: Variant = arguments[1]
	if payload is PackedByteArray:
		bytes = payload
	elif payload is Array:
		bytes = PackedByteArray(payload)
	_callback.call(file_name, bytes)
