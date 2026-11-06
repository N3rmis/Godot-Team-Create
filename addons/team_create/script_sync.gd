@tool
extends Node

## Team Create - Collaborative Script Synchronization & Presence
## Real-time collaborative code editing with 100ms debounced line diffs,
## live presence carets, collaborator name badges, and selection highlighting.

const DIFF_DEBOUNCE_DELAY: float = 0.100      # 100ms debounced diff sync
const SCRIPT_AUTO_SAVE_INTERVAL: float = 15.0 # Save dirty server script buffers every 15s

var network: Node

# Editor references (Client only)
var _tracked_editors: Dictionary = {}    # script_path -> CodeEdit
var _active_script_path: String = ""      # Currently focused script in editor
var _overlays: Dictionary = {}           # script_path -> ScriptPresenceOverlay

# Text synchronization state
var _synced_lines: Dictionary = {}       # script_path -> PackedStringArray
var _script_revisions: Dictionary = {}   # script_path -> int
var _diff_timers: Dictionary = {}        # script_path -> float
var _dirty_scripts: Dictionary = {}       # script_path -> bool
var _applying_remote_depth: int = 0       # Suppress local diffs during remote updates

# Server text buffers (Headless / Host persistence)
var _server_script_buffers: Dictionary = {} # script_path -> PackedStringArray
var _server_script_revisions: Dictionary = {} # script_path -> int
var _server_save_timer: float = 0.0

# Presence state
# script_path -> Dictionary of peer_id -> CaretData
var _peer_carets: Dictionary = {}
var _peer_active_scripts: Dictionary = {} # peer_id -> script_path

var _saved_scripts: Dictionary = {}       # script_path -> whether the tab had no unsaved edits last frame
var _last_broadcast_caret: Dictionary = {}

func _ready():
	name = "TeamCreateScriptSync"
	_setup_script_editor_signals()

func _get_editor_interface():
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		return Engine.get_singleton("EditorInterface")
	if network and network.get("plugin") and network.plugin.has_method("get_editor_interface"):
		return network.plugin.get_editor_interface()
	return null

func _get_script_editor():
	var ei = _get_editor_interface()
	if ei and ei.has_method("get_script_editor"):
		return ei.get_script_editor()
	return null

func _setup_script_editor_signals():
	var se = _get_script_editor()
	if not se:
		return
	if se.has_signal("editor_script_changed") and not se.editor_script_changed.is_connected(_on_editor_script_changed):
		se.editor_script_changed.connect(_on_editor_script_changed)
	if se.has_signal("script_close") and not se.script_close.is_connected(_on_script_closed):
		se.script_close.connect(_on_script_closed)

func _process(delta: float):
	if not network or not network.is_connected_to_session():
		return

	# 1. Headless server periodic auto-save
	if network.is_server and (network.get("is_standalone_server") or DisplayServer.get_name() == "headless"):
		_server_save_timer += delta
		if _server_save_timer >= SCRIPT_AUTO_SAVE_INTERVAL:
			_server_save_timer = 0.0
			_save_dirty_server_scripts()

	if DisplayServer.get_name() == "headless":
		return

	# 2. Client active script scan & editor tracking
	_scan_open_script_editors()

	# 3. Process 100ms debounced diff timers
	var active_keys = _diff_timers.keys()
	for script_path in active_keys:
		if _diff_timers.has(script_path):
			_diff_timers[script_path] -= delta
			if _diff_timers[script_path] <= 0.0:
				_diff_timers.erase(script_path)
				_broadcast_script_diff(script_path)

	# 4. Send the local caret and selection whenever they change. Checked here rather than on
	# caret_changed because selecting or deselecting without moving the caret doesn't emit it
	_broadcast_local_caret()

	# 5. Tell peers when a tab gets back to its saved text
	_share_saved_states()

# ==============================================================================
# Editor Discovery & Tracking
# ==============================================================================

func _scan_open_script_editors():
	var se = _get_script_editor()
	if not se:
		return

	var open_scripts = se.get_open_scripts()
	# Text file tabs are listed here but not in open_scripts, which would pair scripts with the wrong tab
	var open_editors = se.get_open_script_editors().filter(func(e): return e.get_class() != "TextEditor")
	var current_script = se.get_current_script()

	if is_instance_valid(current_script) and current_script.resource_path != "":
		if _active_script_path != current_script.resource_path:
			_active_script_path = current_script.resource_path
			_request_script_if_needed(_active_script_path)

	var count = min(open_scripts.size(), open_editors.size())
	for i in range(count):
		var scr = open_scripts[i]
		var base_editor = open_editors[i]
		if not is_instance_valid(scr) or not is_instance_valid(base_editor):
			continue
		var path = scr.resource_path
		if path == "" or not path.begins_with("res://"):
			continue
		if not _tracked_editors.has(path) or not is_instance_valid(_tracked_editors[path]):
			_track_code_editor(path, base_editor)

func _track_code_editor(path: String, base_editor: Control):
	if not base_editor.has_method("get_base_editor"):
		return
	var code_edit = base_editor.get_base_editor()
	if not code_edit or not (code_edit is Control):
		return

	_tracked_editors[path] = code_edit

	# Initialize synced text state if not already set
	if not _synced_lines.has(path):
		var text = code_edit.get_text() if code_edit.has_method("get_text") else ""
		_synced_lines[path] = text.split("\n")
		_script_revisions[path] = 0

	# Connect text changes
	var changed_callable = Callable(self, "_on_code_edit_text_changed").bind(path)
	if code_edit.has_signal("text_changed") and not code_edit.text_changed.is_connected(changed_callable):
		code_edit.text_changed.connect(changed_callable)

	# Connect caret changes
	var caret_callable = Callable(self, "_on_code_edit_caret_changed").bind(path)
	if code_edit.has_signal("caret_changed") and not code_edit.caret_changed.is_connected(caret_callable):
		code_edit.caret_changed.connect(caret_callable)

	# Attach custom presence overlay
	_attach_presence_overlay(path, code_edit)

func _attach_presence_overlay(path: String, code_edit: Control):
	if _overlays.has(path) and is_instance_valid(_overlays[path]):
		return

	var overlay = ScriptPresenceOverlay.new()
	overlay.name = "TeamCreatePresenceOverlay"
	overlay.script_sync = self
	overlay.script_path = path
	overlay.code_edit = code_edit
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	code_edit.add_child(overlay)
	_overlays[path] = overlay

	# Re-render overlay when editor view scrolls
	if code_edit.has_method("get_v_scroll_bar"):
		var vsb = code_edit.get_v_scroll_bar()
		if vsb and not vsb.value_changed.is_connected(overlay._on_scroll_changed):
			vsb.value_changed.connect(overlay._on_scroll_changed)
	if code_edit.has_method("get_h_scroll_bar"):
		var hsb = code_edit.get_h_scroll_bar()
		if hsb and not hsb.value_changed.is_connected(overlay._on_scroll_changed):
			hsb.value_changed.connect(overlay._on_scroll_changed)

func _send_peer_caret(peer_id: int, path: String, line: int, col: int, has_sel: bool, sfl: int, sfc: int, stl: int, stc: int):
	if not (network and network.is_connected_to_session()):
		return
	var my_id = multiplayer.get_unique_id()
	if network.is_server:
		for pid in network.peers:
			if pid != 1 and pid != my_id:
				rpc_id(pid, "update_peer_script_caret", peer_id, path, line, col, has_sel, sfl, sfc, stl, stc)
	elif my_id != 1:
		rpc_id(1, "update_peer_script_caret", peer_id, path, line, col, has_sel, sfl, sfc, stl, stc)

func _on_editor_script_changed(script: Script):
	if not is_instance_valid(script) or script.resource_path == "":
		if _active_script_path != "":
			_active_script_path = ""
			if network and network.is_connected_to_session():
				var my_id = multiplayer.get_unique_id()
				_send_peer_caret(my_id, "", 0, 0, false, 0, 0, 0, 0)
		return
	var path = script.resource_path
	if path != "":
		_active_script_path = path
		_request_script_if_needed(path)

func _on_script_closed(script: Script):
	if not is_instance_valid(script):
		return
	var path = script.resource_path
	if _tracked_editors.has(path):
		_tracked_editors.erase(path)
	if _overlays.has(path):
		var ov = _overlays[path]
		if is_instance_valid(ov):
			ov.queue_free()
		_overlays.erase(path)
	if _active_script_path == path:
		_active_script_path = ""
		if network and network.is_connected_to_session():
			var my_id = multiplayer.get_unique_id()
			_send_peer_caret(my_id, "", 0, 0, false, 0, 0, 0, 0)

func _on_code_edit_text_changed(path: String):
	if _applying_remote_depth > 0:
		return
	# Debounce diff calculation by 100ms
	_diff_timers[path] = DIFF_DEBOUNCE_DELAY

func _on_code_edit_caret_changed(path: String):
	if _overlays.has(path) and is_instance_valid(_overlays[path]):
		_overlays[path].queue_redraw()

# ==============================================================================
# 100ms Debounced Diff Synchronization
# ==============================================================================

func _broadcast_script_diff(path: String):
	if not _tracked_editors.has(path):
		return
	var code_edit = _tracked_editors[path]
	if not is_instance_valid(code_edit):
		_tracked_editors.erase(path)
		return

	var cur_text = code_edit.get_text() if code_edit.has_method("get_text") else ""
	var cur_lines = cur_text.split("\n")
	var old_lines = _synced_lines.get(path, PackedStringArray())

	if cur_lines == old_lines:
		return

	# Fast prefix scan: find first line that differs
	var start_line = 0
	var min_len = min(old_lines.size(), cur_lines.size())
	while start_line < min_len and old_lines[start_line] == cur_lines[start_line]:
		start_line += 1

	# Fast suffix scan: find last line that differs from bottom
	var old_end = old_lines.size() - 1
	var cur_end = cur_lines.size() - 1
	while old_end >= start_line and cur_end >= start_line and old_lines[old_end] == cur_lines[cur_end]:
		old_end -= 1
		cur_end -= 1

	var old_count = max(0, old_end - start_line + 1)
	var new_slice: PackedStringArray = cur_lines.slice(start_line, cur_end + 1)

	var next_rev = _script_revisions.get(path, 0) + 1
	_script_revisions[path] = next_rev
	_synced_lines[path] = cur_lines
	var checksum = cur_text.md5_text()

	# Targeted delivery: host sends directly to peers; clients send to server (peer 1) for relay
	if network and network.is_server:
		_apply_patch_to_server_buffer(path, start_line, old_count, new_slice)
		_server_script_revisions[path] = next_rev
		for pid in network.peers:
			if pid != 1:
				rpc_id(pid, "apply_script_patch", path, start_line, old_count, new_slice, next_rev, checksum)
	elif multiplayer.get_unique_id() != 1:
		rpc_id(1, "apply_script_patch", path, start_line, old_count, new_slice, next_rev, checksum)

@rpc("any_peer", "reliable")
func apply_script_patch(path: String, start_line: int, old_count: int, new_lines: PackedStringArray, revision: int, checksum: String = ""):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if not _is_safe_script_path(path):
		printerr("Team Create: Blocked script patch for invalid path: ", path)
		return

	# 1. Server relay & buffer update
	if network and network.is_server:
		_apply_patch_to_server_buffer(path, start_line, old_count, new_lines)
		_server_script_revisions[path] = revision
		if sender_id != 0:
			for pid in network.peers:
				if pid != sender_id and pid != 1:
					rpc_id(pid, "apply_script_patch", path, start_line, old_count, new_lines, revision, checksum)

	# 2. Standalone server does not have an editor UI
	if network and (network.get("is_standalone_server") or DisplayServer.get_name() == "headless"):
		return

	# Deduplication & packet order guard: drop stale or duplicate packets immediately
	var cur_rev = _script_revisions.get(path, 0)
	if revision <= cur_rev:
		return
	if cur_rev > 0 and revision > cur_rev + 1:
		_request_script_if_needed(path)
		return

	# 3. Apply to open editor if tracked
	if not _tracked_editors.has(path):
		# If script isn't open locally, just update stored lines so when opened it has them
		_apply_patch_to_offline_lines(path, start_line, old_count, new_lines, revision, checksum)
		return

	var code_edit = _tracked_editors[path]
	if not is_instance_valid(code_edit):
		_tracked_editors.erase(path)
		return

	_applying_remote_depth += 1

	var local_caret_line = code_edit.get_caret_line()
	var local_caret_col = code_edit.get_caret_column()
	var line_diff = new_lines.size() - old_count

	# Apply line updates directly to CodeEdit
	var common = min(old_count, new_lines.size())
	for k in range(common):
		var target_line = start_line + k
		if target_line < code_edit.get_line_count():
			code_edit.set_line(target_line, new_lines[k])
		else:
			var last = code_edit.get_line_count() - 1
			if last >= 0:
				code_edit.insert_text("\n" + new_lines[k], last, code_edit.get_line(last).length())
			else:
				code_edit.insert_text(new_lines[k], 0, 0)

	if old_count > new_lines.size():
		for k in range(old_count - new_lines.size()):
			if start_line + common < code_edit.get_line_count():
				code_edit.remove_line_at(start_line + common)
	elif new_lines.size() > old_count:
		for k in range(common, new_lines.size()):
			var target_line = start_line + k
			if target_line < code_edit.get_line_count():
				code_edit.insert_line_at(target_line, new_lines[k])
			else:
				var last = code_edit.get_line_count() - 1
				if last >= 0:
					code_edit.insert_text("\n" + new_lines[k], last, code_edit.get_line(last).length())
				else:
					code_edit.insert_text(new_lines[k], 0, 0)

	# Adjust local user caret offset if the remote edit occurred above the cursor
	if start_line < local_caret_line:
		var adjusted_line = clamp(local_caret_line + line_diff, 0, max(0, code_edit.get_line_count() - 1))
		code_edit.set_caret_line(adjusted_line)
		code_edit.set_caret_column(local_caret_col)
	elif start_line == local_caret_line:
		# Same line: clamp column so it does not exceed the line length
		var line_len = code_edit.get_line(local_caret_line).length() if local_caret_line < code_edit.get_line_count() else 0
		code_edit.set_caret_column(min(local_caret_col, line_len))

	var updated_text = code_edit.get_text()
	_synced_lines[path] = updated_text.split("\n")
	_script_revisions[path] = revision
	call_deferred("_decrement_applying_remote")

	# Self-healing: verify local patched text matches sender's checksum
	if checksum != "":
		var local_md5 = updated_text.md5_text()
		if local_md5 != checksum:
			print_verbose("[TeamCreate] Script desync detected on " + path + ". Requesting authoritative server state...")
			_request_script_if_needed(path)

	# Redraw presence overlay
	if _overlays.has(path) and is_instance_valid(_overlays[path]):
		_overlays[path].queue_redraw()

# Built-in scripts use paths like res://scene.tscn::GDScript_abc, which aren't files on disk
func _is_safe_script_path(path: String) -> bool:
	return network and network.file_sync and network.file_sync._is_safe_path(path.replace("::", "_"))

func _apply_patch_to_offline_lines(path: String, start_line: int, old_count: int, new_lines: PackedStringArray, revision: int, checksum: String = ""):
	var lines = _synced_lines.get(path, PackedStringArray())
	if lines.is_empty() and FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.READ)
		if f:
			lines = f.get_as_text().replace("\r\n", "\n").split("\n")
			f.close()

	var prefix = lines.slice(0, start_line)
	var suffix = lines.slice(min(lines.size(), start_line + old_count))
	var result = PackedStringArray()
	result.append_array(prefix)
	result.append_array(new_lines)
	result.append_array(suffix)
	_synced_lines[path] = result
	_script_revisions[path] = revision
	if checksum != "" and "\n".join(result).md5_text() != checksum:
		_request_script_if_needed(path)

func _apply_patch_to_server_buffer(path: String, start_line: int, old_count: int, new_lines: PackedStringArray):
	var lines = _server_script_buffers.get(path, PackedStringArray())
	if lines.is_empty() and FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.READ)
		if f:
			lines = f.get_as_text().replace("\r\n", "\n").split("\n")
			f.close()

	var prefix = lines.slice(0, start_line)
	var suffix = lines.slice(min(lines.size(), start_line + old_count))
	var result = PackedStringArray()
	result.append_array(prefix)
	result.append_array(new_lines)
	result.append_array(suffix)
	_server_script_buffers[path] = result
	_dirty_scripts[path] = true

func _save_dirty_server_scripts():
	for path in _dirty_scripts.keys():
		if _server_script_buffers.has(path) and not "::" in path:
			var content = "\n".join(_server_script_buffers[path])
			var f = FileAccess.open(path, FileAccess.WRITE)
			if f:
				f.store_string(content)
				f.close()
	_dirty_scripts.clear()

# ==============================================================================
# Real-Time Caret & Presence Streaming (~30 FPS)
# ==============================================================================

func _broadcast_local_caret():
	if _active_script_path == "" or not _tracked_editors.has(_active_script_path):
		return
	if not (network and network.is_connected_to_session()):
		return

	var code_edit = _tracked_editors[_active_script_path]
	if not is_instance_valid(code_edit):
		return

	var line = code_edit.get_caret_line()
	var col = code_edit.get_caret_column()
	var has_sel = code_edit.has_selection()
	var sel_from_line = code_edit.get_selection_from_line() if has_sel else line
	var sel_from_col = code_edit.get_selection_from_column() if has_sel else col
	var sel_to_line = code_edit.get_selection_to_line() if has_sel else line
	var sel_to_col = code_edit.get_selection_to_column() if has_sel else col

	var caret_state = {
		"path": _active_script_path,
		"line": line,
		"col": col,
		"has_sel": has_sel,
		"sfl": sel_from_line,
		"sfc": sel_from_col,
		"stl": sel_to_line,
		"stc": sel_to_col
	}

	# Only send if state changed
	if _last_broadcast_caret == caret_state:
		return
	_last_broadcast_caret = caret_state

	var my_id = multiplayer.get_unique_id()
	_send_peer_caret(my_id, _active_script_path, line, col, has_sel, sel_from_line, sel_from_col, sel_to_line, sel_to_col)

# Undoing to the saved text or saving only clears the star in the editor that did it, because
# in every other editor the same text arrived as new edits.
func _share_saved_states():
	if not (network and network.is_connected_to_session()):
		return
	for path in _tracked_editors:
		var code_edit = _tracked_editors[path]
		if not is_instance_valid(code_edit):
			continue
		var saved = code_edit.get_version() == code_edit.get_saved_version()
		var was_saved = _saved_scripts.get(path, saved)
		_saved_scripts[path] = saved
		if saved and not was_saved:
			# The undo itself may still be waiting to go out
			_diff_timers.erase(path)
			_broadcast_script_diff(path)
			var checksum = code_edit.get_text().md5_text()
			if network.is_server:
				for pid in network.peers:
					if pid != 1:
						rpc_id(pid, "script_back_to_saved", path, checksum)
			elif multiplayer.get_unique_id() != 1:
				rpc_id(1, "script_back_to_saved", path, checksum)

@rpc("any_peer", "reliable")
func script_back_to_saved(path: String, checksum: String):
	if not _is_safe_script_path(path):
		return
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if network and network.is_server and sender_id != 0:
		for pid in network.peers:
			if pid != sender_id and pid != 1:
				rpc_id(pid, "script_back_to_saved", path, checksum)

	var code_edit = _tracked_editors.get(path)
	if not is_instance_valid(code_edit) or code_edit.get_text().md5_text() != checksum:
		return
	code_edit.tag_saved_version()
	_saved_scripts[path] = true
	# The script editor only redraws its star when the text changes
	code_edit.text_changed.emit()

@rpc("any_peer", "reliable")
func update_peer_script_caret(peer_id: int, path: String, line: int, col: int, has_sel: bool, sel_from_line: int, sel_from_col: int, sel_to_line: int, sel_to_col: int):
	if peer_id == 0:
		return

	# Never render our own caret
	if network and network.is_connected_to_session():
		if peer_id == multiplayer.get_unique_id():
			return

	# Handle clearing caret when peer closed script
	if path == "":
		clear_peer_caret(peer_id)
		return

	# Relay to other peers if server
	var sender_id = multiplayer.get_remote_sender_id() if (network and network.is_connected_to_session()) else 0
	if network and network.is_server and sender_id != 0:
		for pid in network.peers:
			if pid != sender_id and pid != 1 and pid != peer_id:
				rpc_id(pid, "update_peer_script_caret", peer_id, path, line, col, has_sel, sel_from_line, sel_from_col, sel_to_line, sel_to_col)

	# Standalone server does not render UI
	if network and (network.get("is_standalone_server") or DisplayServer.get_name() == "headless"):
		return

	# Ignore dedicated server peer ID 1 if received
	if peer_id == 1 and network and network.peers.has(1) and network.peers[1].get("is_standalone", false):
		return

	# Clean up any old script this peer was previously viewing
	if _peer_active_scripts.has(peer_id) and _peer_active_scripts[peer_id] != path:
		var old_path = _peer_active_scripts[peer_id]
		if _peer_carets.has(old_path):
			_peer_carets[old_path].erase(peer_id)
			if _overlays.has(old_path) and is_instance_valid(_overlays[old_path]):
				_overlays[old_path].queue_redraw()

	if not _peer_carets.has(path):
		_peer_carets[path] = {}

	_peer_carets[path][peer_id] = {
		"line": line,
		"col": col,
		"has_sel": has_sel,
		"sfl": sel_from_line,
		"sfc": sel_from_col,
		"stl": sel_to_line,
		"stc": sel_to_col,
		"time": Time.get_ticks_msec()
	}
	_peer_active_scripts[peer_id] = path
	if network and network.scene_sync:
		network.scene_sync.hold_frame_rate()

	# Trigger redraw if we are viewing this script
	if _overlays.has(path) and is_instance_valid(_overlays[path]):
		_overlays[path].queue_redraw()

func clear_peer_caret(peer_id: int):
	_peer_active_scripts.erase(peer_id)
	for path in _peer_carets.keys():
		if _peer_carets[path].has(peer_id):
			_peer_carets[path].erase(peer_id)
			if _overlays.has(path) and is_instance_valid(_overlays[path]):
				_overlays[path].queue_redraw()

# ==============================================================================
# Full State Synchronization on Script Open
# ==============================================================================

func _request_script_if_needed(path: String):
	if path == "" or not (network and network.is_connected_to_session()):
		return
	if network and network.is_connected_to_session() and not network.is_server and multiplayer.get_unique_id() != 1:
		rpc_id(1, "request_script_state", path)

@rpc("any_peer", "reliable")
func request_script_state(path: String):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if not _is_safe_script_path(path):
		printerr("Team Create: Blocked script request for invalid path: ", path)
		return
	var text = ""

	if network and network.is_server:
		if _server_script_buffers.has(path):
			text = "\n".join(_server_script_buffers[path])
		elif _tracked_editors.has(path) and is_instance_valid(_tracked_editors[path]):
			text = _tracked_editors[path].get_text().replace("\r\n", "\n")
		elif FileAccess.file_exists(path):
			var f = FileAccess.open(path, FileAccess.READ)
			if f:
				text = f.get_as_text().replace("\r\n", "\n")
				f.close()

	var rev = _server_script_revisions.get(path, _script_revisions.get(path, 0))
	rpc_id(sender_id, "receive_script_state", path, text, rev)

@rpc("any_peer", "reliable")
func receive_script_state(path: String, full_text: String, revision: int):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if (sender_id != 1 and sender_id != 0) or not _is_safe_script_path(path):
		return
	full_text = full_text.replace("\r\n", "\n")
	_script_revisions[path] = revision
	_synced_lines[path] = full_text.split("\n")

	if _tracked_editors.has(path):
		var code_edit = _tracked_editors[path]
		# Setting the text counts as an edit in Godot, even when it's identical
		if is_instance_valid(code_edit) and code_edit.get_text().replace("\r\n", "\n") != full_text:
			_applying_remote_depth += 1
			var local_line = code_edit.get_caret_line()
			var local_col = code_edit.get_caret_column()
			code_edit.set_text(full_text)
			code_edit.set_caret_line(min(local_line, code_edit.get_line_count() - 1))
			code_edit.set_caret_column(local_col)
			call_deferred("_decrement_applying_remote")
			if _overlays.has(path) and is_instance_valid(_overlays[path]):
				_overlays[path].queue_redraw()

func _decrement_applying_remote():
	if is_inside_tree():
		await get_tree().process_frame
	_applying_remote_depth = max(0, _applying_remote_depth - 1)

# ==============================================================================
# Cleanup & Reset
# ==============================================================================

func clear_all():
	for path in _overlays.keys():
		var ov = _overlays[path]
		if is_instance_valid(ov):
			ov.queue_free()
	_overlays.clear()
	_tracked_editors.clear()
	_peer_carets.clear()
	_peer_active_scripts.clear()
	_synced_lines.clear()
	_script_revisions.clear()
	_server_script_revisions.clear()
	_diff_timers.clear()
	_dirty_scripts.clear()
	_last_broadcast_caret.clear()
	_active_script_path = ""

# ==============================================================================
# ScriptPresenceOverlay Control (Visual Presence Overlay)
# ==============================================================================

class ScriptPresenceOverlay extends Control:
	var script_sync: Node
	var script_path: String = ""
	var code_edit: Control

	func _ready():
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _on_scroll_changed(_val: float = 0.0) -> void:
		queue_redraw()

	func _draw():
		if not script_sync or not is_instance_valid(script_sync):
			return
		if not code_edit or not is_instance_valid(code_edit):
			return
		if not script_sync._peer_carets.has(script_path):
			return

		var peer_map = script_sync._peer_carets[script_path]
		var font = get_theme_default_font()
		var font_size = 10
		var line_height = code_edit.get_line_height() if code_edit.has_method("get_line_height") else 16
		var total_lines = code_edit.get_line_count()
		if total_lines <= 0:
			return

		var local_caret_line = code_edit.get_caret_line() if code_edit.has_method("get_caret_line") else -1

		for peer_id in peer_map.keys():
			var data = peer_map[peer_id]
			var color = script_sync.network.get_user_color(peer_id) if script_sync.network else Color.WHITE
			var username = "User %d" % peer_id
			if script_sync.network and script_sync.network.peers.has(peer_id):
				username = script_sync.network.peers[peer_id].get("username", username)

			var target_line = data.get("line", 0)
			if target_line < 0 or target_line >= total_lines:
				continue

			# Caret proximity transparency calculation
			var caret_alpha: float = 1.0
			if local_caret_line >= 0:
				var line_dist = abs(target_line - local_caret_line)
				if line_dist == 0:
					caret_alpha = 0.05 # 95% transparent on same line
				elif line_dist == 1:
					caret_alpha = 0.20 # 80% transparent 1 line away
				elif line_dist == 2:
					caret_alpha = 0.40 # 60% transparent 2 lines away
				elif line_dist == 3:
					caret_alpha = 0.70 # 30% transparent 3 lines away
				else:
					caret_alpha = 1.0  # fully visible further away

			var caret_color = Color(color.r, color.g, color.b, caret_alpha)
			var badge_text_color = Color(1.0, 1.0, 1.0, caret_alpha)

			# 1. Selection highlighting
			if data.get("has_sel", false):
				var sfl = clamp(data.get("sfl", 0), 0, total_lines - 1)
				var sfc = data.get("sfc", 0)
				var stl = clamp(data.get("stl", 0), 0, total_lines - 1)
				var stc = data.get("stc", 0)
				var sel_color = Color(color.r, color.g, color.b, max(0.02, 0.25 * caret_alpha))

				if sfl == stl:
					var line_len = code_edit.get_line(sfl).length()
					var col_start = clamp(min(sfc, stc), 0, line_len)
					var col_end = clamp(max(sfc, stc), 0, line_len)
					var r1 = code_edit.get_rect_at_line_column(sfl, col_start)
					var r2 = code_edit.get_rect_at_line_column(stl, col_end)
					if r1.position.x >= 0 and r2.position.x >= 0:
						var x1 = r1.position.x if col_start == 0 else (r1.position.x + r1.size.x)
						var x2 = r2.position.x if col_end == 0 else (r2.position.x + r2.size.x)
						var sel_w = max(2, x2 - x1)
						draw_rect(Rect2(x1, r1.position.y, sel_w, line_height), sel_color)
				else:
					for line_idx in range(sfl, stl + 1):
						if line_idx >= total_lines:
							break
						var line_len = code_edit.get_line(line_idx).length()
						var col_start = clamp(sfc if line_idx == sfl else 0, 0, line_len)
						var col_end = clamp(stc if line_idx == stl else line_len, 0, line_len)
						var r1 = code_edit.get_rect_at_line_column(line_idx, col_start)
						var r2 = code_edit.get_rect_at_line_column(line_idx, col_end)
						if r1.position.x >= 0 and r2.position.x >= 0:
							var x1 = r1.position.x if col_start == 0 else (r1.position.x + r1.size.x)
							var x2 = r2.position.x if col_end == 0 else (r2.position.x + r2.size.x)
							var sel_w = max(2, x2 - x1)
							draw_rect(Rect2(x1, r1.position.y, sel_w, line_height), sel_color)

			# 2. Caret line
			var line_len = code_edit.get_line(target_line).length()
			var target_col = clamp(data.get("col", 0), 0, line_len)
			var caret_rect = code_edit.get_rect_at_line_column(target_line, target_col)

			if caret_rect.position.x >= 0 and caret_rect.position.y >= 0:
				var caret_x = caret_rect.position.x if target_col == 0 else (caret_rect.position.x + caret_rect.size.x)

				# Draw 2px solid colored bar with proximity transparency
				draw_rect(Rect2(caret_x, caret_rect.position.y, 2, line_height), caret_color)

				# 3. Name badge pill with proximity transparency
				var text_size = font.get_string_size(username, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
				var pad_x = 4.0
				var pad_y = 2.0
				var badge_w = text_size.x + pad_x * 2.0
				var badge_h = text_size.y + pad_y * 2.0
				var badge_pos = Vector2(caret_x, caret_rect.position.y - badge_h)
				badge_pos.y = max(0.0, badge_pos.y)

				# Background pill
				draw_rect(Rect2(badge_pos, Vector2(badge_w, badge_h)), caret_color)
				# White text
				draw_string(font, Vector2(badge_pos.x + pad_x, badge_pos.y + pad_y + text_size.y - 2), username, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, badge_text_color)
