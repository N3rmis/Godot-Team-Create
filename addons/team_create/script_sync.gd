@tool
extends Node

## Team Create - Collaborative Script Synchronization & Presence
## Real-time collaborative code editing. Edits go through the server, which puts them in order and rewrites each
## to allow for whatever the sender hadn't seen yet (see text_ot.gd), so people can type at the same time.
## Also live presence carets, collaborator name badges, and selection highlighting.

const TextOT = preload("text_ot.gd")

const DIFF_DEBOUNCE_DELAY: float = 0.100      # How often typing goes out
const MAX_SCRIPT_HISTORY: int = 1000          # Edits the server keeps for rewriting ones that were sent late
const SCRIPT_AUTO_SAVE_INTERVAL: float = 15.0 # Save dirty server script buffers every 15s

var network: Node

# Editor references (Client only)
var _tracked_editors: Dictionary = {}    # script_path -> CodeEdit
var _active_script_path: String = ""      # Currently focused script in editor
var _overlays: Dictionary = {}           # script_path -> ScriptPresenceOverlay

# Text synchronization state (Client)
# script_path -> {text, rev, outstanding, buffer, ready, closing, reloaded}. text is what the editor had when last checked,
# rev is the last server edit included in it, outstanding is the edit the server hasn't confirmed yet, and buffer
# is everything typed since. Only one edit is on its way at a time.
var _docs: Dictionary = {}
var _diff_timers: Dictionary = {}        # script_path -> float
var _dirty_scripts: Dictionary = {}       # script_path -> bool
var _local_delivery: bool = false         # A host's editor is getting a message from its own server
var _pending_saved: Dictionary = {}       # script_path -> checksum of text someone saved, that hasn't arrived yet
var _last_saved_by_peer: Dictionary = {}  # script_path -> checksum of the text someone most recently saved
var _saved_versions: Dictionary = {}      # script_path -> the tab's saved version number last time it was checked
var _saved_checksums: Dictionary = {}     # script_path -> checksum of what this editor last saved

# Server text (Headless / Host)
# script_path -> {text, rev, history, subscribers}. Only for scripts someone has open.
var _server_docs: Dictionary = {}
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

	# 3. Send what's been typed
	var active_keys = _diff_timers.keys()
	for script_path in active_keys:
		if _diff_timers.has(script_path):
			_diff_timers[script_path] -= delta
			if _diff_timers[script_path] <= 0.0:
				_diff_timers.erase(script_path)
				_flush_local_edits(script_path)

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
		_active_script_path = current_script.resource_path

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

	# Whatever a new tab has counts for nothing until the server says what the text is
	_docs[path] = {"text": "", "rev": 0, "outstanding": null, "buffer": null, "ready": false, "closing": false, "reloaded": false}
	_request_script_state(path)

	# Connect text changes
	var changed_callable = Callable(self, "_on_code_edit_text_changed").bind(path)
	if code_edit.has_signal("text_changed") and not code_edit.text_changed.is_connected(changed_callable):
		code_edit.text_changed.connect(changed_callable)

	# Godot reloads a tab from disk when the window gets focus back
	var set_callable = Callable(self, "_on_code_edit_text_set").bind(path)
	if code_edit.has_signal("text_set") and not code_edit.text_set.is_connected(set_callable):
		code_edit.text_set.connect(set_callable)

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

func _on_script_closed(script: Script):
	if not is_instance_valid(script):
		return
	var path = script.resource_path
	_flush_local_edits(path)
	if _tracked_editors.has(path):
		_tracked_editors.erase(path)
	if _docs.has(path):
		# Anything still on its way needs the server's answer before this can be let go
		if _docs[path].outstanding != null:
			_docs[path].closing = true
		else:
			_close_doc(path)
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
	# Not restarted by each key, or fast typing wouldn't go out until it paused
	if not _diff_timers.has(path):
		_diff_timers[path] = DIFF_DEBOUNCE_DELAY

# The disk can be older than the live text, and sending that out would undo what people typed. A change made
# outside Godot still gets here, as an upload.
func _on_code_edit_text_set(path: String):
	if _docs.has(path):
		_docs[path].reloaded = true
		if not _diff_timers.has(path):
			_diff_timers[path] = 0.0

func _on_code_edit_caret_changed(path: String):
	if _overlays.has(path) and is_instance_valid(_overlays[path]):
		_overlays[path].queue_redraw()

# ==============================================================================
# Merged Text Editing: Client
# ==============================================================================

func _local_peer_id() -> int:
	return multiplayer.get_unique_id() if (network and network.is_connected_to_session()) else 0

func _flush_local_edits(path: String):
	var doc = _docs.get(path)
	if not doc or not doc.ready or doc.closing:
		return
	var code_edit = _tracked_editors.get(path)
	if not is_instance_valid(code_edit):
		return
	var text = code_edit.get_text().replace("\r\n", "\n")
	if doc.reloaded:
		doc.reloaded = false
		if text != doc.text:
			_apply_op_to_editor(code_edit, text, TextOT.diff(text, doc.text))
			# If the disk just hadn't caught up with a save yet, this tab isn't really unsaved
			if _last_saved_by_peer.has(path):
				_pending_saved[path] = _last_saved_by_peer[path]
				_clear_star_if_saved(path)
		return
	if text == doc.text:
		return
	var op = TextOT.diff(doc.text, text)
	doc.text = text
	if doc.outstanding != null:
		doc.buffer = TextOT.compose(doc.buffer, op) if doc.buffer != null else op
	else:
		doc.outstanding = op
		_send_outstanding(path)

func _send_outstanding(path: String):
	var doc = _docs[path]
	if network.is_server:
		_server_submit(path, _local_peer_id(), doc.rev, doc.outstanding)
	else:
		rpc_id(1, "submit_script_edit", path, doc.rev, doc.outstanding)

# Built-in scripts use paths like res://scene.tscn::GDScript_abc, which aren't files on disk
func _is_safe_script_path(path: String) -> bool:
	return network and network.file_sync and network.file_sync._is_safe_path(path.replace("::", "_"))

func _from_server() -> bool:
	return _local_delivery or multiplayer.get_remote_sender_id() == 1

@rpc("any_peer", "reliable")
func script_edit_confirmed(path: String, rev: int, checksum: String):
	var doc = _docs.get(path)
	if not _from_server() or not doc or not doc.ready:
		return
	doc.rev = rev
	doc.outstanding = doc.buffer
	doc.buffer = null
	if doc.outstanding != null:
		_send_outstanding(path)
	elif doc.closing:
		_close_doc(path)
	else:
		_verify_doc(path, checksum)

@rpc("any_peer", "reliable")
func receive_script_edit(path: String, rev: int, op: Array, checksum: String):
	var doc = _docs.get(path)
	if not _from_server() or not doc or not doc.ready:
		return
	# What's typed but not sent has to be accounted for first, or this edit lands in the wrong place
	_flush_local_edits(path)
	var base_length = TextOT.input_length(doc.outstanding) if doc.outstanding != null else doc.text.length()
	if rev != doc.rev + 1 or TextOT.input_length(op) != base_length or not TextOT.is_valid(op):
		_resync_doc(path)
		return
	doc.rev = rev
	if doc.outstanding != null:
		var outstanding_pair = TextOT.transform(doc.outstanding, op)
		doc.outstanding = outstanding_pair[0]
		op = outstanding_pair[1]
	if doc.buffer != null:
		var buffer_pair = TextOT.transform(doc.buffer, op)
		doc.buffer = buffer_pair[0]
		op = buffer_pair[1]

	var code_edit = _tracked_editors.get(path)
	if is_instance_valid(code_edit):
		_apply_op_to_editor(code_edit, doc.text, op)
	doc.text = TextOT.apply(doc.text, op)
	if doc.outstanding == null:
		_verify_doc(path, checksum)
	_clear_star_if_saved(path)

# Copies can only be compared when nothing is on its way, and should never differ. If they do, the server's is the real one.
func _verify_doc(path: String, checksum: String):
	if _docs[path].text.md5_text() != checksum:
		network.tc_print("Team Create: Script text went out of step, getting the server's copy: " + path)
		_resync_doc(path)

func _resync_doc(path: String):
	var doc = _docs[path]
	doc.ready = false
	doc.outstanding = null
	doc.buffer = null
	_request_script_state(path)

func _close_doc(path: String):
	_docs.erase(path)
	_pending_saved.erase(path)
	_last_saved_by_peer.erase(path)
	_saved_versions.erase(path)
	_saved_checksums.erase(path)
	if not (network and network.is_connected_to_session()):
		return
	if network.is_server:
		_server_unsubscribe(path, _local_peer_id())
	else:
		rpc_id(1, "close_script_state", path)

# Edits are made one range at a time from the end, so the earlier positions stay correct. The editor moves carets and
# selections itself. A caret at the exact spot stays in front of the new text, so two people typing at the same place
# each keep their own words together.
func _apply_op_to_editor(code_edit, text_before: String, op: Array):
	var hunks = []
	var position = 0
	for step in op:
		if step is String:
			hunks.append([position, 0, step])
		elif step > 0:
			position += step
		else:
			if not hunks.is_empty() and hunks[-1][0] + hunks[-1][1] == position:
				hunks[-1][1] -= step
			else:
				hunks.append([position, -step, ""])
			position -= step
	if hunks.is_empty():
		return

	var line_starts = PackedInt32Array([0])
	var newline = text_before.find("\n")
	while newline != -1:
		line_starts.append(newline + 1)
		newline = text_before.find("\n", newline + 1)

	code_edit.begin_complex_operation()
	for i in range(hunks.size() - 1, -1, -1):
		var from_line = line_starts.bsearch(hunks[i][0], false) - 1
		var from_column = hunks[i][0] - line_starts[from_line]
		if hunks[i][1] > 0:
			var end = hunks[i][0] + hunks[i][1]
			var to_line = line_starts.bsearch(end, false) - 1
			code_edit.remove_text(from_line, from_column, to_line, end - line_starts[to_line])
		if hunks[i][2] != "":
			code_edit.insert_text(hunks[i][2], from_line, from_column, true, false)
	code_edit.end_complex_operation()

	for overlay in _overlays.values():
		if is_instance_valid(overlay) and overlay.code_edit == code_edit:
			overlay.queue_redraw()

# The server is about to take this file. If it isn't what this editor saved, it was changed outside Godot, and the
# tab should show that too, or the next edit here would overwrite it.
# Godot won't save a tab whose file looks newer on disk, and asks about it in a dialog we hide.
# Saying the script was saved updates the time the tab remembers without reloading it. That also
# clears the star, so it goes back on if the tab has text the file doesn't.
func refresh_disk_time(path: String):
	var code_edit = _tracked_editors.get(path)
	if not path.ends_with(".gd") or not is_instance_valid(code_edit):
		return
	var editor_node = EditorInterface.get_base_control().get_parent()
	if not editor_node.has_signal("resource_saved"):
		return
	editor_node.resource_saved.emit(load(path))
	var disk_text = FileAccess.get_file_as_string(path).replace("\r\n", "\n")
	if code_edit.get_text().replace("\r\n", "\n") != disk_text:
		var line = code_edit.get_line_count() - 1
		var col = code_edit.get_line(line).length()
		code_edit.begin_complex_operation()
		code_edit.insert_text(" ", line, col, true, false)
		code_edit.remove_text(line, col, line, col + 1)
		code_edit.end_complex_operation()
	_saved_versions[path] = code_edit.get_saved_version()
	_saved_checksums[path] = disk_text.md5_text()
	_saved_scripts[path] = code_edit.get_version() == code_edit.get_saved_version()

func on_upload_requested(path: String, bytes: PackedByteArray):
	var doc = _docs.get(path)
	var code_edit = _tracked_editors.get(path)
	if not doc or not doc.ready or doc.closing or not is_instance_valid(code_edit):
		return
	var text = bytes.get_string_from_utf8().replace("\r\n", "\n")
	if _saved_checksums.has(path) and (_saved_checksums[path] == "" or _saved_checksums[path] == text.md5_text()):
		return
	_flush_local_edits(path)
	if text != doc.text:
		_apply_op_to_editor(code_edit, doc.text, TextOT.diff(doc.text, text))
		_flush_local_edits(path)
	refresh_disk_time(path)

# ==============================================================================
# Merged Text Editing: Server
# ==============================================================================

# Delivers to a peer, which on a host can be its own editor
func _send_to_peer(peer_id: int, method: String, args: Array):
	if peer_id == _local_peer_id():
		_local_delivery = true
		callv(method, args)
		_local_delivery = false
	else:
		callv("rpc_id", [peer_id, method] + args)

func _server_doc(path: String, sender_text: String) -> Dictionary:
	if not _server_docs.has(path):
		var text = sender_text
		if FileAccess.file_exists(path):
			var f = FileAccess.open(path, FileAccess.READ)
			if f:
				text = f.get_as_text().replace("\r\n", "\n")
				f.close()
		_server_docs[path] = {"text": text, "rev": 0, "history": [], "subscribers": {}}
	return _server_docs[path]

func _is_session_peer(peer_id: int) -> bool:
	return network and network.is_server and (peer_id == _local_peer_id() or network.peers.has(peer_id))

@rpc("any_peer", "reliable")
func submit_script_edit(path: String, base_rev: int, op: Array):
	_server_submit(path, multiplayer.get_remote_sender_id(), base_rev, op)

func _server_submit(path: String, sender_id: int, base_rev: int, op: Array):
	var doc = _server_docs.get(path)
	if not _is_session_peer(sender_id) or not _is_safe_script_path(path) or not doc or not doc.subscribers.has(sender_id):
		return
	# Sent against a version the server has forgotten, or one that can't exist
	var first = doc.history.size() - (doc.rev - base_rev)
	if first < 0 or first > doc.history.size() or not TextOT.is_valid(op):
		_send_script_state(path, sender_id)
		return
	var base_length = TextOT.input_length(doc.history[first]) if first < doc.history.size() else doc.text.length()
	if TextOT.input_length(op) != base_length:
		_send_script_state(path, sender_id)
		return
	for i in range(first, doc.history.size()):
		op = TextOT.transform(op, doc.history[i])[0]
	_server_commit(path, op, sender_id)

# Puts an edit that's already allowed for everything before it into the text, and tells everyone
func _server_commit(path: String, op: Array, sender_id: int):
	var doc = _server_docs[path]
	doc.text = TextOT.apply(doc.text, op)
	doc.rev += 1
	doc.history.append(op)
	if doc.history.size() > MAX_SCRIPT_HISTORY:
		doc.history.pop_front()
	_dirty_scripts[path] = true
	var checksum = doc.text.md5_text()
	for peer_id in doc.subscribers.keys():
		if peer_id == sender_id:
			_send_to_peer(peer_id, "script_edit_confirmed", [path, doc.rev, checksum])
		else:
			_send_to_peer(peer_id, "receive_script_edit", [path, doc.rev, op, checksum])

func _send_script_state(path: String, peer_id: int):
	var doc = _server_docs[path]
	_send_to_peer(peer_id, "receive_script_state", [path, doc.text, doc.rev])

func _server_unsubscribe(path: String, peer_id: int):
	var doc = _server_docs.get(path)
	if not doc:
		return
	doc.subscribers.erase(peer_id)
	if doc.subscribers.is_empty():
		_save_server_doc(path)
		_dirty_scripts.erase(path)
		_server_docs.erase(path)

func on_peer_left(peer_id: int):
	for path in _server_docs.keys():
		_server_unsubscribe(path, peer_id)

@rpc("any_peer", "reliable")
func close_script_state(path: String):
	if _is_session_peer(multiplayer.get_remote_sender_id()):
		_server_unsubscribe(path, multiplayer.get_remote_sender_id())

# A file from someone with the script open is just their save, and their typing reaches the server as edits. From
# anyone else it was changed outside the editor, so it goes to everyone who has the script open.
func on_file_received(path: String, bytes: PackedByteArray, sender_id: int):
	var doc = _server_docs.get(path)
	if not doc or bytes.is_empty():
		return
	var text = bytes.get_string_from_utf8().replace("\r\n", "\n")
	if text == doc.text:
		_dirty_scripts.erase(path)
	elif doc.subscribers.has(sender_id):
		_dirty_scripts[path] = true
	else:
		_server_commit(path, TextOT.diff(doc.text, text), 0)

func _save_server_doc(path: String):
	if not network or not network.get("is_standalone_server") or "::" in path or not _server_docs.has(path) or not _dirty_scripts.has(path):
		return
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(_server_docs[path].text)
		f.close()
	if network.file_sync:
		network.file_sync._file_hash_cache.erase(path)

func _save_dirty_server_scripts():
	for path in _dirty_scripts.keys():
		_save_server_doc(path)
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
		if _saved_versions.get(path, -1) != code_edit.get_saved_version():
			_saved_versions[path] = code_edit.get_saved_version()
			# Empty when typing got in straight after the save, so what was saved is no longer known
			_saved_checksums[path] = code_edit.get_text().replace("\r\n", "\n").md5_text() if saved else ""
		var was_saved = _saved_scripts.get(path, saved)
		_saved_scripts[path] = saved
		if saved and not was_saved:
			# The undo itself may still be waiting to go out
			_diff_timers.erase(path)
			_flush_local_edits(path)
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

	# The text may still be on its way, because the saver's last edit can be waiting for an earlier one to be confirmed
	_pending_saved[path] = checksum
	_last_saved_by_peer[path] = checksum
	_clear_star_if_saved(path)

func _clear_star_if_saved(path: String):
	if not _pending_saved.has(path):
		return
	var code_edit = _tracked_editors.get(path)
	if not is_instance_valid(code_edit) or code_edit.get_text().md5_text() != _pending_saved[path]:
		return
	_pending_saved.erase(path)
	if path.ends_with(".gd") and network and network.file_sync:
		# A tab without a star doesn't get saved when the game runs, so the file has to match it now
		network.file_sync.write_saved_script(path, code_edit.get_text())
		refresh_disk_time(path)
	else:
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

func _request_script_state(path: String):
	if path == "" or not (network and network.is_connected_to_session()):
		return
	# Only used if the server has no such file yet, such as a new script or one built into a scene
	var code_edit = _tracked_editors.get(path)
	var text = code_edit.get_text().replace("\r\n", "\n") if is_instance_valid(code_edit) else ""
	if network.is_server:
		_server_subscribe(path, _local_peer_id(), text)
	else:
		rpc_id(1, "request_script_state", path, text)

@rpc("any_peer", "reliable")
func request_script_state(path: String, sender_text: String):
	if not _is_safe_script_path(path):
		printerr("Team Create: Blocked script request for invalid path: ", path)
		return
	if _is_session_peer(multiplayer.get_remote_sender_id()):
		_server_subscribe(path, multiplayer.get_remote_sender_id(), sender_text)

func _server_subscribe(path: String, peer_id: int, sender_text: String):
	_server_doc(path, sender_text).subscribers[peer_id] = true
	_send_script_state(path, peer_id)

@rpc("any_peer", "reliable")
func receive_script_state(path: String, full_text: String, revision: int):
	var doc = _docs.get(path)
	if not _from_server() or not _is_safe_script_path(path) or not doc:
		return
	doc.text = full_text
	doc.rev = revision
	doc.outstanding = null
	doc.buffer = null
	doc.ready = true
	doc.closing = false
	doc.reloaded = false

	var code_edit = _tracked_editors.get(path)
	if is_instance_valid(code_edit):
		var current = code_edit.get_text().replace("\r\n", "\n")
		if current != full_text:
			_apply_op_to_editor(code_edit, current, TextOT.diff(current, full_text))
	_clear_star_if_saved(path)

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
	_docs.clear()
	_server_docs.clear()
	_pending_saved.clear()
	_last_saved_by_peer.clear()
	_saved_versions.clear()
	_saved_checksums.clear()
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
