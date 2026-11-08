@tool
extends Node

# Syncs project settings one at a time, so people keep their own editor plugins and paths.
# The server holds the shared copy and decides the order of changes, which is why everyone
# applies its broadcasts, including whoever made the change: that way two edits to one setting settle on the same value.

var network: Node

const STORE_PATH = "user://team_create_project_settings.dat"
const OVERRIDE_PATH = "res://override.cfg"
const SERVER_SCENE = "res://addons/team_create/server.tscn"
const FLUSH_DELAY = 0.3
const MAX_CHANGES_PER_MESSAGE = 1024
const MAX_VALUE_DEPTH = 8
const MAX_VALUE_BYTES = 65536
const INPUT_EVENT_KEY = "__tc_input_event"

# Anything not listed here stays local, including editor plugins, data paths and settings that load other files
const SYNCED_PREFIXES = [
	"input/", "layer_names/", "physics/", "display/", "rendering/", "audio/", "autoload/",
	"animation/", "navigation/", "gui/", "internationalization/", "application/boot_splash/"
]
const SYNCED_KEYS = [
	"application/config/name", "application/config/description", "application/config/icon", "application/run/main_scene"
]
# These need the editor restarted before they fully apply
const RESTART_PREFIXES = ["autoload/", "rendering/", "display/"]
const ALLOWED_INPUT_EVENTS = ["InputEventKey", "InputEventMouseButton", "InputEventJoypadButton", "InputEventJoypadMotion"]
const ALLOWED_VALUE_TYPES = [
	TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME,
	TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_RECT2, TYPE_RECT2I, TYPE_COLOR,
	TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY,
	TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY,
	TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY
]

var _store: Dictionary = {}
var _store_loaded = false
var _restart_pending = false

var _snapshot: Dictionary = {}
var _in_session = false
var _flush_timer = -1.0

func _ready():
	if network and network.get("is_standalone_server"):
		_load_store()
		_write_server_autoloads()
		return
	ProjectSettings.settings_changed.connect(_on_settings_changed)
	multiplayer.server_disconnected.connect(func(): _in_session = false)

func _process(delta):
	if _flush_timer < 0.0:
		return
	_flush_timer -= delta
	if _flush_timer < 0.0:
		_send_local_changes()

static func is_synced_key(key: String) -> bool:
	if key in SYNCED_KEYS:
		return true
	for prefix in SYNCED_PREFIXES:
		if key.begins_with(prefix):
			return true
	return false

# Objects never go over the network or into the store. Input events become plain dictionaries,
# and come back as a fixed list of classes with only their plain properties set.
static func _encode_value(value, depth: int = 0) -> Array:
	if depth > MAX_VALUE_DEPTH:
		return [false, null]
	match typeof(value):
		TYPE_OBJECT:
			if not (value is InputEvent) or not value.get_class() in ALLOWED_INPUT_EVENTS:
				return [false, null]
			var props = {}
			for name in _input_event_properties(value):
				props[name] = value.get(name)
			return [true, {INPUT_EVENT_KEY: value.get_class(), "props": props}]
		TYPE_ARRAY:
			var items = []
			for item in value:
				var encoded = _encode_value(item, depth + 1)
				if not encoded[0]:
					return [false, null]
				items.append(encoded[1])
			return [true, items]
		TYPE_DICTIONARY:
			var entries = {}
			for key in value:
				var encoded = _encode_value(value[key], depth + 1)
				if not encoded[0]:
					return [false, null]
				entries[key] = encoded[1]
			return [true, entries]
	return [typeof(value) in ALLOWED_VALUE_TYPES, value]

static func _decode_value(value):
	match typeof(value):
		TYPE_ARRAY:
			var items = []
			for item in value:
				items.append(_decode_value(item))
			return items
		TYPE_DICTIONARY:
			if value.has(INPUT_EVENT_KEY):
				var event = ClassDB.instantiate(value[INPUT_EVENT_KEY])
				for name in _input_event_properties(event):
					if value["props"].has(name):
						event.set(name, value["props"][name])
				return event
			var entries = {}
			for key in value:
				entries[key] = _decode_value(value[key])
			return entries
	return value

static func _input_event_properties(event: InputEvent) -> Array:
	var names = []
	for property in event.get_property_list():
		if property.usage & PROPERTY_USAGE_STORAGE and property.type != TYPE_OBJECT and property.name != "script" and not property.name.begins_with("resource_"):
			names.append(property.name)
	return names

# Checks a value that arrived from the network, in its encoded form
static func _is_valid_wire_value(value, depth: int = 0) -> bool:
	if depth > MAX_VALUE_DEPTH:
		return false
	match typeof(value):
		TYPE_ARRAY:
			for item in value:
				if not _is_valid_wire_value(item, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			if value.has(INPUT_EVENT_KEY):
				if value.size() != 2 or not value[INPUT_EVENT_KEY] is String or not value[INPUT_EVENT_KEY] in ALLOWED_INPUT_EVENTS:
					return false
				if not value.get("props") is Dictionary:
					return false
				for name in value["props"]:
					if not name is String or typeof(value["props"][name]) not in ALLOWED_VALUE_TYPES:
						return false
				return true
			for key in value:
				if typeof(key) not in ALLOWED_VALUE_TYPES or not _is_valid_wire_value(value[key], depth + 1):
					return false
			return true
	return typeof(value) in ALLOWED_VALUE_TYPES

func _is_valid_change(key: String, value) -> bool:
	if not is_synced_key(key) or key.contains("\n") or key.contains("="):
		return false
	if not _is_valid_wire_value(value) or var_to_bytes(value).size() > MAX_VALUE_BYTES:
		return false
	if key == "application/run/main_scene":
		return value is String and value != SERVER_SCENE
	if key.begins_with("autoload/"):
		return _is_valid_autoload(key.trim_prefix("autoload/"), value)
	return true

# The editor stores new autoloads by UID, which means nothing to a machine that hasn't imported the file yet
func _encode_setting(key: String, value) -> Array:
	var encoded = _encode_value(value)
	if encoded[0] and key.begins_with("autoload/") and encoded[1] is String:
		var uid = encoded[1].trim_prefix("*")
		if uid.begins_with("uid://") and ResourceUID.has_id(ResourceUID.text_to_id(uid)):
			encoded[1] = encoded[1].replace(uid, ResourceUID.get_id_path(ResourceUID.text_to_id(uid)))
	return encoded

func _is_valid_autoload(autoload_name: String, value) -> bool:
	var identifier = RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*$")
	if not identifier.search(autoload_name) or autoload_name.begins_with("TeamCreate") or ClassDB.class_exists(autoload_name):
		return false
	if not value is String or value.contains("\"") or value.contains("\n"):
		return false
	var path = value.trim_prefix("*")
	return path.get_extension() in ["gd", "tscn", "scn"] and network.file_sync._is_safe_path(path)

func _read_project_file() -> Dictionary:
	var settings = {}
	var config = ConfigFile.new()
	if config.load("res://project.godot") != OK:
		return settings
	for section in config.get_sections():
		for key in config.get_section_keys(section):
			var full_key = section + "/" + key
			if not is_synced_key(full_key):
				continue
			var encoded = _encode_setting(full_key, config.get_value(section, key))
			if encoded[0]:
				settings[full_key] = encoded[1]
	# The server's own project file points the main scene at the server. The game's is the earlier entry.
	if settings.get("application/run/main_scene") == SERVER_SCENE:
		settings.erase("application/run/main_scene")
		var entry_regex = RegEx.create_from_string('(?m)^run/main_scene="([^"]+)"')
		for m in entry_regex.search_all(FileAccess.get_file_as_string("res://project.godot")):
			if m.get_string(1) != SERVER_SCENE:
				settings["application/run/main_scene"] = m.get_string(1)
				break
	return settings

# Server side

func _load_store() -> void:
	if _store_loaded:
		return
	_store_loaded = true
	var file = FileAccess.open(STORE_PATH, FileAccess.READ)
	if file:
		var saved = file.get_var(false)
		file.close()
		if saved is Dictionary:
			_store = saved
			return
	_store = _read_project_file()
	_save_store()

func _save_store() -> void:
	var file = FileAccess.open(STORE_PATH, FileAccess.WRITE)
	if file:
		file.store_var(_store, false)
		file.close()

func send_state_to_peer(id: int) -> void:
	_load_store()
	rpc_id(id, "receive_settings_state", _store)

# A running server can't take on new autoloads: scripts using one won't compile until it restarts.
# project.godot may be read-only, so the differences go in override.cfg, which Godot reads at launch.
func _write_server_autoloads() -> void:
	var base = _read_project_file()
	var lines = []
	for key in _store:
		if key.begins_with("autoload/") and base.get(key) != _store[key]:
			lines.append(key.trim_prefix("autoload/") + "=" + var_to_str(_store[key]))
	for key in base:
		if key.begins_with("autoload/") and not _store.has(key):
			lines.append(key.trim_prefix("autoload/") + "=null")
	var text = "" if lines.is_empty() else "[autoload]\n\n" + "\n".join(lines) + "\n"
	var existing = FileAccess.get_file_as_string(OVERRIDE_PATH) if FileAccess.file_exists(OVERRIDE_PATH) else ""
	if text == existing:
		return
	if text == "":
		DirAccess.remove_absolute(OVERRIDE_PATH)
	else:
		var file = FileAccess.open(OVERRIDE_PATH, FileAccess.WRITE)
		if not file:
			printerr("Team Create: Couldn't write ", OVERRIDE_PATH)
			return
		file.store_string(text)
		file.close()
	_restart_pending = true

func on_peer_left() -> void:
	if _restart_pending and network.get("is_standalone_server") and multiplayer.get_peers().is_empty():
		_restart_pending = false
		network.tc_print("Everyone has left, restarting to apply autoload changes.")
		network.call_deferred("_deferred_restart")

@rpc("any_peer", "reliable")
func submit_setting_changes(changes: Dictionary, removed: PackedStringArray) -> void:
	if not network.is_server:
		return
	_handle_changes(changes, removed, multiplayer.get_remote_sender_id())

func _handle_changes(changes: Dictionary, removed: PackedStringArray, sender_id: int) -> void:
	_load_store()
	if changes.size() + removed.size() > MAX_CHANGES_PER_MESSAGE:
		printerr("Team Create: Ignored oversized settings change from peer ", sender_id)
		return
	var accepted_changes = {}
	var accepted_removed = PackedStringArray()
	for key in changes:
		if key is String and _is_valid_change(key, changes[key]):
			accepted_changes[key] = changes[key]
		else:
			printerr("Team Create: Rejected project setting from peer ", sender_id, ": ", key)
	for key in removed:
		if is_synced_key(key):
			accepted_removed.append(key)
		else:
			printerr("Team Create: Rejected project setting removal from peer ", sender_id, ": ", key)
	if accepted_changes.is_empty() and accepted_removed.is_empty():
		return

	var changed_autoloads = []
	for key in accepted_changes:
		_store[key] = accepted_changes[key]
		if key.begins_with("autoload/"):
			changed_autoloads.append(key.trim_prefix("autoload/"))
	for key in accepted_removed:
		_store.erase(key)
		if key.begins_with("autoload/"):
			changed_autoloads.append(key.trim_prefix("autoload/"))
	_save_store()

	rpc("apply_setting_changes", accepted_changes, accepted_removed, sender_id)
	if not network.get("is_standalone_server"):
		apply_setting_changes(accepted_changes, accepted_removed, sender_id)
	if not changed_autoloads.is_empty():
		_announce_autoload_change(changed_autoloads, sender_id)

func _announce_autoload_change(changed_autoloads: Array, sender_id: int) -> void:
	var username = network.peers[sender_id].get("username", "Someone") if network.peers.has(sender_id) else "Someone"
	var message = username + " changed autoloads: " + ", ".join(changed_autoloads) + "."
	if network.get("is_standalone_server"):
		_write_server_autoloads()
		if _restart_pending:
			message += " Scenes using them can't be saved on the server until it restarts, which happens once everyone has left."
	network.post_server_message(message)

# Client side

@rpc("authority", "reliable")
func receive_settings_state(state: Dictionary) -> void:
	var removed = PackedStringArray()
	for key in _read_project_file():
		if not state.has(key):
			removed.append(key)
	var changed = _apply(state, removed)
	_snapshot = _take_snapshot()
	_in_session = true
	if changed.size() > 0:
		network.tc_print("Team Create: Matched ", changed.size(), " project settings to the server.")
		_show_restart_hint(changed)

@rpc("authority", "reliable")
func apply_setting_changes(changes: Dictionary, removed: PackedStringArray, sender_id: int) -> void:
	var changed = _apply(changes, removed)
	for key in changed:
		_snapshot.erase(key)
	var current = _take_snapshot()
	for key in changed:
		if current.has(key):
			_snapshot[key] = current[key]
	if changed.is_empty() or sender_id == multiplayer.get_unique_id():
		return
	var username = network.peers[sender_id].get("username", "Someone") if network.peers.has(sender_id) else "Someone"
	network.tc_print(username, " changed project settings: ", ", ".join(changed))
	network.show_toast(username + " changed project settings", 0, "\n".join(changed))
	_show_restart_hint(changed)

func _apply(changes: Dictionary, removed: PackedStringArray) -> PackedStringArray:
	var changed = PackedStringArray()
	for key in changes:
		if not key is String or not _is_valid_change(key, changes[key]):
			printerr("Team Create: Rejected project setting from the server: ", key)
			continue
		if ProjectSettings.has_setting(key):
			var current = _encode_setting(key, ProjectSettings.get_setting(key))
			if current[0] and var_to_str(current[1]) == var_to_str(changes[key]):
				continue
		ProjectSettings.set_setting(key, _decode_value(changes[key]))
		changed.append(key)
	for key in removed:
		if not is_synced_key(key) or not ProjectSettings.has_setting(key):
			continue
		# Built-in settings go back to their default, and custom ones are removed
		if ProjectSettings.property_can_revert(key):
			ProjectSettings.set_setting(key, ProjectSettings.property_get_revert(key))
		else:
			ProjectSettings.set_setting(key, null)
		changed.append(key)
	if changed.size() > 0:
		if ProjectSettings.save() != OK:
			printerr("Team Create: Couldn't save project settings")
		_refresh_settings_dialog()
	return changed

# The settings dialog only rebuilds its Input Map list after edits made in the dialog itself
func _refresh_settings_dialog() -> void:
	var editor = network._get_editor_interface()
	var dialog = _find_node_of_class(editor.get_base_control(), "ProjectSettingsEditor") if editor else null
	if dialog and dialog.has_method("_update_action_map_editor"):
		dialog.call("_update_action_map_editor")

func _find_node_of_class(node: Node, target_class: String) -> Node:
	if node.get_class() == target_class:
		return node
	for child in node.get_children(true):
		var found = _find_node_of_class(child, target_class)
		if found:
			return found
	return null

func _show_restart_hint(changed: PackedStringArray) -> void:
	for key in changed:
		for prefix in RESTART_PREFIXES:
			if key.begins_with(prefix):
				network.show_toast("Restart the editor for the new project settings to fully apply", 1)
				return

func _take_snapshot() -> Dictionary:
	var keys = []
	for property in ProjectSettings.get_property_list():
		keys.append(property.name)
	# The editor leaves autoloads out of that list, so those come from the saved file
	for key in _read_project_file():
		if key.begins_with("autoload/"):
			keys.append(key)
	var snapshot = {}
	for key in keys:
		if is_synced_key(key) and ProjectSettings.has_setting(key):
			var encoded = _encode_setting(key, ProjectSettings.get_setting(key))
			if encoded[0]:
				snapshot[key] = var_to_str(encoded[1])
	return snapshot

func _on_settings_changed() -> void:
	_flush_timer = FLUSH_DELAY

func _send_local_changes() -> void:
	if not _in_session or not network.is_connected_to_session():
		return
	ProjectSettings.save()
	var current = _take_snapshot()
	var changes = {}
	var removed = PackedStringArray()
	for key in current:
		if _snapshot.get(key) != current[key]:
			var value = _encode_setting(key, ProjectSettings.get_setting(key))[1]
			if _is_valid_change(key, value):
				changes[key] = value
			else:
				network.tc_print("Team Create: This project setting can't be synced and stays on your machine: ", key)
	for key in _snapshot:
		if not current.has(key):
			removed.append(key)
	_snapshot = current
	if changes.is_empty() and removed.is_empty():
		return
	if network.is_server:
		_handle_changes(changes, removed, multiplayer.get_unique_id())
	else:
		rpc_id(1, "submit_setting_changes", changes, removed)
