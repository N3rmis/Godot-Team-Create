@tool
extends Node

const ADJECTIVES = ["Fast", "Cool", "Smart", "Brave", "Wild", "Quick", "Sly", "Bold"]
const NOUNS = ["Cat", "Dog", "Fox", "Bear", "Wolf", "Hawk", "Owl", "Lion"]

const PORT = 12345
const MAX_CLIENTS = 10

var ui: Control
var plugin: Node
var peer = ENetMultiplayerPeer.new()
var is_server = false
var is_standalone_server = false
var peers = {} # Dictionary mapping peer_id to user info (username, color)
var _color_assignment_counter = 0
var _assigned_colors = []
var file_sync
var scene_sync

# WebRTC
var webrtc_peer: WebRTCMultiplayerPeer
var webrtc_connection: WebRTCPeerConnection
var is_webrtc = false
var webrtc_candidates = []
var local_sdp_type = ""
var local_sdp = ""
var _local_username = ""
# Console thread
var _console_thread: Thread
var _console_should_exit: bool = false


func _ready():
	if is_standalone_server:
		_console_thread = Thread.new()
		_console_thread.start(Callable(self, "_server_console_thread_func"))

	call_deferred("_init_editor_settings")
	name = "TeamCreateNetwork"
	# Load sync modules
	var file_sync_script = load("res://addons/team_create/file_sync.gd")
	if file_sync_script:
		file_sync = file_sync_script.new()
		file_sync.name = "TeamCreateFileSync"
		file_sync.network = self
		add_child(file_sync)

	var scene_sync_script = load("res://addons/team_create/scene_sync.gd")
	if scene_sync_script:
		scene_sync = scene_sync_script.new()
		scene_sync.name = "TeamCreateSceneSync"
		scene_sync.network = self
		add_child(scene_sync)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _exit_tree():
	if _console_thread and _console_thread.is_started():
		_console_should_exit = true
		# We do not wait_to_finish() here because read_string_from_stdin() blocks infinitely
		# and attempting to wait will cause the server to hang on shutdown.
		# Godot will forcefully clean up the thread when the process exits.


func _server_console_thread_func():
	print_rich("[color=green]Server console ready. Type /help for a list of commands.[/color]")
	while not _console_should_exit:
		# OS.read_string_from_stdin is blocking. It will wake up when the user hits Enter.
		var input = OS.read_string_from_stdin().strip_edges()
		if input == "":
			OS.delay_msec(50)
			continue
		call_deferred("_process_console_command", input)

func _process_console_command(input: String):
	var args = input.split(" ")
	var cmd = args[0].to_lower()

	if cmd == "/help":
		print_rich("[color=cyan]--- Available Commands ---[/color]")
		print_rich("[color=white]/kick <user>[/color]   - Kicks a user from the server")
		print_rich("[color=white]/list[/color]          - Lists all connected users")
		print_rich("[color=white]/info[/color]          - Shows server statistics (memory, CPU, players, etc.)")
		print_rich("[color=white]/update[/color]        - Downloads latest update and restarts the server")
		print_rich("[color=white]/restart[/color]       - Restarts the server")
		print_rich("[color=white]/stop[/color]          - Stops and exits the server")
		print_rich("[color=cyan]--------------------------[/color]")

	elif cmd == "/kick":
		if args.size() < 2:
			print_rich("[color=orange]Usage: /kick <username>[/color]")
		else:
			var target_username = args[1]
			var target_id = -1
			for id in peers.keys():
				if peers[id]["username"] == target_username:
					target_id = id
					break
			if target_id != -1:
				if target_id == 1:
					print_rich("[color=red]Cannot kick the server.[/color]")
				else:
					print_rich("[color=yellow]Kicking user: " + target_username + "[/color]")
					call_deferred("kick_peer", target_id)
			else:
				print_rich("[color=red]User not found: " + target_username + "[/color]")

	elif cmd == "/update":
		print_rich("[color=cyan]Updating plugin and restarting server...[/color]")
		if plugin and plugin.has_method("download_update"):
			call_deferred("_deferred_update_and_restart")
		else:
			print_rich("[color=red]Update mechanism not available.[/color]")

	elif cmd == "/list":
		print_rich("[color=cyan]Connected users:[/color]")
		if is_webrtc:
			print_rich("[color=gray] (IPs not available for WebRTC)[/color]")
		var count = 0
		for id in peers.keys():
			if id == 1:
				continue # Skip the server
			var info = peers[id]
			var ip_str = "N/A"
			if not is_webrtc and multiplayer.multiplayer_peer is ENetMultiplayerPeer:
				ip_str = multiplayer.multiplayer_peer.get_peer(id).get_remote_address()
			print_rich("[color=white]- " + info["username"] + " (ID: " + str(id) + ", IP: " + ip_str + ")[/color]")
			count += 1
		print_rich("[color=green]Total users: " + str(count) + "[/color]")

	elif cmd == "/restart":
		print_rich("[color=orange]Restarting server...[/color]")
		call_deferred("_deferred_restart")

	elif cmd == "/stop":
		print_rich("[color=red]Stopping server...[/color]")
		call_deferred("_deferred_stop")

	elif cmd == "/info":
		print_rich("[color=cyan]--- Server Info ---[/color]")
		print_rich("[color=white]Memory Usage:[/color] " + String.humanize_size(OS.get_static_memory_usage()))
		print_rich("[color=white]Peak Memory Usage:[/color] " + String.humanize_size(OS.get_static_memory_peak_usage()))
		var cpu_usage = Performance.get_monitor(Performance.TIME_PROCESS) * Engine.get_frames_per_second() * 100.0
		print_rich("[color=white]CPU Usage:[/color] " + ("%.2f" % cpu_usage) + "%")
		var port = str(PORT) if not is_webrtc else "WebRTC"
		var local_ip = "127.0.0.1"
		for address in IP.get_local_addresses():
			if address.split(".").size() == 4 and not address.begins_with("127.") and not address.begins_with("169.254."):
				local_ip = address
				break
		print_rich("[color=white]Network:[/color] " + local_ip + ":" + str(port) if not is_webrtc else "[color=white]Network:[/color] WebRTC")
		var user_count = peers.size() - 1 if peers.has(1) else peers.size()
		print_rich("[color=white]Total users connected:[/color] " + str(user_count))
		print_rich("[color=cyan]-------------------[/color]")
	else:
		print_rich("[color=red]Unknown command: " + cmd + "[/color]")

func _deferred_update_and_restart():
	if plugin and plugin.has_method("download_update"):
		plugin.download_update()
		# Actual restart is handled when extraction completes

func _deferred_restart():
	# Clean up network connections before restarting
	disconnect_peer()

	var exec_path = OS.get_executable_path()
	var args = OS.get_cmdline_args()

	if OS.has_method("set_restart_on_exit"):
		OS.set_restart_on_exit(true, args)
	elif OS.has_method("create_instance"):
		OS.create_instance(args)
	elif OS.has_method("create_process"):
		OS.create_process(exec_path, args)
	else:
		print("Restart not supported on this platform/version. Stopping instead.")

	_deferred_stop()

func _deferred_stop():
	disconnect_peer()

	if _console_thread and _console_thread.is_started():
		_console_should_exit = true

	get_tree().quit(0)

func kick_peer(id: int):
	if is_server and id != 1:
		if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
			multiplayer.multiplayer_peer.disconnect_peer(id)
		elif webrtc_peer:
			webrtc_peer.remove_peer(id)
		print("Kicked peer ", id)

func update_local_username(new_name: String):
	_local_username = new_name
	var my_id = multiplayer.get_unique_id()
	if multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		if is_server:
			request_username_change(my_id, _local_username)
		elif my_id != 1:
			rpc_id(1, "request_username_change", my_id, _local_username)

func host_server():
	peer.create_server(PORT, MAX_CLIENTS)
	multiplayer.multiplayer_peer = peer
	is_server = true
	_add_peer(1)
	_update_ui_state()

func join_server(ip: String):
	peer.create_client(ip, PORT)
	multiplayer.multiplayer_peer = peer
	is_server = false
	_add_peer(multiplayer.get_unique_id())

func disconnect_peer():
	if is_webrtc:
		if webrtc_peer:
			webrtc_peer.close()
		webrtc_peer = null
		webrtc_connection = null
		is_webrtc = false
	else:
		if peer:
			peer.close()
	if scene_sync:
		scene_sync.clear_all_peer_indicators()
	multiplayer.multiplayer_peer = null
	peers.clear()
	_color_assignment_counter = 0
	_assigned_colors.clear()
	if ui:
		ui.set_disconnected()
	if file_sync:
		file_sync._hide_sync_blocker()
	print("Disconnected")

func _add_peer(id: int):
	if not peers.has(id):
		if is_server:
			peers[id] = _generate_peer_info(id)
			if id != 1:
				rpc("sync_peer_info", id, peers[id])
		else:
			peers[id] = _get_default_peer_info(id) # temporary fallback until server syncs

func _on_peer_connected(id: int):
	print("Peer connected: ", id)
	_add_peer(id)
	if ui:
		ui.update_users_count(peers.size())

	_update_ui_state()

	if is_server:
		# Auto sync all files when a peer joins
		call_deferred("sync_all_files_to_peer", id)
		# NOTE: We DO NOT push the scene here anymore! The client will request it when file sync finishes.
		# Send current peer list to the new peer
		for existing_id in peers.keys():
			rpc_id(id, "sync_peer_info", existing_id, peers[existing_id])

		# Inform all other peers about the new peer with its server-assigned info
		for peer_id in peers.keys():
			if peer_id != 1 and peer_id != id:
				rpc_id(peer_id, "sync_peer_info", id, peers[id])



func _on_peer_disconnected(id: int):
	print("Peer disconnected: ", id)
	if peers.has(id):
		peers.erase(id)
	if ui:
		ui.update_users_count(peers.size())

	# Clear selection outlines for disconnected peer
	if scene_sync:
		scene_sync.clear_peer_selections(id)
		scene_sync._clear_peer_cursor(id)

func _on_connected_to_server():
	print("Connected to server successfully!")
	_add_peer(1) # Add server to peers list
	_update_ui_state()

	# Wait for the initial file sync to complete before asking for the scene
	if file_sync:
		if not file_sync.sync_completed.is_connected(_request_scene_from_server):
			file_sync.sync_completed.connect(_request_scene_from_server, CONNECT_ONE_SHOT)

	# Send local username request if not server
	if _local_username != "":
		if not is_server and multiplayer.get_unique_id() != 1:
			rpc_id(1, "request_username_change", multiplayer.get_unique_id(), _local_username)

func _request_scene_from_server():
	if plugin:
		var efs = plugin.get_editor_interface().get_resource_filesystem()
		# Give a slight delay for scans to start/catch up
		await get_tree().create_timer(0.6).timeout
		# Wait for scanning to finish
		while efs.is_scanning():
			await get_tree().process_frame

		var scene_path = ""
		var current_scene = plugin.get_editor_interface().get_edited_scene_root()
		if current_scene:
			scene_path = current_scene.scene_file_path
		rpc_id(1, "request_push_scene", scene_path)
	else:
		rpc_id(1, "request_push_scene", "")

@rpc("any_peer", "reliable")
func sync_peer_info(id: int, info: Dictionary):
	# Only the server should dictate peer info to avoid race conditions and enforce color assignments.
	if not is_server and multiplayer.get_remote_sender_id() != 1:
		return
	peers[id] = info

	# Update 3D cursor labels if username changed
	if scene_sync and scene_sync.has_method("_update_cursor_username"):
		scene_sync._update_cursor_username(id, info["username"])
	if ui:
		ui.update_users_count(peers.size())

@rpc("any_peer", "reliable")
func request_username_change(id: int, new_username: String):
	if is_server:
		if peers.has(id) and (multiplayer.get_remote_sender_id() == id or multiplayer.get_remote_sender_id() == 0):
			peers[id]["username"] = new_username
			rpc("sync_peer_info", id, peers[id])
			# Server updates its own
			sync_peer_info(id, peers[id])

func _on_connection_failed():
	print("Connection to server failed.")
	disconnect_peer()

func _on_server_disconnected():
	print("Server disconnected.")
	disconnect_peer()

func _update_ui_state():
	if ui:
		var connected_to_standalone = false
		if peers.has(1) and peers[1].has("is_standalone") and peers[1]["is_standalone"]:
			connected_to_standalone = true
		ui.set_connected(is_server, connected_to_standalone)
		var username = get_username(multiplayer.get_unique_id())
		var protocol = "WebRTC" if is_webrtc else ("Server" if connected_to_standalone else "LAN")
		ui.status_label.text = "Status: " + username + " Connected (" + protocol + ")"
		ui.update_users_count(peers.size())

func push_current_scene():
	if scene_sync:
		scene_sync.push_current_scene()

func push_current_scene_to_peer(id: int):
	if scene_sync:
		scene_sync.push_current_scene_to_peer(id)

@rpc("any_peer", "reliable")
func request_push_scene(client_scene_path: String = ""):
	if is_server:
		if scene_sync and client_scene_path != "":
			scene_sync.push_specific_scene_to_peer(client_scene_path, multiplayer.get_remote_sender_id())
		else:
			push_current_scene_to_peer(multiplayer.get_remote_sender_id())


# Maps dummy resource paths back to original paths
var _dummy_path_to_original = {}
var _original_to_dummy_path = {}

func _get_or_create_dummy_resource(original_path: String, type: String) -> String:
	if _original_to_dummy_path.has(original_path):
		return _original_to_dummy_path[original_path]

	var md5 = original_path.md5_text()
	var dummy_path = "user://tc_dummy_" + md5 + ".tres"

	_dummy_path_to_original[dummy_path] = original_path
	_original_to_dummy_path[original_path] = dummy_path

	if not FileAccess.file_exists(dummy_path):
		var res = null

		# If type is empty/generic, try to infer it from the extension
		if type == "" or type == "Resource":
			var ext = original_path.get_extension().to_lower()
			if ext in ["png", "jpg", "jpeg", "webp", "svg", "bmp"]: type = "Texture2D"
			elif ext in ["obj", "blend", "gltf", "glb"]: type = "ArrayMesh"
			elif ext in ["material"]: type = "StandardMaterial3D"
			elif ext in ["wav", "mp3", "ogg"]: type = "AudioStreamWAV" # AudioStream

		if ClassDB.can_instantiate(type):
			res = ClassDB.instantiate(type)
		if not res:
			if "Texture" in type:
				res = PlaceholderTexture2D.new()
			elif "Material" in type:
				res = StandardMaterial3D.new()
			elif "Mesh" in type:
				res = ArrayMesh.new()
			elif "Audio" in type:
				res = AudioStreamWAV.new()
			elif "Script" in type:
				res = GDScript.new()
			else:
				res = Resource.new()
		ResourceSaver.save(res, dummy_path)

	return dummy_path

func _restore_dummy_paths_in_file(file_path: String):
	if _dummy_path_to_original.is_empty():
		return

	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file: return
	var text = file.get_as_text()
	file.close()

	var modified = false
	for dummy_path in _dummy_path_to_original:
		if text.find(dummy_path) != -1:
			var orig = _dummy_path_to_original[dummy_path]
			text = text.replace(dummy_path, orig)
			modified = true

	if modified:
		var wfile = FileAccess.open(file_path, FileAccess.WRITE)
		if wfile:
			wfile.store_string(text)
			wfile.close()

func sync_project_settings():
	if file_sync:
		file_sync.sync_project_settings()

func sync_all_files():
	if file_sync:
		file_sync.sync_all_files()

func sync_all_files_to_peer(id: int):
	if file_sync:
		file_sync.sync_all_files_to_peer(id)

# Unique ID management for nodes (Using node paths for consistency across network without modifying .tscn files on every connection)
static func assign_unique_id(node: Node) -> String:
	# Using the absolute path from the scene root is deterministic and avoids .tscn serialization issues
	var tree = node.get_tree()
	if tree and tree.edited_scene_root:
		var root = tree.edited_scene_root
		if node == root:
			return "."
		return root.get_path_to(node)
	return node.get_path()

static func get_node_by_unique_id(root: Node, id: String) -> Node:
	if id == ".":
		return root
	if root.has_node(id):
		return root.get_node(id)
	return null

func _process(_delta: float) -> void:
	if is_webrtc:
		if webrtc_connection:
			webrtc_connection.poll()
		if webrtc_peer:
			webrtc_peer.poll()


func _get_random_color(rng: RandomNumberGenerator) -> Color:
	return Color.from_hsv(rng.randf(), 0.8, 0.9)


func _get_random_name(rng: RandomNumberGenerator) -> String:
	return ADJECTIVES[rng.randi() % ADJECTIVES.size()] + NOUNS[rng.randi() % NOUNS.size()] + str(rng.randi() % 100)


func _generate_peer_info(id: int) -> Dictionary:
	var rng = RandomNumberGenerator.new()
	rng.seed = id

	var color
	if _color_assignment_counter < 4:
		var initial_colors = [Color.BLUE, Color.GREEN, Color.RED, Color.PURPLE]
		var available_colors = []
		for c in initial_colors:
			if not _assigned_colors.has(c):
				available_colors.append(c)
		var rand_index = rng.randi() % available_colors.size()
		color = available_colors[rand_index]
		_assigned_colors.append(color)
		_color_assignment_counter += 1
	else:
		color = _get_random_color(rng)

	var username = _local_username if id == 1 and _local_username != "" else _get_random_name(rng)
	if id == 1 and is_standalone_server:
		username = "Server"
	var info = {"username": username, "color": color}
	if id == 1 and is_standalone_server:
		info["is_standalone"] = true
	return info

func _get_default_peer_info(id: int) -> Dictionary:
	var rng = RandomNumberGenerator.new()
	rng.seed = id
	var color = _get_random_color(rng)
	var username = _local_username if id == multiplayer.get_unique_id() and _local_username != "" else _get_random_name(rng)
	return {"username": username, "color": color}

# User Info management
func get_user_color(id: int) -> Color:
	if peers.has(id):
		return peers[id]["color"]
	return _get_default_peer_info(id)["color"]

func get_username(id: int) -> String:
	if peers.has(id):
		return peers[id]["username"]
	return _get_default_peer_info(id)["username"]


var downloading_webrtc = false

func _download_webrtc():
	if downloading_webrtc: return
	downloading_webrtc = true
	print("Downloading WebRTC extension...")
	if ui:
		ui.webrtc_host_btn.text = "Downloading..."
		ui.webrtc_join_btn.text = "Downloading..."
		ui.webrtc_host_btn.disabled = true
		ui.webrtc_join_btn.disabled = true

	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(self._on_webrtc_download_completed.bind(http_request))
	var error = http_request.request("https://github.com/godotengine/webrtc-native/releases/download/1.1.0-stable/godot-extension-webrtc.zip")
	if error != OK:
		print("Failed to start WebRTC download.")
		downloading_webrtc = false

func _on_webrtc_download_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest):
	if result == HTTPRequest.RESULT_SUCCESS and (response_code == 200 or response_code == 301 or response_code == 302):
		var file = FileAccess.open("user://webrtc_update.zip", FileAccess.WRITE)
		if file:
			file.store_buffer(body)
			file.close()
			_extract_webrtc("user://webrtc_update.zip")
		else:
			print("Failed to save WebRTC zip file.")
			downloading_webrtc = false
	else:
		print("Failed to download WebRTC. Response code: " + str(response_code))
		downloading_webrtc = false
	http_request.queue_free()

# TODO: Add proper error handling/cleanup if ZIP extraction fails mid-way due to lack of disk space
func _extract_webrtc(zip_path: String):
	var zip_reader = ZIPReader.new()
	var err = zip_reader.open(zip_path)
	if err != OK:
		print("Failed to open WebRTC zip.")
		DirAccess.remove_absolute(zip_path)
		downloading_webrtc = false
		return

	var files = zip_reader.get_files()
	for f in files:
		if f.ends_with("/"):
			continue

		if ".." in f:
			continue

		var dest_path = "res://" + f
		var dest_dir = dest_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(dest_dir):
			DirAccess.make_dir_recursive_absolute(dest_dir)

		var content = zip_reader.read_file(f)
		var out_file = FileAccess.open(dest_path, FileAccess.WRITE)
		if out_file:
			out_file.store_buffer(content)
			out_file.close()

	zip_reader.close()
	DirAccess.remove_absolute(zip_path)

	# Prevent WebRTC folder from being built with the game
	var ignore_file = FileAccess.open("res://webrtc/.gdignore", FileAccess.WRITE)
	if ignore_file:
		ignore_file.store_string("")
		ignore_file.close()

	print("WebRTC extension installed! Restarting editor...")
	if ui:
		ui.webrtc_host_btn.text = "Restarting..."
		ui.webrtc_join_btn.text = "Restarting..."

	if plugin:
		var editor_interface = plugin.get_editor_interface()
		editor_interface.restart_editor()

func webrtc_host():
	webrtc_candidates.clear()

	webrtc_connection = WebRTCPeerConnection.new()

	# Check if the native extension is actually loaded. If not, Godot creates the base extension wrapper.
	if webrtc_connection.get_class() == "WebRTCPeerConnectionExtension":
		print("WebRTC plugin missing or not loaded. Starting download...")
		webrtc_connection = null
		disconnect_peer()
		_download_webrtc()
		return

	var err = webrtc_connection.initialize({
		"iceServers": _get_stun_servers()
	})

	if err != OK:
		print("Failed to initialize WebRTC connection.")
		webrtc_connection = null
		disconnect_peer()
		return

	webrtc_peer = WebRTCMultiplayerPeer.new()
	webrtc_peer.create_server()
	multiplayer.multiplayer_peer = webrtc_peer
	is_server = true
	is_webrtc = true
	_add_peer(1)

	webrtc_connection.session_description_created.connect(_webrtc_offer_created)
	webrtc_connection.ice_candidate_created.connect(_webrtc_ice_candidate_created)

	webrtc_peer.add_peer(webrtc_connection, 2) # For manual 1-to-1 signaling

	print("Generating WebRTC offer...")
	webrtc_connection.create_offer()

	if ui:
		ui.update_webrtc_instructions("Generating host offer...")
		ui.update_webrtc_text("")

func webrtc_join():
	webrtc_candidates.clear()

	webrtc_connection = WebRTCPeerConnection.new()

	# Check if the native extension is actually loaded. If not, Godot creates the base extension wrapper.
	if webrtc_connection.get_class() == "WebRTCPeerConnectionExtension":
		print("WebRTC plugin missing or not loaded. Starting download...")
		webrtc_connection = null
		disconnect_peer()
		_download_webrtc()
		return

	var err = webrtc_connection.initialize({
		"iceServers": _get_stun_servers()
	})

	if err != OK:
		print("Failed to initialize WebRTC connection.")
		webrtc_connection = null
		disconnect_peer()
		return

	webrtc_peer = WebRTCMultiplayerPeer.new()
	webrtc_peer.create_client(2)
	multiplayer.multiplayer_peer = webrtc_peer
	is_server = false
	is_webrtc = true
	_add_peer(multiplayer.get_unique_id())

	webrtc_connection.session_description_created.connect(_webrtc_offer_created)
	webrtc_connection.ice_candidate_created.connect(_webrtc_ice_candidate_created)

	print("Initializing WebRTC join...")
	webrtc_peer.add_peer(webrtc_connection, 1)

	if ui:
		ui.update_webrtc_instructions("Step 1: Paste Host Offer connection string below, then click Confirm.")
		ui.update_webrtc_text("")

func _webrtc_offer_created(type: String, sdp: String):
	local_sdp_type = type
	local_sdp = sdp
	print("WebRTC session description created: ", type)
	print("Waiting for ICE candidates...")
	webrtc_connection.set_local_description(type, sdp)
	call_deferred("_update_webrtc_output")

func _webrtc_ice_candidate_created(media: String, index: int, name: String):
	webrtc_candidates.append({"media": media, "index": index, "name": name})
	call_deferred("_update_webrtc_output")

func _update_webrtc_output():
	if not webrtc_connection:
		return
	if local_sdp_type == "":
		return

	print("Waiting 3 seconds for ICE candidates to gather...")
	var timer = get_tree().create_timer(3.0)
	await timer.timeout

	if not webrtc_connection:
		return

	var dict = {
		"type": local_sdp_type,
		"sdp": local_sdp,
		"candidates": webrtc_candidates
	}
	var json = JSON.stringify(dict)
	var encoded_str = Marshalls.utf8_to_base64(json)
	if ui:
		if is_server:
			ui.update_webrtc_instructions("Step 1: Copy this string and send it to your friend.\nStep 2: Wait for them to send their answer back.\nStep 3: Paste their answer below and click Confirm.")
			ui.update_webrtc_text(encoded_str)
		else:
			ui.update_webrtc_instructions("Step 2: Copy this string and send it back to the host.")
			ui.update_webrtc_text(encoded_str)

func webrtc_confirm(encoded_str: String):
	print("Parsing WebRTC connection string...")
	if not is_webrtc or not webrtc_connection:
		print("WebRTC not initialized")
		return

	if ui:
		ui.disable_webrtc_confirm()

	var decoded_json_str = Marshalls.base64_to_utf8(encoded_str.strip_edges())

	var json = JSON.new()
	if json.parse(decoded_json_str) != OK:
		print("Failed to parse JSON")
		if ui:
			ui.update_webrtc_instructions("Error: Failed to parse connection data. Please make sure you copied the entire string correctly.")
			ui.enable_webrtc_confirm()
		return

	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		print("Invalid JSON data")
		if ui:
			ui.update_webrtc_instructions("Error: Invalid connection data format.")
			ui.enable_webrtc_confirm()
		return

	if data.has("type") and data.has("sdp"):
		print("Applying remote WebRTC description (", data["type"], ")...")
		webrtc_connection.set_remote_description(data["type"], data["sdp"])

		# If we are client joining, and we just got the offer, it automatically creates an answer
		if not is_server and data["type"] == "offer":
			webrtc_candidates.clear() # Clear any old ones



	if data.has("candidates"):
		print("Adding ICE candidates to remote connection...")
		print("Adding ", data["candidates"].size(), " ICE candidates...")
		for cand in data["candidates"]:
			if typeof(cand) == TYPE_DICTIONARY and cand.has("media") and cand.has("index") and cand.has("name"):
				webrtc_connection.add_ice_candidate(cand["media"], cand["index"], cand["name"])
			else:
				print("Invalid ICE candidate format.")

func _init_editor_settings():
	if Engine.is_editor_hint() and plugin and plugin.has_method("get_editor_interface"):
		var editor_interface = plugin.get_editor_interface()
		if editor_interface and editor_interface.has_method("get_editor_settings"):
			var settings = editor_interface.get_editor_settings()
			if settings:
				var setting_name = "network/team_create/stun_server"
				var default_val = "stun:stun.l.google.com:19302"
				if not settings.has_setting(setting_name):
					settings.set_setting(setting_name, default_val)
				settings.set_initial_value(setting_name, default_val, false)
				var property_info = {
					"name": setting_name,
					"type": TYPE_STRING,
					"hint": PROPERTY_HINT_NONE,
					"hint_string": "Comma separated list of STUN/TURN servers"
				}
				settings.add_property_info(property_info)

func _get_stun_servers() -> Array:
	var default_servers = [{"urls": ["stun:stun.l.google.com:19302"]}]

	if Engine.is_editor_hint() and plugin and plugin.has_method("get_editor_interface"):
		var editor_interface = plugin.get_editor_interface()
		if editor_interface and editor_interface.has_method("get_editor_settings"):
			var settings = editor_interface.get_editor_settings()
			if settings and settings.has_setting("network/team_create/stun_server"):
				var setting_val = settings.get_setting("network/team_create/stun_server")
				if typeof(setting_val) == TYPE_STRING and setting_val.strip_edges() != "":
					var server_list = []
					var parts = setting_val.split(",")
					for part in parts:
						var url = part.strip_edges()
						if url != "":
							server_list.append(url)
					if server_list.size() > 0:
						return [{"urls": server_list}]

	return default_servers
