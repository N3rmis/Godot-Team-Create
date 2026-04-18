@tool
extends Node

const SUPPORTED_EXTENSIONS = {"gd": true, "cs": true, "tscn": true, "scn": true, "png": true, "jpg": true, "wav": true, "ogg": true}

var network: Node
var _is_syncing_files = false
var _scan_timer = null


func _get_cached_md5(path: String) -> String:
	var mod_time = FileAccess.get_modified_time(path)
	if _file_hash_cache.has(path):
		var cached = _file_hash_cache[path]
		if cached["time"] == mod_time:
			return cached["md5"]

	var md5 = FileAccess.get_md5(path)
	_file_hash_cache[path] = {"time": mod_time, "md5": md5}
	return md5

func _is_safe_path(p: String) -> bool:
	var decoded = p.replace("%2e", ".").replace("%2E", ".")
	decoded = decoded.replace("%2f", "/").replace("%2F", "/")
	decoded = decoded.replace("%5c", "\\").replace("%5C", "\\")
	decoded = decoded.uri_decode()
	decoded = decoded.replace("\\", "/")

	if not decoded.begins_with("res://"):
		return false

	var base_res = ProjectSettings.globalize_path("res://").simplify_path()
	if not base_res.ends_with("/"):
		base_res += "/"

	var target = ProjectSettings.globalize_path(decoded).simplify_path()

	if not target.begins_with(base_res):
		return false

	var rel_path = "res://" + target.trim_prefix(base_res)

	var blocked_dirs = ["addons/team_create", ".godot", "webrtc"]
	for d in blocked_dirs:
		if rel_path == "res://" + d or rel_path.begins_with("res://" + d + "/"):
			return false

	if rel_path == "res://project.godot":
		return false

	return true

var _pending_files_to_receive = 0
var downloading_files: Array = []
var _sync_blocker: ColorRect
var _receiving_files: Dictionary = {}
var _known_files: Array = []
var _file_hash_cache: Dictionary = {}
signal sync_completed


func _show_sync_blocker():
	if not _sync_blocker and network and network.plugin:
		var editor = network.plugin.get_editor_interface()
		var base = editor.get_base_control()
		_sync_blocker = ColorRect.new()
		_sync_blocker.color = Color(0, 0, 0, 0.5)
		_sync_blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

		var label = Label.new()
		label.name = "SyncLabel"
		label.text = "Syncing Files... (0 remaining)"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_sync_blocker.add_child(label)

		base.add_child(_sync_blocker)

func _update_sync_blocker():
	if _sync_blocker:
		var label = _sync_blocker.get_node_or_null("SyncLabel")
		if label:
			label.text = "Syncing Files... (" + str(_pending_files_to_receive) + " remaining)"

func _hide_sync_blocker():
	if _sync_blocker:
		_sync_blocker.queue_free()
		_sync_blocker = null

func _ready():
	call_deferred("_setup_fs_signals")

func _setup_fs_signals():
	if network and network.plugin:
		var efs = network.plugin.get_editor_interface().get_resource_filesystem()
		if efs:
			if not efs.filesystem_changed.is_connected(_on_filesystem_changed):
				efs.filesystem_changed.connect(_on_filesystem_changed)

func _on_filesystem_changed():
	if _is_syncing_files or not multiplayer.has_multiplayer_peer() or multiplayer.get_peers().is_empty():
		return

	# Clear cache entries for files that were removed
	var keys_to_remove = []
	for path in _file_hash_cache.keys():
		if not FileAccess.file_exists(path):
			keys_to_remove.append(path)
	for path in keys_to_remove:
		_file_hash_cache.erase(path)

	# Automatically sync files whenever Godot detects a local file system change.
	sync_all_files()

	# Check for local deletions and broadcast them
	var current_files = get_all_files("res://")
	for known_path in _known_files:
		if not current_files.has(known_path):
			rpc("remote_delete_file", known_path)

	_known_files = current_files.duplicate()

func sync_project_settings():
	if multiplayer.is_server():
		var bytes = FileAccess.get_file_as_bytes("res://project.godot")
		if network and network.get("is_standalone_server"):
			var text = bytes.get_string_from_utf8()
			text = text.replace("run/main_scene=\"res://addons/team_create/server.tscn\"", "")
			text = text.replace("run/main_scene.teamcreateserver=\"res://addons/team_create/server.tscn\"", "")
			bytes = text.to_utf8_buffer()
		if bytes:
			rpc("receive_project_settings", bytes)

func sync_all_files():
	_is_syncing_files = true
	var all_files = get_all_files("res://")
	var file_hashes = {}
	for path in all_files:
		if path.begins_with("res://addons/team_create"):
			continue
		file_hashes[path] = _get_cached_md5(path)
	rpc("compare_and_sync_files", file_hashes)
	_is_syncing_files = false

func sync_all_files_to_peer(id: int):
	if multiplayer.is_server():
		var all_files = get_all_files("res://")
		var file_hashes = {}
		for path in all_files:
			if path.begins_with("res://addons/team_create"):
				continue
			file_hashes[path] = _get_cached_md5(path)
		rpc_id(id, "compare_and_sync_files", file_hashes)

func get_all_files(dir_path: String, exclude_dirs: Array = ["res://.godot", "res://webrtc"]) -> Array:
	var files = []
	var dir = DirAccess.open(dir_path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir() and not file_name.begins_with("."):
				var sub_dir = dir_path.path_join(file_name)
				if not exclude_dirs.has(sub_dir):
					files.append_array(get_all_files(sub_dir, exclude_dirs))
			elif not dir.current_is_dir() and not file_name.begins_with("."):
				# Convert local .tmp files to real assets instantly, as requested.
				var full_path = dir_path.path_join(file_name)
				if file_name.ends_with(".tmp"):
					# Strip the .tmp extension to get the original desired filename
					# (e.g. script.gd.tmp -> script.gd, not script.gd.res)
					var real_path = full_path.trim_suffix(".tmp")

					# Only override if it looks like Godot was trying to create an entirely new temporary resource
					# rather than overwriting an existing script or asset
					if not SUPPORTED_EXTENSIONS.has(real_path.get_extension()):
						if not real_path.ends_with(".res") and not real_path.ends_with(".tres"):
							real_path += ".res"

					DirAccess.rename_absolute(full_path, real_path)
					files.append(real_path)
					print("Converted temporary file to real asset: ", real_path)
					# Trigger editor refresh
					if network and network.plugin:
						network.plugin.get_editor_interface().get_resource_filesystem().scan()
				else:
					if full_path != "res://project.godot":
						files.append(full_path)
			file_name = dir.get_next()
	return files

@rpc("any_peer", "reliable")
func receive_project_settings(bytes: PackedByteArray):
	if multiplayer.get_remote_sender_id() != 1:
		printerr("Unauthorized settings sync attempt")
		return

	# Only overwrite if contents actually changed to prevent editor reload loops
	if FileAccess.file_exists("res://project.godot"):
		var existing_bytes = FileAccess.get_file_as_bytes("res://project.godot")
		if existing_bytes == bytes:
			return

	var file = FileAccess.open("res://project.godot", FileAccess.WRITE)
	if file:
		file.store_buffer(bytes)
		file.close()
		print("Project settings updated.")

@rpc("any_peer", "reliable")
func compare_and_sync_files(peer_hashes: Dictionary):
	_is_syncing_files = true
	var sender_id = multiplayer.get_remote_sender_id()
	var local_files = get_all_files("res://")
	var local_hashes = {}

	for path in local_files:
		if path.begins_with("res://addons/team_create"):
			continue
		local_hashes[path] = _get_cached_md5(path)

	# Find files to delete (only allow the server to delete files to prevent clients wiping the server)
	if sender_id == 1:
		for path in local_hashes:
			if not peer_hashes.has(path):
				DirAccess.remove_absolute(path)
				if _file_hash_cache.has(path):
					_file_hash_cache.erase(path)
				print("Deleted unused file: ", path)

	# Request differing files
	var files_to_request = []
	for path in peer_hashes:
		if path == "res://project.godot":
			continue
		if not local_hashes.has(path) or local_hashes[path] != peer_hashes[path]:
			files_to_request.append(path)

	# Sort requests so scenes are requested LAST to ensure assets are downloaded first
	files_to_request.sort_custom(func(a, b):
		var a_is_scene = a.ends_with(".tscn") or a.ends_with(".scn")
		var b_is_scene = b.ends_with(".tscn") or b.ends_with(".scn")
		if a_is_scene and not b_is_scene:
			return false
		if b_is_scene and not a_is_scene:
			return true
		return a < b
	)

	_pending_files_to_receive = files_to_request.size()
	downloading_files.clear()
	downloading_files.append_array(files_to_request)

	_known_files = local_files.duplicate()

	if _pending_files_to_receive > 0:
		call_deferred("_show_sync_blocker")
		call_deferred("_update_sync_blocker")

	for path in files_to_request:
		rpc_id(sender_id, "request_file", path)

	if _pending_files_to_receive == 0:
		sync_completed.emit()

	_is_syncing_files = false

@rpc("any_peer", "reliable")
func request_file(path: String):
	var sender_id = multiplayer.get_remote_sender_id()

	if not _is_safe_path(path):
		printerr("Team Create: Unauthorized or invalid file access requested: ", path)
		rpc_id(sender_id, "receive_file", path, randi(), PackedByteArray(), true)
		return

	# Send file back
	if FileAccess.file_exists(path):
		var bytes = FileAccess.get_file_as_bytes(path)
		var total_size = bytes.size()

		if total_size == 0:
			rpc_id(sender_id, "receive_file", path, randi(), bytes, true)
			return

		# TODO: Abstract chunking logic into a reusable helper for large RPC data transfers
		if network and network.is_webrtc:
			var chunk_size = 60000
			var offset = 0
			var transfer_id = randi()
			while offset < total_size:
				var end_idx = min(offset + chunk_size, total_size)
				var chunk = bytes.slice(offset, end_idx)
				var is_final = (end_idx == total_size)
				rpc_id(sender_id, "receive_file", path, transfer_id, chunk, is_final)
				offset += chunk_size
				if not is_final:
					await get_tree().process_frame
		else:
			rpc_id(sender_id, "receive_file", path, randi(), bytes, true)
	else:
		rpc_id(sender_id, "receive_file", path, randi(), PackedByteArray(), true)

@rpc("any_peer", "reliable")
func receive_file(path: String, transfer_id: int, bytes: PackedByteArray, is_final: bool = true):
	if not _is_safe_path(path):
		printerr("Team Create: Unauthorized or invalid file path received: ", path)
		return

	var sender_id = multiplayer.get_remote_sender_id()
	var file_key = str(sender_id) + "_" + str(transfer_id) + "_" + path
	if not _receiving_files.has(file_key):
		_receiving_files[file_key] = PackedByteArray()

	_receiving_files[file_key].append_array(bytes)

	if not is_final:
		return

	var full_bytes = _receiving_files[file_key]
	_receiving_files.erase(file_key)
	bytes = full_bytes

	# Convert temporary files based on origin
	if path.ends_with(".tmp"):
		var real_path = path.trim_suffix(".tmp")
		if not SUPPORTED_EXTENSIONS.has(real_path.get_extension()):
			if not real_path.ends_with(".res") and not real_path.ends_with(".tres"):
				real_path += ".res"
		path = real_path

	# If this is a scene file, and the user has it open, we intercept writing it to disk.
	if network and network.scene_sync and network.plugin and (path.ends_with(".tscn") or path.ends_with(".scn")):
		var ei = network.plugin.get_editor_interface()
		var current_scene = ei.get_edited_scene_root()
		var open_scenes = ei.get_open_scenes()

		if current_scene and current_scene.scene_file_path == path:
			print("Team Create: Applying received file to active scene view.")
			if bytes.size() > 0:
				var file = FileAccess.open(path, FileAccess.WRITE)
				if file:
					file.store_buffer(bytes)
					file.close()
			network.scene_sync._is_reloading_scene = true
			network.scene_sync._force_full_sync_next_frame = true
			ei.reload_scene_from_path(path)
			get_tree().create_timer(0.5).timeout.connect(func():
				if is_instance_valid(network) and network.scene_sync:
					network.scene_sync._is_reloading_scene = false
			)
			downloading_files.erase(path)
			if _pending_files_to_receive > 0:
				_pending_files_to_receive -= 1
				call_deferred("_update_sync_blocker")
				if _pending_files_to_receive <= 0:
					call_deferred("_hide_sync_blocker")
					call_deferred("_hide_sync_blocker")
				_known_files = get_all_files("res://")
				sync_completed.emit()

			return
		elif path in open_scenes:
			# Scene is open but NOT active ("closed" by the user's focus).
			# We close the background scene in tabs.
			var prev_path = current_scene.scene_file_path if current_scene else ""
			ei.open_scene_from_path(path)
			ei.close_scene()
			if prev_path != "":
				ei.open_scene_from_path(prev_path)
			print("Team Create: Closed background scene tab: ", path)
			# We DO write the file below since it's no longer open.

	# Ensure directory exists before writing
	var dir_path = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	if bytes.size() > 0:
		var should_write = true
		if FileAccess.file_exists(path):
			var existing_bytes = FileAccess.get_file_as_bytes(path)
			if existing_bytes == bytes:
				should_write = false

		if should_write:
			var file = FileAccess.open(path, FileAccess.WRITE)
			if file:
				file.store_buffer(bytes)
				file.close()
				print("Received and updated file: ", path)
		else:
			print("File unchanged, skipped writing: ", path)

		# Trigger Editor resource scan if it's an asset, debounced to prevent premature imports generating new UIDs
		if network.plugin and network.plugin.get_editor_interface().get_resource_filesystem():
			if _scan_timer == null:
				_scan_timer = get_tree().create_timer(0.5)
				_scan_timer.timeout.connect(func():
					_scan_timer = null
					if network and network.plugin and network.plugin.get_editor_interface().get_resource_filesystem():
						network.plugin.get_editor_interface().get_resource_filesystem().scan()
				)

	downloading_files.erase(path)
	if _pending_files_to_receive > 0:
		_pending_files_to_receive -= 1
		call_deferred("_update_sync_blocker")
		if _pending_files_to_receive <= 0:
			call_deferred("_hide_sync_blocker")
			_known_files = get_all_files("res://")
			sync_completed.emit()


# TODO: Handle cases where a local file is deleted while offline/disconnected before broadcasting
@rpc("any_peer", "reliable")
func remote_delete_file(path: String):
	if multiplayer.get_remote_sender_id() != 1:
		return # Only server can dictate deletions for security

	if not _is_safe_path(path):
		return

	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		if _file_hash_cache.has(path):
			_file_hash_cache.erase(path)
		print("Team Create: Replicated file deletion: ", path)

		# Remove from known files
		if _known_files.has(path):
			_known_files.erase(path)
