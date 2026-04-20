@tool
extends Control

var network: Node

# UI Elements
var status_panel: PanelContainer
var status_label: Label
var users_label: RichTextLabel
var server_msg_label: Label
var ip_edit: LineEdit
var username_edit: LineEdit
var host_btn: Button
var join_btn: Button
var disconnect_btn: Button

# WebRTC UI
var webrtc_host_btn: Button
var webrtc_join_btn: Button
var webrtc_instructions: Label
var webrtc_text: TextEdit
var webrtc_confirm_btn: Button
var push_scene_btn: Button
var sync_settings_btn: Button
var sync_files_btn: Button
var update_btn: Button
var webrtc_mode: int = 0

var export_btn: Button
var export_dialog: FileDialog


var lan_container: VBoxContainer
var webrtc_container: VBoxContainer
var lan_tab_btn: Button
var webrtc_tab_btn: Button
var sync_status_btn: Button
var active_tab_style: StyleBoxFlat
var inactive_tab_style: StyleBoxFlat


func _init() -> void:
	name = "Sync Dashboard"

	var scroll = ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 5)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var main_vbox = VBoxContainer.new()
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(main_vbox)

	# --- Title ---
	var title_label = Label.new()
	title_label.text = "Godot Team Create"
	title_label.add_theme_font_override("font", get_theme_font("bold", "Label"))
	title_label.add_theme_font_size_override("font_size", 18)
	main_vbox.add_child(title_label)

	# --- Panel Style ---
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.15, 0.15, 0.15, 1.0) # Dark grey background
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	panel_style.content_margin_left = 10
	panel_style.content_margin_right = 10
	panel_style.content_margin_top = 10
	panel_style.content_margin_bottom = 10

	# --- Status & Users Panel ---
	status_panel = PanelContainer.new()
	status_panel.add_theme_stylebox_override("panel", panel_style)
	main_vbox.add_child(status_panel)

	var status_vbox = VBoxContainer.new()
	status_panel.add_child(status_vbox)

	var status_header = Label.new()
	status_header.text = "Status & Users"
	status_header.add_theme_font_override("font", get_theme_font("bold", "Label"))
	status_vbox.add_child(status_header)

	status_label = Label.new()
	status_label.text = "Status: Disconnected"
	status_label.add_theme_color_override("font_color", Color.GRAY)
	status_vbox.add_child(status_label)

	server_msg_label = Label.new()
	server_msg_label.add_theme_color_override("font_color", Color.YELLOW)
	server_msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	server_msg_label.hide()
	status_vbox.add_child(server_msg_label)

	status_panel.hide()

	users_label = RichTextLabel.new()
	users_label.bbcode_enabled = true
	users_label.text = "Users: 1"
	users_label.fit_content = true
	users_label.scroll_active = false
	status_vbox.add_child(users_label)

	# --- Profile Panel ---
	var profile_panel = PanelContainer.new()
	profile_panel.add_theme_stylebox_override("panel", panel_style)
	main_vbox.add_child(profile_panel)

	var profile_vbox = VBoxContainer.new()
	profile_panel.add_child(profile_vbox)

	var profile_header = Label.new()
	profile_header.text = "Profile"
	profile_header.add_theme_font_override("font", get_theme_font("bold", "Label"))
	profile_vbox.add_child(profile_header)

	username_edit = LineEdit.new()
	username_edit.placeholder_text = "Display Name"
	username_edit.tooltip_text = "Your username across all projects. Max 15 characters."
	username_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	username_edit.max_length = 15
	username_edit.text_changed.connect(_on_username_changed)
	profile_vbox.add_child(username_edit)

	# --- Connectivity Panel ---
	var conn_panel = PanelContainer.new()
	conn_panel.add_theme_stylebox_override("panel", panel_style)
	main_vbox.add_child(conn_panel)

	var conn_vbox = VBoxContainer.new()
	conn_vbox.add_theme_constant_override("separation", 8)
	conn_panel.add_child(conn_vbox)

	var conn_header = Label.new()
	conn_header.text = "Connectivity"
	conn_header.add_theme_font_override("font", get_theme_font("bold", "Label"))
	conn_vbox.add_child(conn_header)

	var tab_hbox = HBoxContainer.new()
	conn_vbox.add_child(tab_hbox)

	active_tab_style = StyleBoxFlat.new()
	active_tab_style.bg_color = Color(0.3, 0.3, 0.3, 1.0)
	active_tab_style.corner_radius_top_left = 6
	active_tab_style.corner_radius_top_right = 6
	active_tab_style.corner_radius_bottom_left = 6
	active_tab_style.corner_radius_bottom_right = 6

	inactive_tab_style = StyleBoxFlat.new()
	inactive_tab_style.bg_color = Color(0.15, 0.15, 0.15, 1.0)
	inactive_tab_style.border_width_bottom = 2
	inactive_tab_style.border_color = Color(0.3, 0.3, 0.3, 1.0)

	lan_tab_btn = Button.new()
	lan_tab_btn.text = "LAN"
	lan_tab_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lan_tab_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	lan_tab_btn.add_theme_stylebox_override("normal", active_tab_style)
	lan_tab_btn.add_theme_stylebox_override("hover", active_tab_style)
	lan_tab_btn.add_theme_stylebox_override("pressed", active_tab_style)
	lan_tab_btn.pressed.connect(_on_lan_tab_pressed)
	tab_hbox.add_child(lan_tab_btn)

	webrtc_tab_btn = Button.new()
	webrtc_tab_btn.text = "WebRTC"
	webrtc_tab_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	webrtc_tab_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	webrtc_tab_btn.add_theme_stylebox_override("normal", inactive_tab_style)
	webrtc_tab_btn.add_theme_stylebox_override("hover", active_tab_style)
	webrtc_tab_btn.add_theme_stylebox_override("pressed", active_tab_style)
	webrtc_tab_btn.pressed.connect(_on_webrtc_tab_pressed)
	tab_hbox.add_child(webrtc_tab_btn)

	# LAN Container
	lan_container = VBoxContainer.new()
	conn_vbox.add_child(lan_container)

	# TODO: Save recently used IP addresses in EditorSettings so users don't have to retype them
	ip_edit = LineEdit.new()
	ip_edit.text = "127.0.0.1"
	ip_edit.placeholder_text = "Host IP Address (e.g., 127.0.0.1)"
	ip_edit.tooltip_text = "Enter the IP address of the host you want to join over LAN."
	ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ip_edit.clear_button_enabled = true
	ip_edit.select_all_on_focus = true
	lan_container.add_child(ip_edit)

	var lan_btn_hbox = HBoxContainer.new()
	lan_container.add_child(lan_btn_hbox)

	host_btn = Button.new()
	host_btn.text = "Host"
	host_btn.tooltip_text = "Start a new LAN server on port 12345."
	host_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_btn.pressed.connect(_on_host_pressed)
	lan_btn_hbox.add_child(host_btn)

	join_btn = Button.new()
	join_btn.text = "Join"
	join_btn.tooltip_text = "Join an existing LAN server using the IP above."
	join_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	join_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_btn.pressed.connect(_on_join_pressed)
	lan_btn_hbox.add_child(join_btn)

	# WebRTC Container
	webrtc_container = VBoxContainer.new()
	webrtc_container.hide() # Hidden by default
	conn_vbox.add_child(webrtc_container)

	var webrtc_btn_hbox = HBoxContainer.new()
	webrtc_container.add_child(webrtc_btn_hbox)

	webrtc_host_btn = Button.new()
	webrtc_host_btn.text = "Host"
	webrtc_host_btn.tooltip_text = "Start a WebRTC session and generate a connection offer."
	webrtc_host_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	webrtc_host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	webrtc_host_btn.pressed.connect(_on_webrtc_host_pressed)
	webrtc_btn_hbox.add_child(webrtc_host_btn)

	webrtc_join_btn = Button.new()
	webrtc_join_btn.text = "Join"
	webrtc_join_btn.tooltip_text = "Join a WebRTC session and paste the host's offer below."
	webrtc_join_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	webrtc_join_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	webrtc_join_btn.pressed.connect(_on_webrtc_join_pressed)
	webrtc_btn_hbox.add_child(webrtc_join_btn)

	webrtc_instructions = Label.new()
	webrtc_instructions.text = "Click 'Host' or 'Join' to start."
	webrtc_instructions.autowrap_mode = TextServer.AUTOWRAP_WORD
	webrtc_instructions.add_theme_font_size_override("font_size", 12)
	webrtc_instructions.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	webrtc_container.add_child(webrtc_instructions)

	webrtc_text = TextEdit.new()
	webrtc_text.custom_minimum_size = Vector2(0, 100)
	webrtc_text.placeholder_text = "Paste WebRTC connection data here..."
	webrtc_text.tooltip_text = "Copy/paste connection strings here to establish WebRTC peer connections."
	webrtc_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	webrtc_container.add_child(webrtc_text)

	webrtc_confirm_btn = Button.new()
	webrtc_confirm_btn.text = "Confirm Connection Data"
	webrtc_confirm_btn.tooltip_text = "Process the connection data pasted above."
	webrtc_confirm_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	webrtc_confirm_btn.pressed.connect(_on_webrtc_confirm_pressed)
	webrtc_container.add_child(webrtc_confirm_btn)

	# Disconnect Button (shared at bottom of connectivity)
	var disconnect_style = StyleBoxFlat.new()
	disconnect_style.bg_color = Color(0.15, 0.15, 0.15, 1.0)
	disconnect_style.border_width_left = 1
	disconnect_style.border_width_right = 1
	disconnect_style.border_width_top = 1
	disconnect_style.border_width_bottom = 1
	disconnect_style.border_color = Color.INDIAN_RED
	disconnect_style.corner_radius_top_left = 6
	disconnect_style.corner_radius_top_right = 6
	disconnect_style.corner_radius_bottom_left = 6
	disconnect_style.corner_radius_bottom_right = 6

	disconnect_btn = Button.new()
	disconnect_btn.text = "Disconnect"
	disconnect_btn.tooltip_text = "Disconnect from the current session."
	disconnect_btn.disabled = true
	disconnect_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	disconnect_btn.add_theme_color_override("font_color", Color.INDIAN_RED)
	disconnect_btn.add_theme_color_override("font_disabled_color", Color(0.5, 0.2, 0.2))
	disconnect_btn.add_theme_stylebox_override("normal", disconnect_style)
	disconnect_btn.pressed.connect(_on_disconnect_pressed)
	conn_vbox.add_child(disconnect_btn)

	# --- Synchronization Panel ---
	var sync_panel = PanelContainer.new()
	sync_panel.add_theme_stylebox_override("panel", panel_style)
	main_vbox.add_child(sync_panel)

	var sync_vbox = VBoxContainer.new()
	sync_vbox.add_theme_constant_override("separation", 8)
	sync_panel.add_child(sync_vbox)

	var sync_header = Label.new()
	sync_header.text = "Synchronization"
	sync_header.add_theme_font_override("font", get_theme_font("bold", "Label"))
	sync_vbox.add_child(sync_header)

	var sync_status_style = StyleBoxFlat.new()
	sync_status_style.bg_color = Color(0.2, 0.3, 0.2, 1.0)
	sync_status_style.corner_radius_top_left = 6
	sync_status_style.corner_radius_top_right = 6
	sync_status_style.corner_radius_bottom_left = 6
	sync_status_style.corner_radius_bottom_right = 6

	sync_status_btn = Button.new()
	sync_status_btn.text = "✓ Up to date!"
	sync_status_btn.add_theme_color_override("font_color", Color.LIGHT_GREEN)
	sync_status_btn.add_theme_stylebox_override("normal", sync_status_style)
	sync_status_btn.add_theme_stylebox_override("disabled", sync_status_style)
	sync_status_btn.disabled = true
	sync_vbox.add_child(sync_status_btn)

	push_scene_btn = Button.new()
	push_scene_btn.text = "Push Current Scene"
	push_scene_btn.tooltip_text = "(Server only) Force push your currently active scene to all clients."
	push_scene_btn.disabled = true
	push_scene_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	push_scene_btn.pressed.connect(_on_push_scene_pressed)
	sync_vbox.add_child(push_scene_btn)

	sync_settings_btn = Button.new()
	sync_settings_btn.text = "Sync Project Settings"
	sync_settings_btn.tooltip_text = "(Server only) Force push project.godot to all clients."
	sync_settings_btn.disabled = true
	sync_settings_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	sync_settings_btn.pressed.connect(_on_sync_settings_pressed)
	sync_vbox.add_child(sync_settings_btn)

	sync_files_btn = Button.new()
	sync_files_btn.text = "Sync All Project Files"
	sync_files_btn.tooltip_text = "Compare and sync all project files across the network."
	sync_files_btn.disabled = true
	sync_status_btn.text = "Not connected"
	sync_status_btn.add_theme_color_override("font_color", Color.GRAY)
	sync_files_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	sync_files_btn.pressed.connect(_on_sync_files_pressed)
	sync_vbox.add_child(sync_files_btn)

	export_btn = Button.new()
	export_btn.text = "Export Headless Server"
	export_btn.tooltip_text = "Generate a standalone server build/scripts to host without the Godot editor."
	export_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	export_btn.pressed.connect(_on_export_pressed)
	sync_vbox.add_child(export_btn)

	main_vbox.add_child(HSeparator.new())

	update_btn = Button.new()
	update_btn.text = "Check for Updates"
	update_btn.tooltip_text = "Check GitHub for newer versions of the Godot Team Create plugin."
	update_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	update_btn.pressed.connect(_on_update_pressed)
	main_vbox.add_child(update_btn)

	export_dialog = FileDialog.new()
	export_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	export_dialog.title = "Select Output Directory for Server Export"
	export_dialog.dir_selected.connect(_on_export_dir_selected)
	add_child(export_dialog)


func _on_lan_tab_pressed() -> void:
	lan_container.show()
	webrtc_container.hide()

	lan_tab_btn.add_theme_stylebox_override("normal", active_tab_style)
	webrtc_tab_btn.add_theme_stylebox_override("normal", inactive_tab_style)

func _on_webrtc_tab_pressed() -> void:
	webrtc_container.show()
	lan_container.hide()

	webrtc_tab_btn.add_theme_stylebox_override("normal", active_tab_style)
	lan_tab_btn.add_theme_stylebox_override("normal", inactive_tab_style)


func _ready() -> void:
	if network and network.plugin:
		var settings = network.plugin.get_editor_interface().get_editor_settings()
		if settings.has_setting("team_create/username"):
			var saved_name = settings.get_setting("team_create/username")
			if saved_name != "":
				username_edit.text = saved_name
				_on_username_changed(saved_name)

func set_connected(is_host: bool, connected_to_standalone: bool = false) -> void:
	host_btn.disabled = true
	join_btn.disabled = true
	webrtc_host_btn.disabled = true
	webrtc_join_btn.disabled = true
	webrtc_confirm_btn.disabled = true
	webrtc_host_btn.text = "Host"
	webrtc_join_btn.text = "Join"
	webrtc_mode = 0
	disconnect_btn.disabled = false
	push_scene_btn.disabled = false
	sync_settings_btn.disabled = false
	sync_files_btn.disabled = false
	sync_status_btn.text = "✓ Up to date!"
	sync_status_btn.add_theme_color_override("font_color", Color.LIGHT_GREEN)

	status_panel.show()
	var username = username_edit.text if username_edit.text != "" else "You"
	if is_host:
		status_label.text = "Status: " + username + " Connected (Host)"
		status_label.add_theme_color_override("font_color", Color.GREEN)
	else:
		if connected_to_standalone:
			status_label.text = "Status: Connected to Server"
		else:
			status_label.text = "Status: " + username + " Connected (Client)"
		status_label.add_theme_color_override("font_color", Color.GREEN)

func set_disconnected() -> void:
	host_btn.disabled = false
	join_btn.disabled = false
	webrtc_host_btn.disabled = false
	webrtc_join_btn.disabled = false
	webrtc_confirm_btn.disabled = false
	webrtc_confirm_btn.text = "Confirm Connection Data"
	webrtc_host_btn.text = "Host"
	webrtc_join_btn.text = "Join"
	webrtc_mode = 0
	disconnect_btn.disabled = true
	push_scene_btn.disabled = true
	sync_settings_btn.disabled = true
	sync_files_btn.disabled = true
	sync_status_btn.text = "Not connected"
	sync_status_btn.add_theme_color_override("font_color", Color.GRAY)

	status_panel.hide()
	update_webrtc_instructions("Click 'Host' or 'Join' to start.")
	update_webrtc_text("")

	status_label.text = "Status: Disconnected"
	status_label.add_theme_color_override("font_color", Color.GRAY)
	users_label.text = "Users: 1"

func update_users_count(count: int) -> void:
	if network:
		var visible_count = count
		var has_standalone = false
		if network.peers.has(1) and network.peers[1].has("is_standalone") and network.peers[1]["is_standalone"]:
			has_standalone = true
			visible_count -= 1

		var text = "Users: " + str(visible_count) + "\n"
		for peer_id in network.peers:
			if peer_id == 1 and has_standalone:
				continue

			var username = network.get_username(peer_id)
			var color = network.get_user_color(peer_id).to_html()
			if peer_id == network.multiplayer.get_unique_id():
				text += "[color=#" + color + "]" + username + " (You)[/color]\n"
			else:
				text += "[color=#" + color + "]" + username + "[/color]\n"
		users_label.text = text
	else:
		users_label.text = "Users: " + str(count)

func show_server_message(msg: String) -> void:
	if server_msg_label:
		server_msg_label.text = msg
		server_msg_label.show()
		var t = get_tree().create_timer(5.0)
		t.timeout.connect(func():
			if is_instance_valid(server_msg_label):
				server_msg_label.hide()
		)

func _on_username_changed(new_text: String) -> void:
	if network:
		if network.plugin:
			var settings = network.plugin.get_editor_interface().get_editor_settings()
			settings.set_setting("team_create/username", new_text)

		network.update_local_username(new_text)

func _on_host_pressed() -> void:
	if network:
		network.host_server()

func _on_join_pressed() -> void:
	if network:
		network.join_server(ip_edit.text)

func _on_webrtc_host_pressed() -> void:
	if network:
		if webrtc_mode == 1:
			network.disconnect_peer()
		else:
			webrtc_mode = 1
			webrtc_join_btn.disabled = true
			webrtc_host_btn.text = "Cancel"
			disconnect_btn.disabled = false
			network.webrtc_host()

func _on_webrtc_join_pressed() -> void:
	if network:
		if webrtc_mode == 2:
			network.disconnect_peer()
		else:
			webrtc_mode = 2
			webrtc_host_btn.disabled = true
			webrtc_join_btn.text = "Cancel"
			disconnect_btn.disabled = false
			network.webrtc_join()

func _on_webrtc_confirm_pressed() -> void:
	if network:
		network.webrtc_confirm(webrtc_text.text)

func disable_webrtc_confirm() -> void:
	if webrtc_confirm_btn:
		webrtc_confirm_btn.disabled = true
		webrtc_confirm_btn.text = "Confirming..."
	update_webrtc_instructions("Processing connection data... Waiting for peer connection.")

func enable_webrtc_confirm() -> void:
	if webrtc_confirm_btn:
		webrtc_confirm_btn.disabled = false
		webrtc_confirm_btn.text = "Confirm Connection Data"


func update_webrtc_instructions(text: String) -> void:
	if webrtc_instructions:
		webrtc_instructions.text = text

func update_webrtc_text(text: String) -> void:
	if webrtc_text:
		webrtc_text.text = text

func _on_disconnect_pressed() -> void:
	if network:
		network.disconnect_peer()

func _on_push_scene_pressed() -> void:
	if network:
		network.push_current_scene()

func _on_sync_settings_pressed() -> void:
	if network:
		network.sync_project_settings()

func _on_sync_files_pressed() -> void:
	if network:
		network.sync_all_files()

func _on_update_pressed() -> void:
	if network and network.plugin:
		if update_btn.text == "Update Available!":
			network.plugin.download_update()
		else:
			update_btn.text = "Checking..."
			update_btn.disabled = true
			network.plugin.check_for_updates()


func _on_export_pressed() -> void:
	if export_dialog:
		export_dialog.popup_centered_ratio(0.5)

func _on_export_dir_selected(dir: String) -> void:
	if network and network.plugin:
		var exporter_script = load("res://addons/team_create/server_exporter.gd")
		if exporter_script:
			# TODO: Add AcceptDialog popup on failure instead of just printing to console
			exporter_script.export_server(dir, self)
		else:
			network.tc_print("Failed to load server_exporter.gd")
