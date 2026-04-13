@tool
extends Node

const SERVER_SCRIPT_TEMPLATE = """extends Node

class DummyEditorSettings:
	func has_setting(name): return false
	func get_setting(name): return ""
	func set_setting(name, val): pass
	func get_project_metadata(section, key, default): return default
	func set_project_metadata(section, key, val): pass

class DummyEditorFileSystem:
	signal filesystem_changed
	signal sources_changed
	func is_scanning(): return false
	func scan(): pass
	func get_filesystem(): return self
	func scan_sources(): pass
	func update_file(path): pass

class DummyEditorSelection:
	signal selection_changed
	func get_selected_nodes(): return []

class DummyEditorInterface:
	var settings = DummyEditorSettings.new()
	var efs = DummyEditorFileSystem.new()
	var dummy_root = Node.new()
	var dummy_selection = DummyEditorSelection.new()
	var dummy_base = Control.new()

	func _init():
		dummy_root.name = "DummyRootScene"
		dummy_root.set_meta("scene_file_path", "res://addons/team_create/server.tscn")

	func get_editor_settings(): return settings
	func get_resource_filesystem(): return efs
	func get_edited_scene_root(): return dummy_root
	func get_selection(): return dummy_selection
	func get_base_control(): return dummy_base
	func get_open_scenes(): return []

	func get_editor_main_screen():
		var n = Node.new()
		n.name = "DummyMainScreen"
		return n
	func open_scene_from_path(path): pass
	func close_scene(): pass
	func reload_scene_from_path(path): pass
	func save_scene(): pass
	func mark_scene_as_unsaved(): pass

class DummyEditorUndoRedoManager:
	signal version_changed
	signal history_changed
	func create_action(name, merge_mode=0, custom_context=null, undo_custom_context=false): pass
	func add_do_property(object, property, value): pass
	func add_undo_property(object, property, value): pass
	func commit_action(execute=true): pass

class DummyEditorPlugin extends Node:
	var ei = DummyEditorInterface.new()
	var dummy_undo_redo = DummyEditorUndoRedoManager.new()
	func get_editor_interface(): return ei
	func get_undo_redo(): return dummy_undo_redo
	func add_control_to_dock(slot, control): pass
	func remove_control_from_docks(control): pass
	func download_update(): pass
	func check_for_updates(): pass


func _ready():
	print("Starting Godot Team Create Headless Server...")
	var network_script = load("res://addons/team_create/network.gd")
	if not network_script:
		print("Failed to load network.gd")
		get_tree().quit(1)
		return

	var network = network_script.new()
	network.name = "TeamCreateNetwork"
	network.is_standalone_server = true

	var dummy_plugin = DummyEditorPlugin.new()
	dummy_plugin.name = "DummyPlugin"
	add_child(dummy_plugin)

	network.plugin = dummy_plugin
	get_tree().root.call_deferred("add_child", network)

	# Since DummyEditorInterface.dummy_root needs to be in the tree for get_tree() calls
	get_tree().root.call_deferred("add_child", dummy_plugin.ei.dummy_root)

	print("Hosting server on port ", network.PORT)
	network.call_deferred("host_server")"""

const TSCN_TEMPLATE = """[gd_scene load_steps=2 format=3 uid="uid://teamcreateserver01"]

[ext_resource type="Script" path="res://addons/team_create/server.gd" id="1_1"]

[node name="Server" type="Node"]
script = ExtResource("1_1")
"""

const LINUX_SH_TEMPLATE = """#!/bin/bash
# Team Create Linux Headless Server
# This script launches the project in headless mode as a server.

GODOT_EXEC="godot"

for f in ./Godot_v4*linux*.x86_64 ./Godot_v4*.x86_64; do
    if [ -f "$f" ]; then
        GODOT_EXEC="$f"
        break
    fi
done

echo "Starting Team Create Server..."
"$GODOT_EXEC" --path project --headless
"""

const WINDOWS_BAT_TEMPLATE = """@echo off
:: Team Create Windows Headless Server
:: This script launches the project in headless mode as a server.

set "GODOT_EXEC=godot.exe"

for %%f in (Godot_v4*.exe) do (
    if exist "%%f" (
        set "GODOT_EXEC=%%f"
        goto found
    )
)
:found

echo Starting Team Create Server...
"%GODOT_EXEC%" --path project --headless
pause
"""

# TODO: Return boolean success/failure to abort export if file copy fails midway (e.g. permission denied)
static func copy_dir_recursive(from_path: String, to_path: String, ignore_paths: Array = []) -> void:
	if not DirAccess.dir_exists_absolute(from_path):
		return
	if not DirAccess.dir_exists_absolute(to_path):
		DirAccess.make_dir_recursive_absolute(to_path)

	var dir = DirAccess.open(from_path)
	if dir:
		dir.include_hidden = true
		dir.include_navigational = false
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			var src_path = from_path.path_join(file_name)
			var dest_path = to_path.path_join(file_name)

			var should_ignore = false
			var global_src = ProjectSettings.globalize_path(src_path)
			var global_dest = ProjectSettings.globalize_path(dest_path)

			for ig in ignore_paths:
				var global_ig = ProjectSettings.globalize_path(ig)
				if global_src.begins_with(global_ig) or global_dest.begins_with(global_ig):
					should_ignore = true
					break

			if not should_ignore:
				if dir.current_is_dir():
					copy_dir_recursive(src_path, dest_path, ignore_paths)
				else:
					var f_in = FileAccess.open(src_path, FileAccess.READ)
					var f_out = FileAccess.open(dest_path, FileAccess.WRITE)
					if f_in and f_out:
						f_out.store_buffer(f_in.get_buffer(f_in.get_length()))
						f_in.close()
						f_out.close()
			file_name = dir.get_next()
		dir.list_dir_end()

static func export_server(target_dir: String, caller_ui: Control) -> void:
	target_dir = ProjectSettings.globalize_path(target_dir)
	print("Exporting Standalone Server to: ", target_dir)
	caller_ui.export_btn.text = "Exporting Server..."
	caller_ui.export_btn.disabled = true

	# To avoid risking the user's project files during export and to ensure we don't infinitely recurse,
	# we copy the current res:// project into a temporary safe directory inside user://
	var temp_project_dir = OS.get_user_data_dir() + "/team_create_temp_export_project"

	print("Cloning project to temporary directory...")

	if DirAccess.dir_exists_absolute(temp_project_dir):
		# Just do a quick pseudo-clean of obvious files
		var d = DirAccess.open(temp_project_dir)
		if d:
			d.list_dir_begin()
			var fn = d.get_next()
			while fn != "":
				if fn != "." and fn != "..":
					if not d.current_is_dir():
						d.remove(fn)
				fn = d.get_next()

	# Provide ignore paths: we don't want to copy the huge .godot folder, nor the target export dir if it's inside res://
	var ignore_paths = ["res://.godot", "res://.git", target_dir]
	copy_dir_recursive("res://", temp_project_dir, ignore_paths)

	# Write server specific files into the temp project
	if not DirAccess.dir_exists_absolute(temp_project_dir + "/addons/team_create"):
		DirAccess.make_dir_recursive_absolute(temp_project_dir + "/addons/team_create")

	var script_file = FileAccess.open(temp_project_dir + "/addons/team_create/server.gd", FileAccess.WRITE)
	if script_file:
		script_file.store_string(SERVER_SCRIPT_TEMPLATE)
		script_file.close()

	var tscn_file = FileAccess.open(temp_project_dir + "/addons/team_create/server.tscn", FileAccess.WRITE)
	if tscn_file:
		tscn_file.store_string(TSCN_TEMPLATE)
		tscn_file.close()

	var proj_path = temp_project_dir + "/project.godot"
	var preset_path = temp_project_dir + "/export_presets.cfg"

	# Modify Project file to include our feature tag main scene override
	var f_proj_append = FileAccess.open(proj_path, FileAccess.READ_WRITE)
	if f_proj_append:
		f_proj_append.seek_end()
		f_proj_append.store_string("\n[application]\nrun/main_scene.teamcreateserver=\"res://addons/team_create/server.tscn\"\n")
		f_proj_append.close()

	# User prefers raw project directory rather than a hidden PCK.
	# 1. ALWAYS clone temp_project_dir to target_dir/project
	print("Bundling project directory...")
	var target_project_dir = target_dir + "/project"
	copy_dir_recursive(temp_project_dir, target_project_dir, [temp_project_dir + "/export_presets.cfg"])

	# Patch target project.godot to make server.tscn the default main scene directly
	var t_proj = FileAccess.open(target_project_dir + "/project.godot", FileAccess.READ_WRITE)
	if t_proj:
		t_proj.seek_end()
		t_proj.store_string("\n[application]\nrun/main_scene=\"res://addons/team_create/server.tscn\"\n")
		t_proj.close()

	# 2. ALWAYS generate script wrappers
	var linux_sh = FileAccess.open(target_dir + "/start_server.sh", FileAccess.WRITE)
	if linux_sh:
		linux_sh.store_string(LINUX_SH_TEMPLATE)
		linux_sh.close()

	var win_bat = FileAccess.open(target_dir + "/start_server.bat", FileAccess.WRITE)
	if win_bat:
		win_bat.store_string(WINDOWS_BAT_TEMPLATE)
		win_bat.close()

	print("Export complete! Project bundled in: " + target_dir)
	print("Run the server using start_server.sh or start_server.bat!")

	caller_ui.export_btn.text = "Export Headless Server"
	caller_ui.export_btn.disabled = false
