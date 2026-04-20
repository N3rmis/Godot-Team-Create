@tool
extends EditorPlugin

var dock: Control
var network: Node

func _enter_tree() -> void:
	network.tc_print("Team Create initialized.")

	# Load UI script and instantiate it.
	# We're building the UI dynamically to ensure stability and match the screenshot.
	var ui_script = load("res://addons/team_create/ui.gd")
	var network_script = load("res://addons/team_create/network.gd")

	if ui_script == null or network_script == null:
		printerr("Team Create failed to load core scripts! Attempting fallback update...")
		download_update()
		return

	dock = ui_script.new()
	add_control_to_dock(DOCK_SLOT_LEFT_UR, dock)

	# Load network manager script and instantiate it as a child.
	network = network_script.new()
	network.name = "TeamCreateNetwork"
	get_tree().root.add_child(network)

	# Link UI and network
	dock.network = network
	network.ui = dock

	network.plugin = self

	# Check for updates on load
	check_for_updates()

func _exit_tree() -> void:
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()
	if network:
		get_tree().root.remove_child(network)
		network.queue_free()

func get_current_version() -> String:
	var cfg = ConfigFile.new()
	var err = cfg.load("res://addons/team_create/plugin.cfg")
	if err == OK:
		return cfg.get_value("plugin", "version", "1.0")
	return "1.0"

func check_for_updates() -> void:
	var http_request = HTTPRequest.new()
	add_child(http_request)

	# Setting TLS/SSL parameters may be needed depending on the Godot version
	# But generally githubusercontent works with default.
	# We also need to delay the request slightly if the plugin just loaded.

	http_request.request_completed.connect(self._http_request_completed.bind(http_request))
	var headers = ["User-Agent: Godot-Team-Create-Plugin", "Cache-Control: no-cache"]
	var timestamp = str(Time.get_unix_time_from_system())
	var error = http_request.request("https://raw.githubusercontent.com/N3rmis/Godot-Team-Create/main/addons/team_create/plugin.cfg", headers)
	if error != OK:
		network.tc_print("An error occurred in the HTTP request.")

func _http_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
		var content = body.get_string_from_utf8()
		var lines = content.split("\n")
		var latest_version = ""
		for line in lines:
			if line.begins_with("version="):
				latest_version = line.split("=")[1].replace("\"", "").strip_edges()
				break

		var current_version = get_current_version()
		if latest_version != "" and latest_version != current_version:
			network.tc_print("Team Create update available: " + latest_version + " (Current: " + current_version + ")")
			_prompt_update(latest_version)
		else:
			network.tc_print("Team Create is up to date.")
			if dock and dock.update_btn:
				dock.update_btn.text = "Up to date!"
				dock.update_btn.disabled = false
	else:
		network.tc_print("Failed to check for updates. Result: " + str(result) + ", Code: " + str(response_code))
		if dock and dock.update_btn:
			dock.update_btn.text = "Check Failed"
			dock.update_btn.disabled = false

	http_request.queue_free()
var downloading = false

func _prompt_update(latest_version: String = "") -> void:
	if downloading:
		return
	if dock and dock.update_btn:
		dock.update_btn.text = "Update Available!"
		dock.update_btn.disabled = false
		dock.update_btn.add_theme_color_override("font_color", Color.GREEN)

	var dialog = AcceptDialog.new()
	dialog.title = "Team Create Update Available"
	if latest_version != "":
		dialog.dialog_text = "A new version of Godot Team Create (" + latest_version + ") is available.\nClick the update button in the dock to install it."
	else:
		dialog.dialog_text = "A new version of Godot Team Create is available.\nClick the update button in the dock to install it."

	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	get_editor_interface().get_base_control().add_child(dialog)
	dialog.popup_centered()

func _reset_update_button() -> void:
	downloading = false
	if dock and dock.update_btn:
		dock.update_btn.text = "Update Failed. Retry?"
		dock.update_btn.add_theme_color_override("font_color", Color.RED)

func download_update() -> void:
	if downloading:
		return
	downloading = true
	if dock and dock.update_btn:
		dock.update_btn.text = "Downloading..."

	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(self._download_request_completed.bind(http_request))
	http_request.download_file = "user://team_create_update.zip"
	# Using raw GitHub repo download link
	var headers = ["User-Agent: Godot-Team-Create-Plugin"]
	var error = http_request.request("https://github.com/N3rmis/Godot-Team-Create/archive/refs/heads/main.zip", headers)
	if error != OK:
		network.tc_print("An error occurred in the HTTP download request.")
		_reset_update_button()

func _download_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and (response_code == 200 or response_code == 301 or response_code == 302):
		_extract_and_apply_update("user://team_create_update.zip")
	else:
		network.tc_print("Failed to download update. Response code: " + str(response_code))
		_reset_update_button()

	http_request.queue_free()

func _extract_and_apply_update(zip_path: String) -> void:
	# Use Godot's ZIPReader
	var zip_reader = ZIPReader.new()
	var err = zip_reader.open(zip_path)
	if err != OK:
		network.tc_print("Failed to open update zip.")
		DirAccess.remove_absolute(zip_path)
		_reset_update_button()
		return

	var files = zip_reader.get_files()
	for f in files:
		if f.ends_with("/"):
			continue # Directory

		# Normalize path separators
		var f_norm = f.replace("\\", "/")

		# Ensure it's inside the addons/team_create folder
		# GitHub zips put everything inside a root folder, e.g., "Godot-Team-Create-main/addons/team_create/..."
		var parts = f_norm.split("/")
		if parts.size() > 2 and parts[1] == "addons" and parts[2] == "team_create":
			var dest_path = ("res://" + "/".join(parts.slice(1, parts.size()))).simplify_path()

			# Validate path to prevent ZipSlip traversal and absolute path escapes
			if not dest_path.begins_with("res://addons/team_create/"):
				printerr("Security Warning: Traversal attempt detected in update zip: ", f)
				continue

			# Ensure directory exists
			var dest_dir = dest_path.get_base_dir()
			if not DirAccess.dir_exists_absolute(dest_dir):
				DirAccess.make_dir_recursive_absolute(dest_dir)

			var content = zip_reader.read_file(f)
			var out_file = FileAccess.open(dest_path, FileAccess.WRITE)
			if out_file:
				out_file.store_buffer(content)
				out_file.close()
			else:
				network.tc_print("Failed to write updated file: " + dest_path)

	zip_reader.close()
	DirAccess.remove_absolute(zip_path)
	network.tc_print("Update applied successfully! Restarting editor...")

	if dock and dock.update_btn:
		dock.update_btn.text = "Restarting..."

	# Restart editor
	var editor_interface = get_editor_interface()
	editor_interface.restart_editor()
