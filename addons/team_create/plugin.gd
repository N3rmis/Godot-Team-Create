@tool
extends EditorPlugin

var dock: Control
var chat_dock: Control
var network: Node
var export_plugin: EditorExportPlugin = null
var _disk_changed_dialogs: Array[ConfirmationDialog] = []

func _enter_tree() -> void:
	# Register automated export cleaner to ensure builds contain zero traces of Team Create
	if has_method("add_export_plugin"):
		export_plugin = TeamCreateExportPlugin.new()
		add_export_plugin(export_plugin)

	# Load UI script and instantiate it.
	# We're building the UI dynamically to ensure stability and match the screenshot.
	var ui_script = load("res://addons/team_create/ui.gd")
	var network_script = load("res://addons/team_create/network.gd")

	if ui_script == null or network_script == null:
		printerr("Team Create failed to load core scripts! Reinstall the plugin.")
		return

	var chat_script = load("res://addons/team_create/chat_window.gd")
	dock = ui_script.new()
	chat_dock = chat_script.new()

	# Load network manager script and instantiate it as a child.
	network = network_script.new()
	network.name = "TeamCreateNetwork"

	# Link UI and network
	dock.network = network
	network.ui = dock

	chat_dock.network = network
	network.chat_window = chat_dock

	network.plugin = self

	add_control_to_dock(DOCK_SLOT_LEFT_UR, dock)
	add_control_to_bottom_panel(chat_dock, "Team Chat")
	get_tree().root.add_child(network)

	network.tc_print("Team Create initialized.")

	_schedule_dock_focus()

	if has_signal("scene_saved"):
		if not scene_saved.is_connected(_on_scene_saved):
			scene_saved.connect(_on_scene_saved)

	if has_signal("scene_closed"):
		if not scene_closed.is_connected(_on_scene_closed):
			scene_closed.connect(_on_scene_closed)

	# Intercept and suppress external file modification dialog while connected to session
	_setup_disk_changed_interceptor()

func _schedule_dock_focus() -> void:
	_open_and_prioritize_dock()
	call_deferred("_open_and_prioritize_dock")
	if is_inside_tree() and get_tree():
		await get_tree().process_frame
		await get_tree().process_frame
		_open_and_prioritize_dock()

func _open_and_prioritize_dock() -> void:
	if not is_instance_valid(dock):
		return
	var tab_container: TabContainer = null
	var dock_tab_node: Node = dock

	var current: Node = dock
	while current:
		var parent = current.get_parent()
		if parent is TabContainer:
			tab_container = parent
			dock_tab_node = current
			break
		current = parent

	if tab_container and is_instance_valid(dock_tab_node):
		tab_container.move_child(dock_tab_node, 0)
		tab_container.current_tab = 0
		var tab_bar = tab_container.get_tab_bar()
		if tab_bar:
			tab_bar.current_tab = 0
			tab_bar.ensure_tab_visible(0)
		if dock_tab_node.has_method("make_visible"):
			dock_tab_node.make_visible()
		elif dock_tab_node.has_method("open"):
			dock_tab_node.open()

# The editor is about to save, so nodes still gliding need their exact values
func _apply_changes() -> void:
	if network and network.scene_sync:
		network.scene_sync.finish_remote_moves()

func _exit_tree() -> void:
	_cleanup_disk_changed_interceptor()

	if export_plugin and has_method("remove_export_plugin"):
		remove_export_plugin(export_plugin)
		export_plugin = null

	if has_signal("scene_saved") and scene_saved.is_connected(_on_scene_saved):
		scene_saved.disconnect(_on_scene_saved)

	if has_signal("scene_closed") and scene_closed.is_connected(_on_scene_closed):
		scene_closed.disconnect(_on_scene_closed)

	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()
		dock = null
	if chat_dock:
		remove_control_from_bottom_panel(chat_dock)
		chat_dock.queue_free()
		chat_dock = null
	if network:
		if network.scene_sync:
			var cur_scn = network.scene_sync._get_edited_scene_root()
			if cur_scn and cur_scn.scene_file_path != "":
				network.scene_sync.save_current_camera_for_scene(cur_scn.scene_file_path, true)
			network.scene_sync._save_camera_cache()
		if network.script_sync:
			network.script_sync.clear_all()
		if network.get_parent():
			network.get_parent().remove_child(network)
		network.queue_free()
		network = null

func _on_scene_saved(filepath: String) -> void:
	if network and network.has_method("on_local_scene_saved"):
		network.on_local_scene_saved(filepath)

func _on_scene_closed(filepath: String) -> void:
	if network and network.has_method("on_scene_closed"):
		network.on_scene_closed(filepath)

func _force_close_all_scenes() -> void:
	var editor = get_editor_interface()
	if not editor:
		return

	if editor.has_method("get_open_scenes") and editor.has_method("close_scene"):
		var open_scenes = editor.get_open_scenes()
		for _i in range(open_scenes.size() + 2):
			if editor.close_scene() != OK:
				break
		return

	var base_control = editor.get_base_control()
	var scene_tabs: TabBar = null

	var nodes_to_check = [base_control]
	while not nodes_to_check.is_empty():
		var current = nodes_to_check.pop_front()
		if current is TabBar and current.get_parent() is VBoxContainer and current.get_parent().get_parent() is MarginContainer:
			scene_tabs = current
			break
		nodes_to_check.append_array(current.get_children())

	if scene_tabs:
		for i in range(scene_tabs.get_tab_count() - 1, -1, -1):
			scene_tabs.emit_signal("tab_close_pressed", i)


# ==============================================================================
# External File Modification Dialog Interceptor
# Auto-suppresses "Files have been modified outside Godot" popup while connected
# ==============================================================================
func _setup_disk_changed_interceptor() -> void:
	if not Engine.is_editor_hint():
		return
	call_deferred("_hook_disk_changed_dialogs")

func _hook_disk_changed_dialogs() -> void:
	var found = _find_all_disk_changed_dialogs()
	for dlg in found:
		if dlg in _disk_changed_dialogs:
			continue
		_disk_changed_dialogs.append(dlg)
		var cb_about = Callable(self, "_on_disk_changed_about_to_popup").bind(dlg)
		if not dlg.about_to_popup.is_connected(cb_about):
			dlg.about_to_popup.connect(cb_about)
		var cb_vis = Callable(self, "_on_disk_changed_visibility_changed").bind(dlg)
		if not dlg.visibility_changed.is_connected(cb_vis):
			dlg.visibility_changed.connect(cb_vis)

	# If fewer than 2 dialogs (scene and script) found, retry periodically until both are ready
	if is_inside_tree() and _disk_changed_dialogs.size() < 2:
		get_tree().create_timer(1.0).timeout.connect(_hook_disk_changed_dialogs)

func _cleanup_disk_changed_interceptor() -> void:
	for dlg in _disk_changed_dialogs:
		if is_instance_valid(dlg):
			var cb_about = Callable(self, "_on_disk_changed_about_to_popup").bind(dlg)
			if dlg.about_to_popup.is_connected(cb_about):
				dlg.about_to_popup.disconnect(cb_about)
			var cb_vis = Callable(self, "_on_disk_changed_visibility_changed").bind(dlg)
			if dlg.visibility_changed.is_connected(cb_vis):
				dlg.visibility_changed.disconnect(cb_vis)
	_disk_changed_dialogs.clear()

func _find_all_disk_changed_dialogs() -> Array[ConfirmationDialog]:
	var result: Array[ConfirmationDialog] = []
	if not has_method("get_editor_interface"):
		return result
	var ei = get_editor_interface()
	if not ei or not is_instance_valid(ei):
		return result

	var candidates: Array[Node] = []
	var base = ei.get_base_control()
	if base and is_instance_valid(base):
		candidates.append(base)
	if ei.has_method("get_script_editor"):
		var se = ei.get_script_editor()
		if se and is_instance_valid(se):
			candidates.append(se)
	if is_inside_tree() and get_tree().root:
		candidates.append(get_tree().root)

	for parent in candidates:
		for child in parent.get_children():
			if _is_disk_changed_dialog(child) and not child in result:
				result.append(child as ConfirmationDialog)
			for sub in child.get_children():
				if _is_disk_changed_dialog(sub) and not sub in result:
					result.append(sub as ConfirmationDialog)

	return result

func _is_disk_changed_dialog(node: Node) -> bool:
	if not (node is ConfirmationDialog):
		return false
	var dlg = node as ConfirmationDialog
	var title = dlg.title.to_lower()
	if "modified outside godot" in title or "files have been modified" in title:
		return true
	for child in dlg.get_children():
		if child is VBoxContainer:
			for sub in child.get_children():
				if sub is Label:
					var txt = sub.text.to_lower()
					if "newer on disk" in txt or "modified outside" in txt:
						return true
	return false

func _on_disk_changed_about_to_popup(dlg: ConfirmationDialog) -> void:
	if network and network.has_method("is_connected_to_session") and network.is_connected_to_session():
		if is_instance_valid(dlg):
			call_deferred("_deferred_hide_dialog", dlg)

func _on_disk_changed_visibility_changed(dlg: ConfirmationDialog) -> void:
	if is_instance_valid(dlg) and dlg.visible:
		if network and network.has_method("is_connected_to_session") and network.is_connected_to_session():
			call_deferred("_deferred_hide_dialog", dlg)

func _deferred_hide_dialog(dlg: ConfirmationDialog) -> void:
	if is_instance_valid(dlg):
		if network and network.has_method("is_connected_to_session") and network.is_connected_to_session():
			if dlg.visible:
				dlg.hide()


# ==============================================================================
# Automated Export Cleaner
# Strips all plugin files and _tc_* metadata from exported game builds.
# ==============================================================================
class TeamCreateExportPlugin extends EditorExportPlugin:
	func _get_name() -> String:
		return "TeamCreateExportCleaner"

	func _get_customization_configuration_hash() -> int:
		return "TeamCreateExportCleaner_v1".hash()

	func _export_file(path: String, type: String, features: PackedStringArray) -> void:
		# Exclude all Team Create plugin files and persistent data from exported packages
		if path.begins_with("res://addons/team_create/") or path.begins_with("res://.team_create/") or path == "res://addons/team_create":
			skip()

	func _begin_customize_scenes(platform, features: PackedStringArray) -> bool:
		return true

	func _customize_scene(scene: Node, path: String) -> Node:
		var modified := _strip_team_create_from_node(scene)
		if modified:
			return scene
		return null

	func _strip_team_create_from_node(node: Node) -> bool:
		if not node:
			return false
		var changed := false

		# Strip Team Create metadata from this node
		for meta_name in node.get_meta_list():
			var meta_str := str(meta_name)
			if meta_str == "_tc_uuid" or meta_str == "team_create_outline_peer" or meta_str.begins_with("_tc_"):
				node.remove_meta(meta_name)
				changed = true

		# Clean children recursively
		var children := node.get_children()
		for child in children:
			var child_name := child.name
			# Remove any editor preview visual nodes if they accidentally got persisted
			if child_name.begins_with("TC_RemoteOutline_") or child_name.begins_with("RemoteCursor_") or child.has_meta("team_create_outline_peer"):
				node.remove_child(child)
				child.free()
				changed = true
				continue
			if _strip_team_create_from_node(child):
				changed = true

		return changed
