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
var server_ip: String = ""
var peers = {} # Dictionary mapping peer_id to user info (username, color)
var _color_assignment_counter = 0
var _assigned_colors = []
var file_sync
var scene_sync

var _local_username = ""
# Console thread
var chat_window: Control
var _console_thread: Thread
var _console_should_exit: bool = false

# Server commands config
var auto_save_prints_enabled: bool = false
var timeprint_enabled: bool = true
var joins_enabled: bool = true
var chat_locked: bool = false
var chat_images_enabled: bool = true
var muted_users = []
var admins = []

var max_file_size: int = 0

var chat_history = []
var chat_id_counter = 0
const CHAT_HISTORY_FILE = "res://addons/team_create/team_chat_history.json"


func tc_print(msg: String, arg1="", arg2="", arg3=""):
	var full_msg = msg + str(arg1) + str(arg2) + str(arg3)
	if timeprint_enabled:
		var time = Time.get_time_string_from_system()
		print("<" + time + "> " + full_msg)
	else:
		print(full_msg)

func tc_print_rich(msg: String, arg1="", arg2="", arg3=""):
	var full_msg = msg + str(arg1) + str(arg2) + str(arg3)
	if timeprint_enabled:
		var time = Time.get_time_string_from_system()
		print_rich("[color=gray]<" + time + ">[/color] " + full_msg)
	else:
		print_rich(full_msg)

func _ready():
	if is_standalone_server:
		_console_thread = Thread.new()
		_console_thread.start(Callable(self, "_server_console_thread_func"))

	_load_chat_history()

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
	tc_print_rich("[color=green]Server console ready. Type /help for a list of commands.[/color]")
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
		if args.size() > 1 and args[1] == "2":
			tc_print_rich("[color=cyan]--- Available Commands (Page 2) ---[/color]")
			tc_print_rich("[color=white]/lockchat <true/false>[/color] - Prevents users from chatting")
			tc_print_rich("[color=white]/chatmsg <message>[/color]    - Creates chat message from a server")
			tc_print_rich("[color=white]/mute <user or id>[/color]      - Mutes user from chatting")
			tc_print_rich("[color=white]/unmute <user or id>[/color]    - Unmutes user from chatting")
			tc_print_rich("[color=white]/admin <user or id>[/color]     - Gives admin privileges to a user")
			tc_print_rich("[color=white]/unadmin <user or id>[/color]   - Removes admin privileges from a user")
			tc_print_rich("[color=white]/chatimgs <true/false>[/color] - Lets users send images in the chat")
			tc_print_rich("[color=white]/filesize <num or none>[/color] - Sets maximum file size limit")
			tc_print_rich("[color=cyan]--------------------------[/color]")
		else:
			tc_print_rich("[color=cyan]--- Available Commands (Page 1) ---[/color]")
			tc_print_rich("[color=white]/kick <user>[/color]   - Kicks a user from the server")
			tc_print_rich("[color=white]/list[/color]          - Lists all connected users")
			tc_print_rich("[color=white]/info[/color]          - Shows server statistics (memory, CPU, players, etc.)")
			tc_print_rich("[color=white]/update[/color]        - Downloads latest update and restarts the server")
			tc_print_rich("[color=white]/restart[/color]       - Restarts the server")
			tc_print_rich("[color=white]/stop[/color]          - Stops and exits the server")
			tc_print_rich("[color=white]/saveprints <true/false>[/color] - Toggles auto-save prints")
			tc_print_rich("[color=white]/timeprint <true/false>[/color] - Toggles time prefix in prints")
			tc_print_rich("[color=white]/togglejoins <true/false>[/color] - Toggles people joining the server")
			tc_print_rich("[color=white]/msg <message>[/color]    - Shows a message to everyone")
			tc_print_rich("[color=white]/popup <message>[/color]  - Creates a pop up for everyone")
			tc_print_rich("[color=white]/clearchat[/color]       - Clears all chat messages")
			tc_print_rich("[color=cyan]Type /help 2 for more commands[/color]")
			tc_print_rich("[color=cyan]--------------------------[/color]")

	elif cmd == "/clearchat":
		clear_chat()

	elif cmd == "/lockchat":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: /lockchat <true/false>[/color]")
		else:
			var val = args[1].to_lower()
			if val == "true":
				chat_locked = true
				tc_print_rich("[color=green]Chat is now locked.[/color]")
			elif val == "false":
				chat_locked = false
				tc_print_rich("[color=green]Chat is now unlocked.[/color]")
			else:
				tc_print_rich("[color=red]Invalid argument. Use true or false.[/color]")

	elif cmd == "/chatmsg":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: /chatmsg <message>[/color]")
		else:
			var msg_text = input.substr(args[0].length()).strip_edges()
			var msg = {
				"id": chat_id_counter,
				"type": "text",
				"sender_id": 1,
				"sender_name": "Server",
				"sender_color": "FFA500",
				"pinned": false,
				"text": "[color=#FFA500]" + msg_text + "[/color]"
			}
			chat_id_counter += 1
			chat_history.append(msg)
			_save_chat_history()
			rpc("receive_chat_message", msg)
			_add_message_to_local_ui(msg)
			tc_print("[Chat] Server: " + msg_text)

	elif cmd == "/mute" or cmd == "/unmute":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: " + cmd + " <user or peer id>[/color]")
		else:
			var target_str = args[1]
			var target_id = -1
			if target_str.is_valid_int():
				target_id = target_str.to_int()
				if not peers.has(target_id):
					target_id = -1
			if target_id == -1:
				for id in peers.keys():
					if peers[id]["username"] == target_str:
						target_id = id
						break

			if target_id != -1:
				if cmd == "/mute":
					if not muted_users.has(target_id):
						muted_users.append(target_id)
						tc_print_rich("[color=yellow]User muted: " + peers[target_id]["username"] + "[/color]")
					else:
						tc_print_rich("[color=yellow]User is already muted.[/color]")
				else:
					if muted_users.has(target_id):
						muted_users.erase(target_id)
						tc_print_rich("[color=green]User unmuted: " + peers[target_id]["username"] + "[/color]")
					else:
						tc_print_rich("[color=yellow]User is not muted.[/color]")
			else:
				tc_print_rich("[color=red]User not found: " + target_str + "[/color]")

	elif cmd == "/admin" or cmd == "/unadmin":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: " + cmd + " <user or peer id>[/color]")
		else:
			var target_str = args[1]
			var target_id = -1
			if target_str.is_valid_int():
				target_id = target_str.to_int()
				if not peers.has(target_id):
					target_id = -1
			if target_id == -1:
				for id in peers.keys():
					if peers[id]["username"] == target_str:
						target_id = id
						break

			if target_id != -1:
				if cmd == "/admin":
					if not admins.has(target_id):
						admins.append(target_id)
						tc_print_rich("[color=green]User granted admin: " + peers[target_id]["username"] + "[/color]")
					else:
						tc_print_rich("[color=yellow]User is already an admin.[/color]")
				else:
					if admins.has(target_id):
						admins.erase(target_id)
						tc_print_rich("[color=green]User removed from admin: " + peers[target_id]["username"] + "[/color]")
					else:
						tc_print_rich("[color=yellow]User is not an admin.[/color]")
			else:
				tc_print_rich("[color=red]User not found: " + target_str + "[/color]")

	elif cmd == "/filesize":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: /filesize <number (in Mb) or none>[/color]")
		else:
			var val = args[1].to_lower()
			if val == "none":
				max_file_size = 0
				rpc("update_max_file_size", max_file_size)
				tc_print_rich("[color=green]Max file size limit disabled (unlimited).[/color]")
			elif val.is_valid_int() or val.is_valid_float():
				var mb = val.to_float()
				if mb <= 0:
					tc_print_rich("[color=red]Invalid file size. Must be greater than 0 or none.[/color]")
				else:
					# Convert Mb to bytes
					max_file_size = int(mb * 1024 * 1024)
					rpc("update_max_file_size", max_file_size)
					tc_print_rich("[color=green]Max file size set to " + val + " MB.[/color]")
			else:
				tc_print_rich("[color=red]Invalid argument. Use a number or none.[/color]")

	elif cmd == "/chatimgs":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: /chatimgs <true/false>[/color]")
		else:
			var val = args[1].to_lower()
			if val == "true":
				chat_images_enabled = true
				tc_print_rich("[color=green]Chat images enabled.[/color]")
			elif val == "false":
				chat_images_enabled = false
				tc_print_rich("[color=green]Chat images disabled.[/color]")
			else:
				tc_print_rich("[color=red]Invalid argument. Use true or false.[/color]")

	elif cmd == "/saveprints":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: /saveprints <true/false>[/color]")
		else:
			var val = args[1].to_lower()
			if val == "true":
				auto_save_prints_enabled = true
				tc_print_rich("[color=green]Auto-save prints enabled.[/color]")
			elif val == "false":
				auto_save_prints_enabled = false
				tc_print_rich("[color=green]Auto-save prints disabled.[/color]")
			else:
				tc_print_rich("[color=red]Invalid argument. Use true or false.[/color]")

	elif cmd == "/timeprint":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: /timeprint <true/false>[/color]")
		else:
			var val = args[1].to_lower()
			if val == "true":
				timeprint_enabled = true
				tc_print_rich("[color=green]Time prints enabled.[/color]")
			elif val == "false":
				timeprint_enabled = false
				tc_print_rich("[color=green]Time prints disabled.[/color]")
			else:
				tc_print_rich("[color=red]Invalid argument. Use true or false.[/color]")

	elif cmd == "/togglejoins":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: /togglejoins <true/false>[/color]")
		else:
			var val = args[1].to_lower()
			if val == "true":
				joins_enabled = true
				if multiplayer.multiplayer_peer and multiplayer.multiplayer_peer is ENetMultiplayerPeer:
					multiplayer.multiplayer_peer.refuse_new_connections = false
				tc_print_rich("[color=green]Joining is now enabled.[/color]")
			elif val == "false":
				joins_enabled = false
				if multiplayer.multiplayer_peer and multiplayer.multiplayer_peer is ENetMultiplayerPeer:
					multiplayer.multiplayer_peer.refuse_new_connections = true
				tc_print_rich("[color=green]Joining is now disabled.[/color]")
			else:
				tc_print_rich("[color=red]Invalid argument. Use true or false.[/color]")

	elif cmd == "/msg":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: /msg <message>[/color]")
		else:
			var msg = input.substr(args[0].length()).strip_edges()
			rpc("show_message", msg)
			show_message(msg)
			tc_print_rich("[color=green]Message sent: " + msg + "[/color]")

	elif cmd == "/popup":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: /popup <message>[/color]")
		else:
			var msg = input.substr(args[0].length()).strip_edges()
			rpc("show_popup", msg)
			show_popup(msg)
			tc_print_rich("[color=green]Popup sent: " + msg + "[/color]")

	elif cmd == "/kick":
		if args.size() < 2:
			tc_print_rich("[color=orange]Usage: /kick <username>[/color]")
		else:
			var target_username = args[1]
			var target_id = -1
			for id in peers.keys():
				if peers[id]["username"] == target_username:
					target_id = id
					break
			if target_id != -1:
				if target_id == 1:
					tc_print_rich("[color=red]Cannot kick the server.[/color]")
				else:
					tc_print_rich("[color=yellow]Kicking user: " + target_username + "[/color]")
					call_deferred("kick_peer", target_id)
			else:
				tc_print_rich("[color=red]User not found: " + target_username + "[/color]")

	elif cmd == "/update":
		tc_print_rich("[color=cyan]Updating plugin and restarting server...[/color]")
		if plugin and plugin.has_method("download_update"):
			call_deferred("_deferred_update_and_restart")
		else:
			tc_print_rich("[color=red]Update mechanism not available.[/color]")

	elif cmd == "/list":
		tc_print_rich("[color=cyan]Connected users:[/color]")
		var count = 0
		for id in peers.keys():
			if id == 1:
				continue # Skip the server
			var info = peers[id]
			var ip_str = "N/A"
			if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
				ip_str = multiplayer.multiplayer_peer.get_peer(id).get_remote_address()
			tc_print_rich("[color=white]- " + info["username"] + " (ID: " + str(id) + ", IP: " + ip_str + ")[/color]")
			count += 1
		tc_print_rich("[color=green]Total users: " + str(count) + "[/color]")

	elif cmd == "/restart":
		tc_print_rich("[color=orange]Restarting server...[/color]")
		call_deferred("_deferred_restart")

	elif cmd == "/stop":
		tc_print_rich("[color=red]Stopping server...[/color]")
		call_deferred("_deferred_stop")

	elif cmd == "/info":
		tc_print_rich("[color=cyan]--- Server Info ---[/color]")
		tc_print_rich("[color=white]Memory Usage:[/color] " + String.humanize_size(OS.get_static_memory_usage()))
		tc_print_rich("[color=white]Peak Memory Usage:[/color] " + String.humanize_size(OS.get_static_memory_peak_usage()))
		var cpu_usage = Performance.get_monitor(Performance.TIME_PROCESS) * Engine.get_frames_per_second() * 100.0
		tc_print_rich("[color=white]CPU Usage:[/color] " + ("%.2f" % cpu_usage) + "%")
		var port = str(PORT)
		var local_ip = "127.0.0.1"
		for address in IP.get_local_addresses():
			if address.split(".").size() == 4 and not address.begins_with("127.") and not address.begins_with("169.254."):
				local_ip = address
				break
		tc_print_rich("[color=white]Network:[/color] " + local_ip + ":" + str(port))
		var user_count = peers.size() - 1 if peers.has(1) else peers.size()
		tc_print_rich("[color=white]Total users connected:[/color] " + str(user_count))
		tc_print_rich("[color=cyan]-------------------[/color]")
	else:
		tc_print_rich("[color=red]Unknown command: " + cmd + "[/color]")

func _deferred_update_and_restart():
	if plugin and plugin.has_method("download_update"):
		plugin.download_update()
		# Actual restart is handled when extraction completes

func _deferred_restart():
	# Clean up network connections before restarting
	disconnect_peer()
	_save_chat_history()

	var exec_path = OS.get_executable_path()
	var args = []
	if DisplayServer.get_name() == "headless":
		args.append("--headless")

	for arg in OS.get_cmdline_args():
		args.append(arg)

	if OS.has_method("set_restart_on_exit"):
		OS.set_restart_on_exit(true, args)
	elif OS.has_method("create_instance"):
		OS.create_instance(args)
	elif OS.has_method("create_process"):
		OS.create_process(exec_path, args)
	else:
		tc_print("Restart not supported on this platform/version. Stopping instead.")

	_deferred_stop()

func _deferred_stop():
	disconnect_peer()
	_save_chat_history()

	if _console_thread and _console_thread.is_started():
		_console_should_exit = true

	get_tree().quit(0)

func kick_peer(id: int):
	if is_server and id != 1:
		if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
			multiplayer.multiplayer_peer.disconnect_peer(id)
		tc_print("Kicked peer ", id)

func update_local_username(new_name: String):
	_local_username = new_name
	var my_id = multiplayer.get_unique_id()
	if multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		if is_server:
			request_username_change(my_id, _local_username)
		elif my_id != 1:
			rpc_id(1, "request_username_change", my_id, _local_username)

func host_server():
	disconnect_peer()
	var err = peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		tc_print("Failed to host server: Error code ", err)
		disconnect_peer()
		return

	multiplayer.multiplayer_peer = peer
	is_server = true
	if is_standalone_server and file_sync:
		file_sync._setup_http_server()

	_add_peer(1)
	call_deferred("_update_local_chat_ui")
	_update_ui_state()

func join_server(ip: String):
	server_ip = ip
	disconnect_peer()
	var err = peer.create_client(ip, PORT)
	if err != OK:
		tc_print("Failed to join server: Error code ", err)
		disconnect_peer()
		return
	multiplayer.multiplayer_peer = peer
	is_server = false
	_add_peer(multiplayer.get_unique_id())

func disconnect_peer():
	var was_connected = multiplayer.multiplayer_peer != null
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
	if was_connected:
		tc_print("Disconnected")

func _add_peer(id: int):
	if not peers.has(id):
		if is_server:
			peers[id] = _generate_peer_info(id)
			if id != 1:
				rpc("sync_peer_info", id, peers[id])
		else:
			peers[id] = _get_default_peer_info(id) # temporary fallback until server syncs

func _on_peer_connected(id: int):
	if is_server and not joins_enabled:
		tc_print("Rejected peer connection because joins are disabled: ", id)
		call_deferred("kick_peer", id)
		return

	tc_print("Peer connected: ", id)
	_add_peer(id)
	if ui:
		ui.update_users_count(peers.size())

	_update_ui_state()

	if is_server:
		# Auto sync all files when a peer joins
		call_deferred("sync_all_files_to_peer", id)
		# NOTE: We DO NOT push the scene here anymore! The client will request it when file sync finishes.
		# Sync max file size to the new peer
		rpc_id(id, "update_max_file_size", max_file_size)

		# Send current peer list to the new peer
		for existing_id in peers.keys():
			rpc_id(id, "sync_peer_info", existing_id, peers[existing_id])

		# Inform all other peers about the new peer with its server-assigned info
		for peer_id in peers.keys():
			if peer_id != 1 and peer_id != id:
				rpc_id(peer_id, "sync_peer_info", id, peers[id])

		# Send chat history to the new user
		rpc_id(id, "sync_chat_history", chat_history)



func _on_peer_disconnected(id: int):
	tc_print("Peer disconnected: ", id)
	if peers.has(id):
		peers.erase(id)
	if ui:
		ui.update_users_count(peers.size())

	# Clear selection outlines for disconnected peer
	if scene_sync:
		scene_sync.clear_peer_selections(id)
		scene_sync._clear_peer_cursor(id)

func _on_connected_to_server():
	tc_print("Connected to server successfully!")
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
	else:
		if not is_server and multiplayer.get_unique_id() != 1:
			rpc_id(1, "request_username_change", multiplayer.get_unique_id(), "")

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
func update_max_file_size(size: int):
	if multiplayer.get_remote_sender_id() != 1:
		return
	max_file_size = size

@rpc("any_peer", "reliable")
func show_message(msg: String):
	if multiplayer.get_remote_sender_id() != 1 and multiplayer.get_remote_sender_id() != 0:
		return
	if ui and ui.has_method("show_server_message"):
		ui.show_server_message(msg)

@rpc("authority", "call_remote", "reliable")
func show_popup(msg: String):
	if multiplayer.get_remote_sender_id() != 1 and multiplayer.get_remote_sender_id() != 0:
		return

	var dialog = AcceptDialog.new()
	dialog.title = "Server Message"
	dialog.dialog_text = msg
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)

	if plugin:
		plugin.get_editor_interface().get_base_control().add_child(dialog)
		dialog.call_deferred("popup_centered")
	else:
		# Fallback if plugin reference is not available (e.g. headless)
		get_tree().root.add_child(dialog)
		dialog.call_deferred("popup_centered")

@rpc("any_peer", "reliable")
func request_username_change(id: int, new_username: String):
	if is_server:
		if peers.has(id) and (multiplayer.get_remote_sender_id() == id or multiplayer.get_remote_sender_id() == 0):
			if new_username != "":
				peers[id]["username"] = new_username
			rpc("sync_peer_info", id, peers[id])
			# Server updates its own
			sync_peer_info(id, peers[id])
			if not peers[id].get("has_broadcast_join", false):
				peers[id]["has_broadcast_join"] = true
				broadcast_join_message(id)

func _on_connection_failed():
	tc_print("Connection to server failed.")
	disconnect_peer()

func _on_server_disconnected():
	tc_print("Server disconnected.")
	disconnect_peer()

func _update_ui_state():
	if ui:
		var connected_to_standalone = false
		if peers.has(1) and peers[1].has("is_standalone") and peers[1]["is_standalone"]:
			connected_to_standalone = true
		ui.set_connected(is_server, connected_to_standalone)
		var username = get_username(multiplayer.get_unique_id())
		var protocol = "Server" if connected_to_standalone else "LAN"
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

		if "Texture" in type:
			res = GradientTexture2D.new()
		elif "Material" in type:
			res = StandardMaterial3D.new()
		elif "Mesh" in type:
			res = ArrayMesh.new()
		elif "Audio" in type:
			res = AudioStreamWAV.new()
		elif "Script" in type:
			res = GDScript.new()
		elif ClassDB.can_instantiate(type):
			res = ClassDB.instantiate(type)

		if not res:
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
	var info = {"username": username, "color": color}
	if id == 1 and is_standalone_server:
		info["is_standalone"] = true
	return info

# User Info management
func get_user_color(id: int) -> Color:
	if peers.has(id):
		return peers[id]["color"]
	return _get_default_peer_info(id)["color"]

func get_username(id: int) -> String:
	if peers.has(id):
		return peers[id]["username"]
	return _get_default_peer_info(id)["username"]




# Chat System
func _load_chat_history():
	if FileAccess.file_exists(CHAT_HISTORY_FILE):
		var file = FileAccess.open(CHAT_HISTORY_FILE, FileAccess.READ)
		if file:
			var text_content = file.get_as_text()
			file.close()
			var json = JSON.new()
			if json.parse(text_content) == OK:
				if typeof(json.data) == TYPE_ARRAY:
					chat_history = json.data
					# find highest id
					for m in chat_history:
						if m.has("id") and m["id"] >= chat_id_counter:
							chat_id_counter = int(m["id"]) + 1

func _save_chat_history():
	var file = FileAccess.open(CHAT_HISTORY_FILE, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(chat_history))
		file.close()

func _update_local_chat_ui():
	if chat_window:
		chat_window.set_messages(chat_history)

func _add_message_to_local_ui(msg: Dictionary):
	if chat_window:
		chat_window.add_message(msg)

@rpc("any_peer", "reliable")
func sync_chat_history(history: Array):
	if multiplayer.get_remote_sender_id() != 1: return
	chat_history = history
	_update_local_chat_ui()

func send_chat_message(text: String, image_path: String = ""):
	if multiplayer.multiplayer_peer == null:
		tc_print("Cannot send message. Not connected to a server.")
		return
	var peer_status = multiplayer.multiplayer_peer.get_connection_status()
	if peer_status == MultiplayerPeer.CONNECTION_DISCONNECTED:
		tc_print("Cannot send message. Not connected to a server.")
		return

	var my_id = multiplayer.get_unique_id()
	if is_server:
		if text.begins_with("/"):
			_process_console_command(text)
			return
		if not chat_locked:
			if not chat_images_enabled and image_path != "": return
			_process_new_chat_message(my_id, text, image_path)
	else:
		if my_id == 1 or my_id == 0:
			tc_print("Cannot send message. Not connected to a server.")
			return
		rpc_id(1, "request_chat_message", text, image_path)

@rpc("any_peer", "reliable")
func request_chat_message(text: String, image_path: String):
	if not is_server: return
	var sender_id = multiplayer.get_remote_sender_id()

	if text.begins_with("/") and admins.has(sender_id):
		_process_console_command(text)
		return

	if chat_locked: return
	if muted_users.has(sender_id): return
	if not chat_images_enabled and image_path != "": return
	_process_new_chat_message(sender_id, text, image_path)

func _process_new_chat_message(sender_id: int, text: String, image_path: String):
	var username = get_username(sender_id)
	var color = get_user_color(sender_id)

	var msg = {
		"id": chat_id_counter,
		"type": "text",
		"sender_id": sender_id,
		"sender_name": username,
		"sender_color": color.to_html(false),
		"pinned": false
	}
	chat_id_counter += 1

	if image_path != "":
		msg["type"] = "image"
		# If they drag from local filesystem and its outside res://, we would need to transfer it
		# For now we assume they drag from inside the project, or we just take the path.
		msg["path"] = image_path
		tc_print("[Chat] " + username + " sent an image: " + image_path)
	else:
		msg["text"] = text
		tc_print("[Chat] " + username + ": " + text)

	chat_history.append(msg)
	_save_chat_history()

	# Send to all peers
	rpc("receive_chat_message", msg)
	# Local server gets it too
	_add_message_to_local_ui(msg)

@rpc("any_peer", "reliable")
func receive_chat_message(msg: Dictionary):
	var sender_id = multiplayer.get_remote_sender_id()
	# If we're not the server, only accept from server. (0 means local call)
	if not is_server and sender_id != 1 and sender_id != 0: return

	# Client-side: if we didn't add it ourselves (we aren't server), append it
	if not is_server:
		chat_history.append(msg)

	_add_message_to_local_ui(msg)

func clear_chat():
	if is_server:
		chat_history.clear()
		_save_chat_history()
		rpc("sync_chat_history", [])
		_update_local_chat_ui()
		tc_print("Chat history cleared.")
	else:
		rpc_id(1, "request_clear_chat")

@rpc("any_peer", "reliable")
func request_clear_chat():
	if is_server:
		var sender_id = multiplayer.get_remote_sender_id()
		if admins.has(sender_id):
			clear_chat()

func toggle_pin_message(msg_id: int):
	if is_server:
		_process_toggle_pin(msg_id)
	else:
		rpc_id(1, "request_toggle_pin", msg_id)

@rpc("any_peer", "reliable")
func request_toggle_pin(msg_id: int):
	if is_server:
		_process_toggle_pin(msg_id)

func _process_toggle_pin(msg_id: int):
	for m in chat_history:
		if m.has("id") and m["id"] == msg_id:
			m["pinned"] = not m.get("pinned", false)
			_save_chat_history()
			rpc("sync_chat_history", chat_history)
			_update_local_chat_ui()
			break

func broadcast_join_message(id: int):
	if not joins_enabled: return
	var username = get_username(id)
	var msg = {
		"id": chat_id_counter,
		"type": "join",
		"text": username + " joined the session",
		"pinned": false
	}
	chat_id_counter += 1
	chat_history.append(msg)
	_save_chat_history()
	rpc("receive_chat_message", msg)
	receive_chat_message(msg)
