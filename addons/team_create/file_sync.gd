@tool
extends Node

var _file_write_mutex = Mutex.new()

const SUPPORTED_EXTENSIONS = {
	"gd": true, "cs": true, "tscn": true, "scn": true,
	"png": true, "jpg": true, "jpeg": true, "webp": true, "svg": true, "bmp": true,
	"wav": true, "ogg": true, "mp3": true,
	"tres": true, "res": true, "material": true, "import": true,
	"json": true, "txt": true, "blend": true, "glb": true, "gltf": true
}

var network: Node
var _is_syncing_files = false
var _scan_timer = null

var _http_server: TCPServer
var _http_clients: Array = []
var _http_buffers: Dictionary = {}
var _http_responses: Dictionary = {}
const HTTP_TOKEN_HEADER = "X-Team-Create-Token"
const HTTP_MAX_RECORDS_PER_FRAME = 64
const HTTP_MAX_ACCEPTS_PER_FRAME = 16
# TLS handshakes are slow, so opening a connection per file at once overflows the server's backlog
const HTTP_MAX_CONCURRENT_DOWNLOADS = 8
const HTTP_MAX_DOWNLOAD_RETRIES = 3
var _http_download_queue: Array = []
var _http_downloads_active = 0
var _http_download_retries: Dictionary = {}

func _get_editor_interface():
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		return Engine.get_singleton("EditorInterface")
	if network and network.plugin and network.plugin.has_method("get_editor_interface"):
		return network.plugin.get_editor_interface()
	return null

func _process(delta):
	if _http_server and _http_server.is_listening():
		for _accept in range(HTTP_MAX_ACCEPTS_PER_FRAME):
			if not _http_server.is_connection_available():
				break
			var tcp = _http_server.take_connection()
			var peer = StreamPeerTLS.new()
			if network.server_tls_options and peer.accept_stream(tcp, network.server_tls_options) == OK:
				_http_clients.append(peer)
				_http_buffers[peer] = PackedByteArray()
				_http_responses[peer] = { "data": PackedByteArray(), "sent": 0, "active": false, "timer": 0.0, "tcp": tcp }
			else:
				tcp.disconnect_from_host()

		for i in range(_http_clients.size() - 1, -1, -1):
			var peer: StreamPeerTLS = _http_clients[i]
			_http_responses[peer]["tcp"].poll()
			peer.poll()
			var status = peer.get_status()

			if status == StreamPeerTLS.STATUS_HANDSHAKING:
				# Drop clients that stall during the handshake
				_http_responses[peer]["timer"] += delta
				if _http_responses[peer]["timer"] > file_transfer_timeout:
					peer.disconnect_from_stream()
					_http_clients.remove_at(i)
					_http_buffers.erase(peer)
					_http_responses.erase(peer)
			elif status == StreamPeerTLS.STATUS_CONNECTED:
				var resp = _http_responses[peer]
				resp["timer"] += delta

				# Timeout idle connections
				if resp["timer"] > file_transfer_timeout:
					peer.disconnect_from_stream()
					_http_clients.remove_at(i)
					_http_buffers.erase(peer)
					_http_responses.erase(peer)
					continue

				if not resp["active"]:
					if peer.get_available_bytes() > 0:
						var bytes = peer.get_data(peer.get_available_bytes())
						if bytes[0] == OK:
							_http_buffers[peer].append_array(bytes[1])
							# Each poll exposes one TLS record (16 KB), so drain what's ready or uploads crawl
							for _record in range(HTTP_MAX_RECORDS_PER_FRAME):
								peer.poll()
								var available = peer.get_available_bytes()
								if available <= 0:
									break
								var more = peer.get_data(available)
								if more[0] != OK:
									break
								_http_buffers[peer].append_array(more[1])
							var buffer_bytes = _http_buffers[peer]
							var header_end_idx = -1
							var header_len = 4

							# Find sequence manually
							for k in range(buffer_bytes.size() - 3):
								if buffer_bytes[k] == 13 and buffer_bytes[k+1] == 10 and buffer_bytes[k+2] == 13 and buffer_bytes[k+3] == 10:
									header_end_idx = k
									break

							if header_end_idx == -1:
								for k in range(buffer_bytes.size() - 1):
									if buffer_bytes[k] == 10 and buffer_bytes[k+1] == 10:
										header_end_idx = k
										header_len = 2
										break

							var req_str = ""
							if header_end_idx != -1:
								req_str = buffer_bytes.slice(0, header_end_idx).get_string_from_utf8()

								if req_str.begins_with("GET " + network.TLS_CERT_PATH + " "):
									# Public by design: clients pin this, and the password check covers its hash
									var pem_bytes = network.get_server_cert_pem().to_utf8_buffer()
									var response_headers = "HTTP/1.1 200 OK\r\nContent-Length: " + str(pem_bytes.size()) + "\r\nConnection: close\r\n\r\n"
									resp["data"].append_array(response_headers.to_utf8_buffer())
									resp["data"].append_array(pem_bytes)
									resp["active"] = true
								elif req_str.begins_with("GET " + network.PLUGIN_UPDATE_PATH + " "):
									# Has its own token, because whoever asks for this was refused entry to the session
									if network.is_valid_update_token(_http_request_token(req_str)):
										var bundle = network.get_plugin_update_bundle()
										var response_headers = "HTTP/1.1 200 OK\r\nContent-Length: " + str(bundle.size()) + "\r\nConnection: close\r\n\r\n"
										resp["data"].append_array(response_headers.to_utf8_buffer())
										resp["data"].append_array(bundle)
									else:
										var response_headers = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
										resp["data"].append_array(response_headers.to_utf8_buffer())
									resp["active"] = true
								elif not _is_http_authorized(req_str):
									var response_headers = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
									resp["data"].append_array(response_headers.to_utf8_buffer())
									resp["active"] = true
								elif req_str.begins_with("GET "):
									var lines_arr = req_str.split("\n")
									if lines_arr.size() > 0:
										var parts = lines_arr[0].split(" ")
										if parts.size() > 1:
											var path = parts[1]
											path = path.uri_decode()
											if path.begins_with("/res/"):
												path = "res://" + path.substr(5)

											if _is_safe_path(path) and FileAccess.file_exists(path):
												var file_bytes = FileAccess.get_file_as_bytes(path)
												var response_headers = "HTTP/1.1 200 OK\r\nContent-Length: " + str(file_bytes.size()) + "\r\nConnection: close\r\n\r\n"
												resp["data"].append_array(response_headers.to_utf8_buffer())
												resp["data"].append_array(file_bytes)
												resp["active"] = true
											else:
												var response_headers = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
												resp["data"].append_array(response_headers.to_utf8_buffer())
												resp["active"] = true
								elif req_str.begins_with("POST "):
									var lines_arr = req_str.split("\n")
									if lines_arr.size() > 0:
										var parts = lines_arr[0].split(" ")
										if parts.size() > 1:
											var path = parts[1]
											path = path.uri_decode()
											if path.begins_with("/res/"):
												path = "res://" + path.substr(5)

											if _is_safe_path(path):
												var content_length = 0
												for req_line in lines_arr:
													var lower_line = req_line.to_lower()
													if lower_line.begins_with("content-length:"):
														content_length = lower_line.split(":")[1].strip_edges().to_int()
														break

												if buffer_bytes.size() >= header_end_idx + header_len + content_length:
													var body_bytes = buffer_bytes.slice(header_end_idx + header_len, header_end_idx + header_len + content_length)

													# receive_file will handle dir creation and writing
													receive_file(path, randi(), body_bytes, true)

													var response_headers = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
													resp["data"].append_array(response_headers.to_utf8_buffer())
													resp["active"] = true

							if not resp["active"]:
								if header_end_idx == -1:
									# Wait for complete headers up to safety threshold (16KB)
									if buffer_bytes.size() > 16384:
										peer.disconnect_from_stream()
										_http_clients.remove_at(i)
										_http_buffers.erase(peer)
										_http_responses.erase(peer)
									continue

								# Check if it's a POST waiting for more body data
								if req_str.begins_with("POST "):
									continue
								peer.disconnect_from_stream()
								_http_clients.remove_at(i)
								_http_buffers.erase(peer)
								_http_responses.erase(peer)
				else:
					# Active response, send in chunks asynchronously
					var to_send = resp["data"].size() - resp["sent"]
					if to_send > 0:
						# TLS accepts one record (16 KB) per call, so send several each frame
						for _record in range(HTTP_MAX_RECORDS_PER_FRAME):
							to_send = resp["data"].size() - resp["sent"]
							if to_send <= 0:
								break
							var chunk = resp["data"].slice(resp["sent"], resp["sent"] + min(to_send, 65536))
							var sent_arr = peer.put_partial_data(chunk)
							if sent_arr[0] == OK:
								if sent_arr[1] <= 0:
									break
								resp["sent"] += sent_arr[1]
								resp["timer"] = 0.0 # Reset timeout on activity
							else:
								if sent_arr[0] != ERR_BUSY:
									# Error
									peer.disconnect_from_stream()
									_http_clients.remove_at(i)
									_http_buffers.erase(peer)
									_http_responses.erase(peer)
								break
					else:
						# Done
						peer.disconnect_from_stream()
						_http_clients.remove_at(i)
						_http_buffers.erase(peer)
						_http_responses.erase(peer)

			else:
				_http_clients.remove_at(i)
				_http_buffers.erase(peer)
				_http_responses.erase(peer)

func _setup_http_server():
	if network and network.get("is_standalone_server"):
		_http_server = TCPServer.new()
		var port = network.PORT if (network and network.get("PORT") != null) else 25567
		var err = _http_server.listen(port)
		if err == OK:
			network.tc_print("HTTP File Server listening on port " + str(port))
		else:
			network.tc_print("Failed to start HTTP File Server on port " + str(port))

func stop_http_server() -> void:
	if _http_server and _http_server.is_listening():
		_http_server.stop()
		for peer in _http_clients:
			if peer and peer.get_status() == StreamPeerTLS.STATUS_CONNECTED:
				peer.disconnect_from_stream()
		_http_clients.clear()
		_http_buffers.clear()
		_http_responses.clear()
		if network:
			network.tc_print("HTTP File Server stopped.")



func _http_request_token(req_str: String) -> String:
	for req_line in req_str.split("\n"):
		if req_line.to_lower().begins_with(HTTP_TOKEN_HEADER.to_lower() + ":"):
			return req_line.split(":", true, 1)[1].strip_edges()
	return ""

func _is_http_authorized(req_str: String) -> bool:
	if not network or network.session_password == "":
		return true
	return network.is_valid_http_token(_http_request_token(req_str))

func _http_auth_headers() -> PackedStringArray:
	if network and network.http_session_token != "":
		return PackedStringArray([HTTP_TOKEN_HEADER + ": " + network.http_session_token])
	return PackedStringArray()

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

	# Compared in lowercase because macOS and Windows filesystems ignore case
	var rel_path = "res://" + target.trim_prefix(base_res).to_lower()

	# Colons reach NTFS alternate streams, and Windows ignores trailing dots and spaces
	if ":" in rel_path.trim_prefix("res://"):
		return false

	# Hidden paths like .git and .env are never synced, and .git/hooks can run code
	for part in rel_path.trim_prefix("res://").split("/"):
		if part.begins_with(".") or part.ends_with(".") or part.ends_with(" "):
			return false

	var blocked_dirs = ["addons/team_create"]
	for d in blocked_dirs:
		if rel_path == "res://" + d or rel_path.begins_with("res://" + d + "/"):
			return false

	# override.cfg replaces project settings at launch, which would bypass settings_sync.gd's rules
	if rel_path == "res://project.godot" or rel_path == "res://override.cfg":
		return false

	return true

func is_safe_scene_path(p: String) -> bool:
	return _is_safe_path(p) and p.get_extension().to_lower() in ["tscn", "scn"]

var _pending_files_to_receive = 0
var downloading_files: Array = []
var _sync_blocker: ColorRect
var _receiving_files: Dictionary = {}
var _known_files: Array = []
var _file_hash_cache: Dictionary = {}
signal sync_completed
var file_transfer_timeout: float = 30.0
var auto_backups_enabled = false
var allow_client_file_deletions = true
var auto_relay_files = true
var _initial_sync_done = false
signal asset_imported(path: String)

var _relay_timer_active: bool = false
var _last_file_received_time: int = 0
var _has_unrelayed_files: bool = false

func _schedule_relay_sync():
	var relay_enabled = auto_relay_files
	if network and "auto_relay_files" in network:
		relay_enabled = network.auto_relay_files
	if not (network and network.is_server and relay_enabled):
		return
	if not is_inside_tree() or get_tree() == null:
		return
	if not network.is_connected_to_session() or multiplayer.get_peers().is_empty():
		return

	_last_file_received_time = Time.get_ticks_msec()
	if _relay_timer_active:
		return

	_relay_timer_active = true
	_check_relay_after_delay()

func _check_relay_after_delay():
	if not is_inside_tree() or get_tree() == null:
		_relay_timer_active = false
		return

	get_tree().create_timer(0.5).timeout.connect(func():
		if not is_instance_valid(self) or not is_inside_tree() or get_tree() == null:
			_relay_timer_active = false
			return

		var now = Time.get_ticks_msec()
		if now - _last_file_received_time < 450:
			_check_relay_after_delay()
			return

		_relay_timer_active = false

		var relay_enabled = auto_relay_files
		if network and "auto_relay_files" in network:
			relay_enabled = network.auto_relay_files
		if not (network and network.is_server and relay_enabled and _has_unrelayed_files):
			return
		if not network.is_connected_to_session() or multiplayer.get_peers().is_empty():
			return
		if _pending_files_to_receive > 0 or not downloading_files.is_empty():
			_schedule_relay_sync()
			return

		_has_unrelayed_files = false
		network.tc_print("Team Create: Auto-relaying updated project files to connected peers...")
		sync_all_files()
	)

func backup_scene(path: String, is_manual: bool = false) -> String:
	if not is_manual and not auto_backups_enabled:
		return ""
	if not FileAccess.file_exists(path):
		return ""
	var base_backup_dir = "res://.team_create/backups"
	if not DirAccess.dir_exists_absolute(base_backup_dir):
		DirAccess.make_dir_recursive_absolute(base_backup_dir)
	var time_str = Time.get_datetime_string_from_system().replace(":", "-")
	var scene_name = path.get_file().get_basename()
	var ext = path.get_extension()
	var backup_path = base_backup_dir + "/" + scene_name + "_" + time_str + "." + ext
	var bytes = FileAccess.get_file_as_bytes(path)
	var f = FileAccess.open(backup_path, FileAccess.WRITE)
	if f:
		f.store_buffer(bytes)
		f.close()
		if network:
			network.tc_print("Team Create: Backup created: ", backup_path)
		return backup_path
	return ""

func request_asset_immediately(path: String, sender_id: int = 1):
	if not _is_safe_path(path):
		return

	var is_importable = not (path.ends_with(".tscn") or path.ends_with(".scn") or path.ends_with(".gd") or path.ends_with(".tres"))
	var file_exists = FileAccess.file_exists(path)
	var is_safe_loaded = false
	if network and network.scene_sync:
		is_safe_loaded = network.scene_sync._safe_resource_exists(path)

	if file_exists:
		if is_safe_loaded:
			asset_imported.emit(path)
			return
		elif is_importable:
			var ei = _get_editor_interface()
			if ei and ei.get_resource_filesystem() and not ei.get_resource_filesystem().is_scanning():
				ei.get_resource_filesystem().scan()

	if network and network.is_connected_to_session():
		var target_id = sender_id
		if target_id == 0 or target_id == multiplayer.get_unique_id():
			target_id = 1
		rpc_id(target_id, "request_asset_package", path)

@rpc("any_peer", "reliable")
func request_asset_package(path: String):
	if not _is_safe_path(path):
		return
	var sender_id = multiplayer.get_remote_sender_id()
	var asset_bytes = PackedByteArray()
	var import_bytes = PackedByteArray()
	if FileAccess.file_exists(path):
		asset_bytes = FileAccess.get_file_as_bytes(path)
	if FileAccess.file_exists(path + ".import"):
		import_bytes = FileAccess.get_file_as_bytes(path + ".import")

	if asset_bytes.size() > 0:
		rpc_id(sender_id, "deliver_asset_package", path, asset_bytes, import_bytes)

@rpc("any_peer", "reliable")
func deliver_asset_package(path: String, asset_bytes: PackedByteArray, import_bytes: PackedByteArray):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if network and not network.is_server and sender_id != 1 and sender_id != 0:
		return
	if not _is_safe_path(path):
		return
	var dir_path = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	if asset_bytes.size() > 0:
		_file_write_mutex.lock()
		var f = FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_buffer(asset_bytes)
			f.close()
		if import_bytes.size() > 0:
			var fi = FileAccess.open(path + ".import", FileAccess.WRITE)
			if fi:
				fi.store_buffer(import_bytes)
				fi.close()
		_file_write_mutex.unlock()

		if _file_hash_cache.has(path):
			_file_hash_cache.erase(path)

		var ei = _get_editor_interface()
		if ei and ei.get_resource_filesystem() and not ei.get_resource_filesystem().is_scanning():
			ei.get_resource_filesystem().scan()

		asset_imported.emit(path)
		if network:
			network.tc_print("Team Create: Immediately received and reimported requested asset: ", path)



func _show_sync_blocker():
	if not _sync_blocker:
		var editor = _get_editor_interface()
		if not editor: return
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

		# Failsafe timer: automatically dismiss blocker if stuck for more than 15 seconds
		var blocker_ref = weakref(_sync_blocker)
		get_tree().create_timer(15.0).timeout.connect(func():
			var b = blocker_ref.get_ref()
			if b and is_instance_valid(b):
				printerr("Team Create: Sync blocker timed out waiting for files, dismissing.")
				_hide_sync_blocker()
				downloading_files.clear()
				_pending_files_to_receive = 0
				_known_files = get_all_files("res://")
				sync_completed.emit()
		)

func _update_sync_blocker():
	if _sync_blocker:
		var label = _sync_blocker.get_node_or_null("SyncLabel")
		if label:
			var txt = "Syncing Files... (" + str(_pending_files_to_receive) + " remaining)"
			if downloading_files.size() > 0:
				txt += "\nWaiting for: " + downloading_files[0]
			label.text = txt

func _hide_sync_blocker():
	if _sync_blocker:
		_sync_blocker.queue_free()
		_sync_blocker = null

func _ready():
	call_deferred("_setup_fs_signals")
	sync_completed.connect(func():
		_initial_sync_done = true
		if network and network.has_method("show_toast"):
			network.show_toast("Project assets synchronized", 0)
	)

func _setup_fs_signals():
	var ei = _get_editor_interface()
	if ei:
		var efs = ei.get_resource_filesystem()
		if efs:
			if not efs.filesystem_changed.is_connected(_on_filesystem_changed):
				efs.filesystem_changed.connect(_on_filesystem_changed)

func _on_filesystem_changed():
	if _is_syncing_files or not (network and network.is_connected_to_session()) or multiplayer.get_peers().is_empty():
		return

	var current_files = get_all_files("res://")
	var current_files_dict = {}
	for path in current_files:
		current_files_dict[path] = true

	var known_files_dict = {}
	for path in _known_files:
		known_files_dict[path] = true

	# Clear cache entries for files that were removed
	var keys_to_remove = []
	for path in _file_hash_cache.keys():
		if not current_files_dict.has(path):
			keys_to_remove.append(path)
	for path in keys_to_remove:
		_file_hash_cache.erase(path)

	# Check for local files that exceed max_file_size
	if network and network.max_file_size > 0:
		var removed_any = false
		var i = current_files.size() - 1
		while i >= 0:
			var path = current_files[i]
			if not known_files_dict.has(path):
				var f = FileAccess.open(path, FileAccess.READ)
				if f:
					var size = f.get_length()
					f.close()
					if size > network.max_file_size:
						_move_to_trash(path)
						network.tc_print_rich("[color=red]Warning: File " + path + " is too large (max " + str(network.max_file_size / (1024 * 1024.0)) + " MB). It was deleted and not synced.[/color]")
						if _file_hash_cache.has(path):
							_file_hash_cache.erase(path)
						removed_any = true
						current_files.remove_at(i)
						current_files_dict.erase(path)
			i -= 1

		if removed_any:
			# Scan again so editor notices deleted files
			var ei = _get_editor_interface()
			if ei and ei.get_resource_filesystem():
				ei.get_resource_filesystem().scan()

	# Automatically sync files whenever Godot detects a local file system change.
	sync_all_files(current_files)

	# Check for local deletions and broadcast them ONLY if initial sync has completed,
	# we are not currently syncing/downloading, and the file was genuinely verified to exist locally previously.
	if _initial_sync_done and not _is_syncing_files and downloading_files.is_empty():
		for known_path in _known_files:
			if not current_files_dict.has(known_path):
				if not _is_safe_path(known_path):
					continue
				# Verify this path was genuinely present and cached on disk before deletion
				if _file_hash_cache.has(known_path) or not FileAccess.file_exists(known_path):
					rpc("remote_delete_file", known_path)

	_known_files = current_files.duplicate()

func sync_all_files(all_files: Array = []):
	_is_syncing_files = true
	if all_files.is_empty():
		all_files = get_all_files("res://")
	var file_hashes = {}
	for path in all_files:
		if path.begins_with("res://addons/team_create"):
			continue
		file_hashes[path] = _get_cached_md5(path)
	if network and network.is_server:
		var relay_enabled = auto_relay_files
		if network and "auto_relay_files" in network:
			relay_enabled = network.auto_relay_files
		if relay_enabled:
			rpc("compare_and_sync_files", file_hashes)
	elif network and network.is_connected_to_session() and multiplayer.get_unique_id() != 1:
		rpc_id(1, "compare_and_sync_files", file_hashes)
	_is_syncing_files = false

func sync_all_files_to_peer(id: int, all_files: Array = []):
	if network and network.is_server:
		if all_files.is_empty():
			all_files = get_all_files("res://")
		var file_hashes = {}
		for path in all_files:
			if path.begins_with("res://addons/team_create"):
				continue
			file_hashes[path] = _get_cached_md5(path)
		rpc_id(id, "compare_and_sync_files", file_hashes)

func get_all_files(dir_path: String, exclude_dirs: Array = []) -> Array:
	var files = []
	var dir = DirAccess.open(dir_path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir():
				var sub_dir = dir_path.path_join(file_name)
				if not file_name.begins_with("."):
					if not exclude_dirs.has(sub_dir):
						files.append_array(get_all_files(sub_dir, exclude_dirs))
			elif not dir.current_is_dir() and not file_name.begins_with("."):
				var full_path = dir_path.path_join(file_name)

				# Convert local .tmp files to real assets instantly, as requested.
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
					network.tc_print("Converted temporary file to real asset: ", real_path)
					# Trigger editor refresh
					var ei = _get_editor_interface()
					if ei and ei.get_resource_filesystem():
						ei.get_resource_filesystem().scan()
				else:
					if full_path != "res://project.godot" and full_path != "res://override.cfg":
						files.append(full_path)
			file_name = dir.get_next()
	return files

# Nothing the plugin removes is destroyed: it goes to the trash folder under its project path,
# and an older copy already there is kept too (name.gd, name.gd.1, ...).
func _move_to_trash(path: String) -> Error:
	var base = "res://.team_create/trash/" + path.trim_prefix("res://")
	DirAccess.make_dir_recursive_absolute(base.get_base_dir())
	var dest = base
	var copy = 1
	while FileAccess.file_exists(dest):
		dest = base + "." + str(copy)
		copy += 1
	return DirAccess.rename_absolute(path, dest)

@rpc("any_peer", "reliable")
func compare_and_sync_files(peer_hashes: Dictionary):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if network and not network.is_server and sender_id != 1 and sender_id != 0:
		return # Clients strictly sync from the authoritative server (peer 1)

	_is_syncing_files = true
	var local_files = get_all_files("res://")
	var local_hashes = {}

	for path in local_files:
		if path.begins_with("res://addons/team_create"):
			continue
		local_hashes[path] = _get_cached_md5(path)

	var open_scenes = []
	var ei = _get_editor_interface()
	if ei:
		open_scenes = ei.get_open_scenes()

	# Find files to delete (only allow the server to delete files to prevent clients wiping the server)
	if sender_id == 1:
		for path in local_hashes:
			if path.begins_with("res://.godot/"):
				continue
			if not peer_hashes.has(path):
				if path in open_scenes:
					network.tc_print("Skipping deletion of open scene: ", path)
					continue
				if _move_to_trash(path) != OK:
					continue
				network.tc_print("Moved file the server doesn't have to trash: ", path)
				if _file_hash_cache.has(path):
					_file_hash_cache.erase(path)

	# Request differing files
	var files_to_request = []
	for path in peer_hashes:
		if path == "res://project.godot" or path == "res://override.cfg" or path.begins_with("res://.godot/"):
			continue

		# Server is authoritative for scenes: The server never downloads existing scenes over its own copy
		if network and network.is_server and local_hashes.has(path):
			if path.ends_with(".tscn") or path.ends_with(".scn"):
				continue

		# Don't request a scene file if we recently saved it locally (within 5 seconds)
		if network and network.get("_recently_saved_scenes") and network._recently_saved_scenes.has(path):
			if Time.get_ticks_msec() - network._recently_saved_scenes[path] < 5000:
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


	var use_http = false
	if network and sender_id == 1 and network.peers.has(1) and network.peers[1].has("is_standalone") and network.peers[1]["is_standalone"]:
		use_http = true

	_pending_files_to_receive = files_to_request.size()
	downloading_files.clear()
	downloading_files.append_array(files_to_request)
	_http_download_queue.clear()
	_http_download_retries.clear()

	_known_files = local_files.duplicate()

	if _pending_files_to_receive > 0:
		call_deferred("_show_sync_blocker")
		call_deferred("_update_sync_blocker")

	for path in files_to_request:

		if use_http:
			_download_file_http(path)
		else:
			rpc_id(sender_id, "request_file", path)


	if _pending_files_to_receive == 0:
		sync_completed.emit()

	_is_syncing_files = false


func _download_file_http(path: String):
	if _http_downloads_active >= HTTP_MAX_CONCURRENT_DOWNLOADS:
		_http_download_queue.append(path)
		return
	_http_downloads_active += 1
	var http_request = HTTPRequest.new()
	http_request.timeout = file_transfer_timeout
	http_request.set_tls_options(network.client_tls_options)
	add_child(http_request)
	http_request.request_completed.connect(self._http_download_completed.bind(http_request, path))

	var ip = network.server_ip
	if ip == "":
		ip = "127.0.0.1"
	var port = network.PORT if (network and network.get("PORT") != null) else 25567

	var raw_path = path.replace("res://", "/res/")
	var path_parts = raw_path.split("/")
	for i in range(path_parts.size()):
		path_parts[i] = path_parts[i].uri_encode()
	var encoded_path = "/".join(path_parts)
	var url = "https://" + ip + ":" + str(port) + encoded_path

	var error = http_request.request(url, _http_auth_headers())
	if error != OK:
		printerr("HTTP Request failed for ", path)
		http_request.queue_free()
		_finish_http_download(path)
		_start_next_http_download()

func _http_download_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest, path: String):
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
		_http_download_retries.erase(path)
		receive_file(path, randi(), body, true)
	elif response_code == 0 and _http_download_retries.get(path, 0) < HTTP_MAX_DOWNLOAD_RETRIES:
		# Never reached the server, so it's worth another go
		_http_download_retries[path] = _http_download_retries.get(path, 0) + 1
		_http_download_queue.append(path)
	else:
		_http_download_retries.erase(path)
		var message = "Failed to download " + path + ". Reconnect to try again."
		printerr(message, " Result: ", result, " Response: ", response_code)
		if network and network.has_method("show_toast"):
			network.show_toast(message, 2)
		_finish_http_download(path)

	http_request.queue_free()
	_start_next_http_download()

func _start_next_http_download() -> void:
	_http_downloads_active -= 1
	if not _http_download_queue.is_empty():
		_download_file_http(_http_download_queue.pop_front())


func _upload_file_http(path: String, bytes: PackedByteArray):
	var http_request = HTTPRequest.new()
	http_request.timeout = file_transfer_timeout
	http_request.set_tls_options(network.client_tls_options)
	add_child(http_request)
	http_request.request_completed.connect(self._http_upload_completed.bind(http_request, path))

	var ip = network.server_ip
	if ip == "":
		ip = "127.0.0.1"
	var port = network.PORT if (network and network.get("PORT") != null) else 25567

	var raw_path = path.replace("res://", "/res/")
	var path_parts = raw_path.split("/")
	for i in range(path_parts.size()):
		path_parts[i] = path_parts[i].uri_encode()
	var encoded_path = "/".join(path_parts)
	var url = "https://" + ip + ":" + str(port) + encoded_path

	var headers = _http_auth_headers()
	headers.append("Content-Type: application/octet-stream")
	var error = http_request.request_raw(url, headers, HTTPClient.METHOD_POST, bytes)
	if error != OK:
		printerr("HTTP POST Request failed for ", path)
		http_request.queue_free()

func _http_upload_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest, path: String):
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		printerr("Failed to upload file via HTTP: ", path, " Response: ", response_code)
	http_request.queue_free()

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

		var use_http = false
		if network and sender_id == 1 and network.peers.has(1) and network.peers[1].has("is_standalone") and network.peers[1]["is_standalone"]:
			use_http = true

		if use_http:
			_upload_file_http(path, bytes)
		else:
			rpc_id(sender_id, "receive_file", path, randi(), bytes, true)
	else:
		rpc_id(sender_id, "receive_file", path, randi(), PackedByteArray(), true)

@rpc("any_peer", "reliable")
func receive_file(path: String, transfer_id: int, bytes: PackedByteArray, is_final: bool = true):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if network and not network.is_server and sender_id != 1 and sender_id != 0:
		return # Clients only accept files delivered by the server
	if not _is_safe_path(path):
		printerr("Team Create: Unauthorized or invalid file path received: ", path)
		downloading_files.erase(path)
		if _pending_files_to_receive > 0:
			_pending_files_to_receive -= 1
			call_deferred("_update_sync_blocker")
			if _pending_files_to_receive <= 0:
				call_deferred("_hide_sync_blocker")
				_known_files = get_all_files("res://")
				sync_completed.emit()
		return

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
	if network and network.scene_sync and (path.ends_with(".tscn") or path.ends_with(".scn")):
		var ei = _get_editor_interface()
		var current_scene: Node = null
		var open_scenes = []
		if ei:
			current_scene = ei.get_edited_scene_root()
			open_scenes = ei.get_open_scenes()

		if path in open_scenes:
			if FileAccess.file_exists(path):
				var current_disk_bytes = FileAccess.get_file_as_bytes(path)
				if current_disk_bytes.size() == bytes.size() and current_disk_bytes == bytes:
					downloading_files.erase(path)
					if _pending_files_to_receive > 0:
						_pending_files_to_receive -= 1
						call_deferred("_update_sync_blocker")
						if _pending_files_to_receive <= 0:
							call_deferred("_hide_sync_blocker")
							_known_files = get_all_files("res://")
							sync_completed.emit()
					if network and network.scene_sync:
						network.scene_sync._synced_scene_states[path] = true
						network.scene_sync._last_scene_path = path
					return

			var merge_data = {}
			if network and network.scene_sync and not network.is_server:
				merge_data = network.scene_sync.prepare_offline_scene_merge(path, bytes)

			var is_active = current_scene and current_scene.scene_file_path == path
			if is_active:
				network.tc_print("Team Create: Applying received file to active scene view.")
			else:
				network.tc_print("Team Create: Applying received file to open background scene.")

			if bytes.size() > 0:
				backup_scene(path)
				_file_write_mutex.lock()
				var tmp_path = path + ".tmp"
				var file = FileAccess.open(tmp_path, FileAccess.WRITE)
				var saved_ok = false
				if file:
					file.store_buffer(bytes)
					file.close()
					if DirAccess.remove_absolute(path) == OK or not FileAccess.file_exists(path):
						if DirAccess.rename_absolute(tmp_path, path) == OK:
							saved_ok = true
					if not saved_ok:
						file = FileAccess.open(path, FileAccess.WRITE)
						if file:
							file.store_buffer(bytes)
							file.close()
						DirAccess.remove_absolute(tmp_path)
				_file_write_mutex.unlock()

			if network and network.scene_sync:
				network.scene_sync._is_reloading_scene = true
				network.scene_sync._last_scene_path = path
				network.scene_sync._synced_scene_states[path] = true
				if is_active:
					network.scene_sync._force_full_sync_next_frame = true

			var prev_path = current_scene.scene_file_path if current_scene else ""
			ei.reload_scene_from_path(path)

			if not is_active and prev_path != "":
				# reload_scene_from_path might change the active tab, so we switch back just in case
				ei.open_scene_from_path(prev_path)

			get_tree().create_timer(0.5).timeout.connect(func():
				if is_instance_valid(network) and network.scene_sync:
					network.scene_sync._is_reloading_scene = false
					network.scene_sync._last_scene_path = path
					if is_active and merge_data.size() > 0 and merge_data.get("added_nodes", []).size() > 0:
						network.scene_sync.apply_offline_merge_deferred(path, merge_data)
			)

			downloading_files.erase(path)
			if _pending_files_to_receive > 0:
				_pending_files_to_receive -= 1
				call_deferred("_update_sync_blocker")
				if _pending_files_to_receive <= 0:
					call_deferred("_hide_sync_blocker")
					_known_files = get_all_files("res://")
					sync_completed.emit()
					if network and network.is_server and _has_unrelayed_files:
						_schedule_relay_sync()
			elif network and network.is_server and _has_unrelayed_files:
				_schedule_relay_sync()

			return

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
			if path.ends_with(".tscn") or path.ends_with(".scn"):
				backup_scene(path)
				if network and network.scene_sync and not network.is_server:
					network.scene_sync.prepare_offline_scene_merge(path, bytes)
			_file_write_mutex.lock()
			var file = FileAccess.open(path + ".tmp", FileAccess.WRITE)
			if file:
				file.store_buffer(bytes)
				file.close()
				if DirAccess.remove_absolute(path) == OK or not FileAccess.file_exists(path):
					DirAccess.rename_absolute(path + ".tmp", path)
				network.tc_print("Received and updated file: ", path)
			_file_write_mutex.unlock()
			if _file_hash_cache.has(path):
				_file_hash_cache.erase(path)

			var relay_enabled = auto_relay_files
			if network and "auto_relay_files" in network:
				relay_enabled = network.auto_relay_files
			if network and network.is_server and relay_enabled:
				_has_unrelayed_files = true
		else:
			pass

		asset_imported.emit(path)

	downloading_files.erase(path)
	if _pending_files_to_receive > 0:
		_pending_files_to_receive -= 1
		call_deferred("_update_sync_blocker")
		if _pending_files_to_receive <= 0:
			call_deferred("_hide_sync_blocker")
			_known_files = get_all_files("res://")
			sync_completed.emit()
			if network and network.is_server and _has_unrelayed_files:
				_schedule_relay_sync()
	elif network and network.is_server and _has_unrelayed_files:
		_schedule_relay_sync()

	if _pending_files_to_receive <= 0:
		# Trigger Editor resource scan only once ALL files are downloaded and saved
		var ei_scan = _get_editor_interface()
		if ei_scan and ei_scan.get_resource_filesystem():
			if _scan_timer == null:
				_scan_timer = get_tree().create_timer(0.3)
				_scan_timer.timeout.connect(func():
					_scan_timer = null
					var e = _get_editor_interface()
					if e and e.get_resource_filesystem():
						e.get_resource_filesystem().scan()
				)


@rpc("any_peer", "reliable")
func remote_delete_file(path: String):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 1
	var is_srv = network and network.is_server
	if not is_srv and sender_id != 1 and sender_id != 0:
		return # Clients only accept file deletions from the server

	if not _is_safe_path(path):
		return

	# If received on server from a client, check setting
	if is_srv and sender_id != 1:
		var allow_del = allow_client_file_deletions
		if network and "allow_client_file_deletions" in network:
			allow_del = network.allow_client_file_deletions
		if not allow_del:
			network.tc_print("Team Create: Blocked client deletion request for ", path, " (allow_client_file_deletions is false)")
			return

	# If on a client and message did NOT come from server (peer 1), reject
	if not is_srv and sender_id != 1:
		return

	if FileAccess.file_exists(path):
		if _move_to_trash(path) == OK:
			network.tc_print("Team Create: Replicated file deletion, moved to trash: ", path)

		if _file_hash_cache.has(path):
			_file_hash_cache.erase(path)

		if _known_files.has(path):
			_known_files.erase(path)

		var ei = _get_editor_interface()
		if ei and ei.get_resource_filesystem():
			ei.get_resource_filesystem().scan()

	# If server received and approved client deletion, broadcast to all OTHER clients
	if is_srv and sender_id != 0:
		if network and network.multiplayer:
			for peer_id in network.multiplayer.get_peers():
				if peer_id != sender_id and peer_id != 1:
					rpc_id(peer_id, "remote_delete_file", path)

func _finish_http_download(path: String):
	downloading_files.erase(path)
	if _pending_files_to_receive > 0:
		_pending_files_to_receive -= 1
		call_deferred("_update_sync_blocker")
		if _pending_files_to_receive <= 0:
			call_deferred("_hide_sync_blocker")
			_known_files = get_all_files("res://")
			sync_completed.emit()
			if network and network.is_server and _has_unrelayed_files:
				_schedule_relay_sync()
	elif network and network.is_server and _has_unrelayed_files:
		_schedule_relay_sync()

func set_file_timeout(seconds: float):
	file_transfer_timeout = clamp(seconds, 5.0, 300.0)
