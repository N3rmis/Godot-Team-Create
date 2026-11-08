extends Node

class DummyEditorSettings:
	func has_setting(name): return false
	func get_setting(name): return ""
	func set_setting(name, val): pass
	func add_property_info(info): pass
	func set_initial_value(name, value, update_current): pass
	func get_project_metadata(section, key, default): return default
	func set_project_metadata(section, key, val): pass

class DummyEditorFileSystem:
	signal filesystem_changed
	signal sources_changed
	func is_scanning(): return false
	func scan(): pass # No-op in headless
	func get_filesystem(): return self
	func scan_sources(): pass # No-op in headless
	func update_file(_path): pass # No-op in headless

class DummyEditorSelection:
	signal selection_changed
	func get_selected_nodes(): return []

class DummyEditorInterface:
	var settings = DummyEditorSettings.new()
	var efs = DummyEditorFileSystem.new()
	var dummy_root = Node.new()
	var dummy_selection = DummyEditorSelection.new()
	var dummy_base = Control.new()
	var dummy_main_screen = Node.new()

	func _init():
		dummy_root.name = "DummyRootScene"
		dummy_root.set_meta("scene_file_path", "res://addons/team_create/server.tscn")
		dummy_main_screen.name = "DummyMainScreen"

	func get_editor_settings(): return settings
	func get_resource_filesystem(): return efs
	func get_edited_scene_root(): return dummy_root
	func get_selection(): return dummy_selection
	func get_base_control(): return dummy_base
	func get_open_scenes(): return []

	func restart_editor():
		print("Closing standalone server...")
		var main_loop = Engine.get_main_loop()
		if main_loop and main_loop.has_method("quit"):
			main_loop.quit(0)

	func get_editor_main_screen():
		return dummy_main_screen
	func get_editor_viewport_3d(_idx=0): return null
	func open_scene_from_path(_path): pass # No-op in headless
	func close_scene(): return OK # No-op in headless
	func reload_scene_from_path(_path): pass # No-op in headless
	func save_scene(): pass # No-op in headless
	func mark_scene_as_unsaved(): pass # No-op in headless

class DummyEditorUndoRedoManager:
	signal version_changed
	signal history_changed
	func create_action(_name, _merge_mode=0, _custom_context=null, _backward_undo_ops=false, _mark_unsaved=true): pass # No-op in headless
	func add_do_property(_object, _property, _value): pass # No-op in headless
	func add_undo_property(_object, _property, _value): pass # No-op in headless
	func commit_action(_execute=true): pass # No-op in headless

class DummyEditorPlugin extends Node:
	var ei = DummyEditorInterface.new()
	var dummy_undo_redo = DummyEditorUndoRedoManager.new()
	func get_editor_interface(): return ei
	func get_undo_redo(): return dummy_undo_redo
	func add_control_to_dock(_slot, _control): pass # No-op in headless
	func remove_control_from_docks(_control): pass # No-op in headless
	func download_update():
		var tc_network = get_tree().root.get_node_or_null("TeamCreateNetwork")
		if tc_network and tc_network.has_method("download_update"):
			tc_network.download_update()

	func check_for_updates(): pass # No-op in headless


func _ready():
	print("Starting Godot Team Create Headless Server...")
	var network_script = load("res://addons/team_create/core/network.gd")
	if not network_script:
		print("Failed to load network.gd")
		get_tree().quit(1)
		return

	var network = network_script.new()
	network.name = "TeamCreateNetwork"
	network.is_standalone_server = true

	# Check command line user args (after '--')
	var user_args = OS.get_cmdline_user_args()
	for i in range(user_args.size()):
		if user_args[i] == "--port" and i + 1 < user_args.size() and user_args[i + 1].is_valid_int():
			network.PORT = user_args[i + 1].to_int()
			network.HTTP_PORT = network.PORT
		elif user_args[i] == "--host-token" and i + 1 < user_args.size():
			network.host_auth_token = user_args[i + 1]

	var dummy_plugin = DummyEditorPlugin.new()
	dummy_plugin.name = "DummyPlugin"
	add_child(dummy_plugin)

	network.plugin = dummy_plugin
	get_tree().root.call_deferred("add_child", network)

	# Since DummyEditorInterface.dummy_root needs to be in the tree for get_tree() calls
	get_tree().root.call_deferred("add_child", dummy_plugin.ei.dummy_root)

	print("Hosting server on port ", network.PORT)
	network.call_deferred("host_server")
