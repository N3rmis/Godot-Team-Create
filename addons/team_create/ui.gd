@tool
extends Control

var network: Node

# UI Elements
var status_panel: PanelContainer
var status_label: Label
var deploy_btn: Button
var deploy_status_label: Label
var deploy_dialog: ConfirmationDialog
var users_label: RichTextLabel
var server_msg_label: Label
var ip_edit: LineEdit
var username_edit: LineEdit
var color_picker: ColorPickerButton
var _shown_color = Color.WHITE
var _has_saved_color = false
var password_edit: LineEdit
var remember_check: CheckBox
const SAVED_LOGINS_FILE = "team_create_logins.cfg"
const AUTO_JOIN_DELAY_SEC = 2.0
var _saved_login_address = ""
var _saved_login_key = PackedByteArray()
var _join_address = ""
var _accepted_key = PackedByteArray()
var _connect_pressed = false
var _update_prompt: ConfirmationDialog
var host_btn: Button
var join_btn: Button
var disconnect_btn: Button


var export_btn: Button
var export_dialog: FileDialog
var backup_scene_btn: Button


var lan_container: VBoxContainer
var sync_status_btn: Button



var _ui_built = false
var _bold_labels = []
var title_label: Label
var status_header: Label
var profile_header: Label
var conn_header: Label
var sync_header: Label

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_READY:
		_apply_theme_overrides()

func _init() -> void:
	name = "Team Create"
	_build_ui()

func _apply_theme_overrides() -> void:
	if not is_inside_tree():
		return
	var bold_font = get_theme_font("bold", "Label") if has_theme_font("bold", "Label") else null
	if bold_font:
		for lbl in _bold_labels:
			if is_instance_valid(lbl):
				lbl.add_theme_font_override("font", bold_font)

func _get_editor_settings() -> EditorSettings:
	if Engine.is_editor_hint() and ClassDB.class_exists("EditorInterface"):
		return EditorInterface.get_editor_settings()
	if network and network.plugin and network.plugin.has_method("get_editor_interface"):
		return network.plugin.get_editor_interface().get_editor_settings()
	return null

func _build_ui() -> void:
	if _ui_built:
		return
	_ui_built = true

	var scroll = ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 5)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	var main_vbox = VBoxContainer.new()
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(main_vbox)

	# --- Title ---
	title_label = Label.new()
	title_label.text = "Godot Team Create"
	title_label.add_theme_font_size_override("font_size", 18)
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bold_labels.append(title_label)
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
	status_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(status_panel)

	var status_vbox = VBoxContainer.new()
	status_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_panel.add_child(status_vbox)

	status_header = Label.new()
	status_header.text = "Status & Users"
	status_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bold_labels.append(status_header)
	status_vbox.add_child(status_header)

	status_label = Label.new()
	status_label.text = "Status: Disconnected"
	status_label.add_theme_color_override("font_color", Color.GRAY)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_vbox.add_child(status_label)

	server_msg_label = Label.new()
	server_msg_label.add_theme_color_override("font_color", Color.YELLOW)
	server_msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	server_msg_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	server_msg_label.hide()
	status_vbox.add_child(server_msg_label)

	status_panel.hide()

	users_label = RichTextLabel.new()
	users_label.bbcode_enabled = true
	users_label.text = "Users: 1"
	users_label.fit_content = true
	users_label.scroll_active = false
	users_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	users_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_vbox.add_child(users_label)

	# --- Profile Panel ---
	var profile_panel = PanelContainer.new()
	profile_panel.add_theme_stylebox_override("panel", panel_style)
	profile_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(profile_panel)

	var profile_vbox = VBoxContainer.new()
	profile_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	profile_panel.add_child(profile_vbox)

	profile_header = Label.new()
	profile_header.text = "Profile"
	profile_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	profile_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bold_labels.append(profile_header)
	profile_vbox.add_child(profile_header)

	username_edit = LineEdit.new()
	username_edit.placeholder_text = "Display Name"
	username_edit.tooltip_text = "Your username across all projects. Max 15 characters."
	username_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	username_edit.max_length = 15
	username_edit.text_changed.connect(_on_username_changed)

	var profile_hbox = HBoxContainer.new()
	profile_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	profile_vbox.add_child(profile_hbox)
	profile_hbox.add_child(username_edit)

	color_picker = ColorPickerButton.new()
	color_picker.tooltip_text = "Your colour across all projects, shown on your cursor, selections and chat messages."
	color_picker.custom_minimum_size = Vector2(44, 0) * (EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0)
	color_picker.edit_alpha = false
	color_picker.color = _shown_color
	color_picker.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	color_picker.popup_closed.connect(_on_color_picker_closed)
	profile_hbox.add_child(color_picker)

	# --- Connectivity Panel ---
	var conn_panel = PanelContainer.new()
	conn_panel.add_theme_stylebox_override("panel", panel_style)
	conn_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(conn_panel)

	var conn_vbox = VBoxContainer.new()
	conn_vbox.add_theme_constant_override("separation", 8)
	conn_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	conn_panel.add_child(conn_vbox)

	conn_header = Label.new()
	conn_header.text = "Connectivity"
	conn_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	conn_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bold_labels.append(conn_header)
	conn_vbox.add_child(conn_header)

	# LAN Container
	lan_container = VBoxContainer.new()
	lan_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	conn_vbox.add_child(lan_container)

	ip_edit = LineEdit.new()
	ip_edit.text = "127.0.0.1"
	ip_edit.placeholder_text = "Host IP or Domain (e.g., play.example.com)"
	ip_edit.tooltip_text = "Enter the IP address or domain of the host you want to join."
	ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ip_edit.clear_button_enabled = true
	ip_edit.select_all_on_focus = true
	ip_edit.text_changed.connect(_on_ip_changed)
	lan_container.add_child(ip_edit)

	password_edit = LineEdit.new()
	password_edit.placeholder_text = "Server Password"
	password_edit.tooltip_text = "Required to join a password-protected server. Host LAN uses it as the session password."
	password_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	password_edit.secret = true
	password_edit.clear_button_enabled = true
	lan_container.add_child(password_edit)

	remember_check = CheckBox.new()
	remember_check.text = "Remember Password"
	remember_check.tooltip_text = "Saves a hash of the password on this computer, for this project and server, once it's accepted. The editor then joins by itself when this project opens, which makes the project folder match the server. Untick to forget it."
	remember_check.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	remember_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	remember_check.toggled.connect(_on_remember_toggled)
	lan_container.add_child(remember_check)

	var lan_btn_hbox = HBoxContainer.new()
	lan_btn_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lan_container.add_child(lan_btn_hbox)

	host_btn = Button.new()
	host_btn.text = "Host LAN"
	host_btn.tooltip_text = "Starts server on LAN and automatically connects you to it."
	host_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	host_btn.pressed.connect(_on_host_pressed)
	lan_btn_hbox.add_child(host_btn)

	join_btn = Button.new()
	join_btn.text = "Join"
	join_btn.tooltip_text = "Join an existing LAN server using the IP above."
	join_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	join_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	join_btn.pressed.connect(_on_join_pressed)
	lan_btn_hbox.add_child(join_btn)

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
	disconnect_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	disconnect_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	disconnect_btn.add_theme_color_override("font_color", Color.INDIAN_RED)
	disconnect_btn.add_theme_color_override("font_disabled_color", Color(0.5, 0.2, 0.2))
	disconnect_btn.add_theme_stylebox_override("normal", disconnect_style)
	disconnect_btn.pressed.connect(_on_disconnect_pressed)
	conn_vbox.add_child(disconnect_btn)

	# --- Synchronization Panel ---
	var sync_panel = PanelContainer.new()
	sync_panel.add_theme_stylebox_override("panel", panel_style)
	sync_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(sync_panel)

	var sync_vbox = VBoxContainer.new()
	sync_vbox.add_theme_constant_override("separation", 8)
	sync_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sync_panel.add_child(sync_vbox)

	sync_header = Label.new()
	sync_header.text = "Synchronization"
	sync_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sync_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bold_labels.append(sync_header)
	sync_vbox.add_child(sync_header)

	var sync_status_style = StyleBoxFlat.new()
	sync_status_style.bg_color = Color(0.2, 0.3, 0.2, 1.0)
	sync_status_style.corner_radius_top_left = 6
	sync_status_style.corner_radius_top_right = 6
	sync_status_style.corner_radius_bottom_left = 6
	sync_status_style.corner_radius_bottom_right = 6

	sync_status_btn = Button.new()
	sync_status_btn.text = "Not connected"
	sync_status_btn.add_theme_color_override("font_color", Color.GRAY)
	sync_status_btn.add_theme_stylebox_override("normal", sync_status_style)
	sync_status_btn.add_theme_stylebox_override("disabled", sync_status_style)
	sync_status_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sync_status_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sync_status_btn.disabled = true
	sync_vbox.add_child(sync_status_btn)


	export_btn = Button.new()
	export_btn.text = "Export Headless Server"
	export_btn.tooltip_text = "Generate standalone server scripts to host without the Godot editor."
	export_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	export_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	export_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	export_btn.pressed.connect(_on_export_pressed)
	sync_vbox.add_child(export_btn)

	backup_scene_btn = Button.new()
	backup_scene_btn.text = "Create Backup"
	backup_scene_btn.tooltip_text = "Create a timestamped snapshot backup of the current scene."
	backup_scene_btn.disabled = true
	backup_scene_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	backup_scene_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	backup_scene_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	backup_scene_btn.pressed.connect(_on_backup_scene_pressed)
	sync_vbox.add_child(backup_scene_btn)

	deploy_btn = Button.new()
	deploy_btn.text = "Deploy to Website"
	deploy_btn.tooltip_text = "Publish what's saved on the server to the live website, for everyone playing the game."
	deploy_btn.visible = false
	deploy_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	deploy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deploy_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	deploy_btn.pressed.connect(_on_deploy_pressed)
	sync_vbox.add_child(deploy_btn)

	deploy_status_label = Label.new()
	deploy_status_label.visible = false
	deploy_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	deploy_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sync_vbox.add_child(deploy_status_label)

	deploy_dialog = ConfirmationDialog.new()
	deploy_dialog.title = "Deploy to Website"
	deploy_dialog.dialog_text = "Publish the project to the live website?\n\nThis replaces the game for everyone playing it. Save your scenes first, as tilemap and animation edits only reach the server when saved."
	deploy_dialog.dialog_autowrap = true
	deploy_dialog.ok_button_text = "Deploy"
	deploy_dialog.min_size = Vector2i(420, 0)
	deploy_dialog.confirmed.connect(_on_deploy_confirmed)
	add_child(deploy_dialog)

	export_dialog = FileDialog.new()
	export_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	export_dialog.title = "Select Output Directory for Server Export"
	export_dialog.dir_selected.connect(_on_export_dir_selected)
	add_child(export_dialog)


func _ready() -> void:
	_build_ui()
	_apply_theme_overrides()

	var settings = _get_editor_settings()
	if settings:
		if settings.has_setting("team_create/username"):
			var saved_name = settings.get_setting("team_create/username")
			if saved_name != "":
				username_edit.text = saved_name
				_on_username_changed(saved_name)

		if settings.has_setting("team_create/color"):
			var saved_color = settings.get_setting("team_create/color")
			if saved_color is String and Color.html_is_valid(saved_color):
				_has_saved_color = true
				_show_color(Color.html(saved_color))
				if network:
					network.update_local_color(_shown_color)

		if settings.has_setting("team_create/last_ip"):
			var saved_ip = settings.get_setting("team_create/last_ip")
			if saved_ip != "":
				ip_edit.text = saved_ip
				_on_ip_changed(saved_ip)

	_load_saved_login()
	_auto_join_saved_login()

func set_connected(is_host: bool, connected_to_standalone: bool = false) -> void:
	host_btn.disabled = true
	join_btn.disabled = true
	disconnect_btn.disabled = false
	backup_scene_btn.disabled = false
	sync_status_btn.text = "✓ Up to date!"
	sync_status_btn.add_theme_color_override("font_color", Color.LIGHT_GREEN)

	status_panel.show()
	var username = username_edit.text if username_edit.text != "" else "You"
	if is_host:
		status_label.text = "Status: Connected (Host)\nUser: " + username
		status_label.add_theme_color_override("font_color", Color.GREEN)
	else:
		if connected_to_standalone:
			status_label.text = "Status: Connected to Server\nUser: " + username
		else:
			status_label.text = "Status: Connected (Client)\nUser: " + username
		status_label.add_theme_color_override("font_color", Color.GREEN)

func _on_deploy_pressed() -> void:
	deploy_dialog.popup_centered()

func _on_deploy_confirmed() -> void:
	if network and network.deploy_sync:
		network.deploy_sync.press_deploy()

func update_deploy_state() -> void:
	var deploy = network.deploy_sync if network else null
	deploy_btn.visible = deploy != null and deploy.available
	deploy_btn.disabled = deploy == null or deploy.running
	deploy_status_label.text = deploy.message if deploy else ""
	deploy_status_label.visible = deploy_status_label.text != ""

func set_disconnected() -> void:
	if network and network.deploy_sync:
		network.deploy_sync.reset()
	update_deploy_state()
	host_btn.disabled = false
	join_btn.disabled = false
	disconnect_btn.disabled = true
	backup_scene_btn.disabled = true
	sync_status_btn.text = "Not connected"
	sync_status_btn.add_theme_color_override("font_color", Color.GRAY)

	status_panel.hide()

	status_label.text = "Status: Disconnected"
	status_label.add_theme_color_override("font_color", Color.GRAY)
	users_label.text = "Users: 1"
	username_edit.placeholder_text = "Display Name"

func update_users_count(count: int) -> void:
	if network:
		var visible_count = count
		var has_standalone = false
		if network.peers.has(1) and network.peers[1].has("is_standalone") and network.peers[1]["is_standalone"]:
			has_standalone = true
			visible_count -= 1

		var text = "Users: " + str(visible_count) + "\n"
		var my_id = 0
		if network and network.is_connected_to_session():
			my_id = network.multiplayer.get_unique_id()

		for peer_id in network.peers:
			if peer_id == 1 and has_standalone:
				continue

			var username = network.get_username(peer_id)
			var color = network.get_user_color(peer_id).to_html()
			if my_id != 0 and peer_id == my_id:
				text += "[color=#" + color + "]" + username + " (You)[/color]\n"
			else:
				text += "[color=#" + color + "]" + username + "[/color]\n"
		users_label.text = text
		if my_id != 0 and network.peers.has(my_id):
			# Until a colour has been picked, show the one the server assigned
			if not _has_saved_color:
				_show_color(network.get_user_color(my_id))
			# With no name set, this is what everyone else sees
			username_edit.placeholder_text = network.get_username(my_id)
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
	var settings = _get_editor_settings()
	if settings:
		settings.set_setting("team_create/username", new_text)
	if network:
		network.update_local_username(new_text)

func _show_color(color: Color) -> void:
	_shown_color = color
	color_picker.color = color

func _on_color_picker_closed() -> void:
	if color_picker.color == _shown_color:
		return
	_shown_color = color_picker.color
	_has_saved_color = true
	var settings = _get_editor_settings()
	if settings:
		settings.set_setting("team_create/color", _shown_color.to_html(false))
	if network:
		network.update_local_color(_shown_color)

func _on_ip_changed(new_text: String) -> void:
	var settings = _get_editor_settings()
	if settings:
		settings.set_setting("team_create/last_ip", new_text)
	_update_password_placeholder()

func _on_host_pressed() -> void:
	_connect_pressed = true
	if network:
		network.scenes_to_reopen = PackedStringArray()
		_join_address = ""
		_accepted_key = PackedByteArray()
		network.saved_auth_key = PackedByteArray()
		network.session_password = password_edit.text
		network.host_lan_server(ip_edit.text)

func _on_join_pressed() -> void:
	_connect_pressed = true
	if network:
		network.scenes_to_reopen = PackedStringArray()
	_join()

func _join() -> void:
	if network:
		if network.has_method("stop_local_server"):
			network.stop_local_server()
		_join_address = ip_edit.text.strip_edges()
		_accepted_key = PackedByteArray()
		network.saved_auth_key = _saved_key_for_address() if password_edit.text == "" else PackedByteArray()
		network.session_password = password_edit.text
		network.join_server(ip_edit.text)

func _saved_key_for_address() -> PackedByteArray:
	if ip_edit.text.strip_edges() == _saved_login_address:
		return _saved_login_key
	return PackedByteArray()

func _update_password_placeholder() -> void:
	password_edit.placeholder_text = "Saved Password" if not _saved_key_for_address().is_empty() else "Server Password"

func _saved_logins_path() -> String:
	return EditorInterface.get_editor_paths().get_config_dir().path_join(SAVED_LOGINS_FILE)

# Logins are kept per project, because joining makes the project folder match the server.
# The last address is shared between projects, so it can't be what decides to auto-join.
# They're also kept outside the project, where they would sync to everyone.
func _saved_login_section() -> String:
	return ProjectSettings.globalize_path("res://").sha256_text()

func _load_saved_login() -> void:
	var config = ConfigFile.new()
	if config.load(_saved_logins_path()) != OK:
		return
	var address = str(config.get_value(_saved_login_section(), "address", ""))
	var key = str(config.get_value(_saved_login_section(), "key", "")).hex_decode()
	if address == "" or key.size() != 32:
		return
	_saved_login_address = address
	_saved_login_key = key
	remember_check.set_pressed_no_signal(true)
	ip_edit.text = address
	_on_ip_changed(address)

func _write_saved_logins(config: ConfigFile) -> void:
	var path = _saved_logins_path()
	var err = config.save(path)
	if err != OK:
		push_warning("Team Create could not update its saved logins: " + error_string(err))
	elif OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(path, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)

func _save_login(address: String, key: PackedByteArray) -> void:
	if address == "" or (address == _saved_login_address and key == _saved_login_key):
		return
	var config = ConfigFile.new()
	config.load(_saved_logins_path())
	config.set_value(_saved_login_section(), "address", address)
	config.set_value(_saved_login_section(), "key", key.hex_encode())
	_write_saved_logins(config)
	_saved_login_address = address
	_saved_login_key = key
	_update_password_placeholder()

func forget_saved_login() -> void:
	_saved_login_address = ""
	_saved_login_key = PackedByteArray()
	_update_password_placeholder()
	var config = ConfigFile.new()
	if config.load(_saved_logins_path()) == OK and config.has_section(_saved_login_section()):
		config.erase_section(_saved_login_section())
		_write_saved_logins(config)

func on_password_accepted(key: PackedByteArray) -> void:
	_accepted_key = key
	if remember_check.button_pressed:
		_save_login(_join_address, key)

func _on_remember_toggled(remember: bool) -> void:
	if not remember:
		forget_saved_login()
	elif not _accepted_key.is_empty() and network and network.is_connected_to_session():
		_save_login(_join_address, _accepted_key)

func _auto_join_saved_login() -> void:
	if _saved_login_key.is_empty() or DisplayServer.get_name() == "headless":
		return
	# Joining reloads files, so let the editor finish restoring the project first
	await get_tree().create_timer(AUTO_JOIN_DELAY_SEC).timeout
	var filesystem = EditorInterface.get_resource_filesystem()
	while filesystem.is_scanning():
		await get_tree().create_timer(0.5).timeout
	if not _connect_pressed and not _saved_key_for_address().is_empty():
		network.scenes_to_reopen = _open_scenes_current_last()
		_join()

func _open_scenes_current_last() -> PackedStringArray:
	var scenes = EditorInterface.get_open_scenes()
	var current = EditorInterface.get_edited_scene_root()
	if current and current.scene_file_path in scenes:
		scenes.remove_at(scenes.find(current.scene_file_path))
		scenes.append(current.scene_file_path)
	return scenes

func _on_disconnect_pressed() -> void:
	if network:
		network.disconnect_peer(true)
		if network.has_method("stop_local_server"):
			network.stop_local_server()

func _on_backup_scene_pressed() -> void:
	if network:
		network.create_backup()
		backup_scene_btn.text = "✓ Backup Created!"
		get_tree().create_timer(2.5).timeout.connect(func():
			if is_instance_valid(backup_scene_btn):
				backup_scene_btn.text = "Create Backup"
		)

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


func show_error(title: String, message: String) -> void:
	var dialog = AcceptDialog.new()
	dialog.title = title
	dialog.dialog_text = message
	add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)

func show_plugin_update_prompt(codes: String) -> void:
	if is_instance_valid(_update_prompt):
		_update_prompt.queue_free()
	_update_prompt = ConfirmationDialog.new()
	_update_prompt.title = "Update Team Create?"
	_update_prompt.dialog_text = "The server is running a different copy of the Team Create plugin, so you can't join with this one. " + codes + "\n\nInstall the server's copy? Your open scenes will be saved and the editor will restart."
	_update_prompt.dialog_autowrap = true
	_update_prompt.min_size = Vector2i(480, 0) * (EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0)
	_update_prompt.ok_button_text = "Update and Restart"
	_update_prompt.cancel_button_text = "Not Now"
	_update_prompt.confirmed.connect(network.download_plugin_update)
	add_child(_update_prompt)
	_update_prompt.popup_centered()
