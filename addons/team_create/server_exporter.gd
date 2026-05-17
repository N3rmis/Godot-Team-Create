@tool
extends Node

const SERVER_SCRIPT_TEMPLATE = """extends Node

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

	func _init():
		dummy_root.name = "DummyRootScene"
		dummy_root.set_meta("scene_file_path", "res://addons/team_create/server.tscn")

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
		var n = Node.new()
		n.name = "DummyMainScreen"
		return n
	func open_scene_from_path(_path): pass # No-op in headless
	func close_scene(): pass # No-op in headless
	func reload_scene_from_path(_path): pass # No-op in headless
	func save_scene(): pass # No-op in headless
	func mark_scene_as_unsaved(): pass # No-op in headless

class DummyEditorUndoRedoManager:
	signal version_changed
	signal history_changed
	func create_action(_name, _merge_mode=0, _custom_context=null, _undo_custom_context=false): pass # No-op in headless
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
	var downloading = false

	func download_update():
		if downloading:
			return
		downloading = true
		print_rich("[color=yellow]Downloading update from GitHub...[/color]")

		var http_request = HTTPRequest.new()
		add_child(http_request)
		http_request.request_completed.connect(self._download_request_completed.bind(http_request))
		http_request.download_file = "user://team_create_update.zip"
		var headers = ["User-Agent: Godot-Team-Create-Plugin"]
		var error = http_request.request("https://github.com/N3rmis/Godot-Team-Create/archive/refs/heads/main.zip", headers)
		if error != OK:
			print_rich("[color=red]An error occurred starting the HTTP download request.[/color]")
			downloading = false

	func _download_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest) -> void:
		if result == HTTPRequest.RESULT_SUCCESS and (response_code == 200 or response_code == 301 or response_code == 302):
			_extract_and_apply_update("user://team_create_update.zip")
		else:
			print_rich("[color=red]Failed to download update. Response code: " + str(response_code) + "[/color]")
			downloading = false

		http_request.queue_free()

	func _extract_and_apply_update(zip_path: String) -> void:
		var zip_reader = ZIPReader.new()
		var err = zip_reader.open(zip_path)
		if err != OK:
			print_rich("[color=red]Failed to open update zip.[/color]")
			DirAccess.remove_absolute(zip_path)
			downloading = false
			return

		print_rich("[color=yellow]Extracting update...[/color]")
		var files = zip_reader.get_files()
		for f in files:
			if f.ends_with("/"):
				continue # Directory

			# Normalize path separators
			var f_norm = f.replace("\\\\", "/")

			# Ensure it's inside the addons/team_create folder
			var parts = f_norm.split("/")
			if parts.size() > 2 and parts[1] == "addons" and parts[2] == "team_create":
				var dest_path = ("res://" + "/".join(parts.slice(1, parts.size()))).simplify_path()

				# Validate path to prevent ZipSlip traversal and absolute path escapes
				if not dest_path.begins_with("res://addons/team_create/"):
					printerr("Security Warning: Traversal attempt detected in update zip: ", f)
					continue

				var global_dest = ProjectSettings.globalize_path(dest_path)

				# Ensure directory exists
				var dest_dir = global_dest.get_base_dir()
				if not DirAccess.dir_exists_absolute(dest_dir):
					DirAccess.make_dir_recursive_absolute(dest_dir)

				var content = zip_reader.read_file(f)
				DirAccess.remove_absolute(global_dest)
				var out_file = FileAccess.open(global_dest, FileAccess.WRITE)
				if out_file:
					out_file.store_buffer(content)
					out_file.close()
				else:
					print_rich("[color=red]Failed to write updated file: " + dest_path + "[/color]")

		zip_reader.close()
		DirAccess.remove_absolute(zip_path)
		print_rich("[color=green]Update applied successfully! Restarting server...[/color]")
		var tc_network = get_tree().root.get_node_or_null("TeamCreateNetwork")
		if tc_network and tc_network.has_method("_deferred_restart"):
			tc_network.call_deferred("_deferred_restart")
		else:
			get_editor_interface().restart_editor()

	func check_for_updates(): pass # No-op in headless


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

for f in ./*linux*.x86_64 ./*linux*.x86_32 ./Godot_v4*.x86_64 ./godot*; do
    if [ -f "$f" ] && [ -x "$f" ]; then
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

set "GODOT_EXEC=godot.console.exe"

:: First try to find the Godot console wrapper, required for stdin input on Windows
for %%f in (*console*.exe) do (
    if exist "%%f" (
        set "GODOT_EXEC=%%f"
        goto found
    )
)

:: Fallback to standard executable
for %%f in (*godot*.exe) do (
    if exist "%%f" (
        set "GODOT_EXEC=%%f"
        goto found_standard
    )
)
for %%f in (Godot*.exe) do (
    if exist "%%f" (
        set "GODOT_EXEC=%%f"
        goto found_standard
    )
)
goto found

:found_standard
echo WARNING: Standard Godot executable found instead of the console wrapper!
echo You will not be able to type commands into the server console.
echo Please place the Godot console executable (e.g. godot.console.exe) in this folder.
echo.

:found
echo Starting Team Create Server...
"%GODOT_EXEC%" --path project --headless
pause
"""

static func copy_dir_recursive(from_path: String, to_path: String, ignore_paths: Array = []) -> bool:
	if not DirAccess.dir_exists_absolute(from_path):
		return false
	if not DirAccess.dir_exists_absolute(to_path):
		var err = DirAccess.make_dir_recursive_absolute(to_path)
		if err != OK:
			return false

	var dir = DirAccess.open(from_path)
	if dir:
		dir.include_hidden = true
		dir.include_navigational = false
		var err = dir.list_dir_begin()
		if err != OK:
			return false

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
					if not copy_dir_recursive(src_path, dest_path, ignore_paths):
						return false
				else:
					var f_in = FileAccess.open(src_path, FileAccess.READ)
					if not f_in:
						return false
					var f_out = FileAccess.open(dest_path, FileAccess.WRITE)
					if not f_out:
						f_in.close()
						return false
					f_out.store_buffer(f_in.get_buffer(f_in.get_length()))
					f_in.close()
					f_out.close()
			file_name = dir.get_next()
		dir.list_dir_end()
		return true
	else:
		return false

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
	if not copy_dir_recursive("res://", temp_project_dir, ignore_paths):
		_abort_export(caller_ui, "Failed to clone project to temporary directory.")
		return

	# Write server specific files into the temp project
	if not DirAccess.dir_exists_absolute(temp_project_dir + "/addons/team_create"):
		var err = DirAccess.make_dir_recursive_absolute(temp_project_dir + "/addons/team_create")
		if err != OK:
			_abort_export(caller_ui, "Failed to create addons directory in temp project.")
			return

	var script_file = FileAccess.open(temp_project_dir + "/addons/team_create/server.gd", FileAccess.WRITE)
	if script_file:
		script_file.store_string(SERVER_SCRIPT_TEMPLATE)
		script_file.close()
	else:
		_abort_export(caller_ui, "Failed to write server.gd to temp project.")
		return

	var tscn_file = FileAccess.open(temp_project_dir + "/addons/team_create/server.tscn", FileAccess.WRITE)
	if tscn_file:
		tscn_file.store_string(TSCN_TEMPLATE)
		tscn_file.close()
	else:
		_abort_export(caller_ui, "Failed to write server.tscn to temp project.")
		return

	var proj_path = temp_project_dir + "/project.godot"

	# Modify Project file to include our feature tag main scene override
	var f_proj_append = FileAccess.open(proj_path, FileAccess.READ_WRITE)
	if f_proj_append:
		f_proj_append.seek_end()
		f_proj_append.store_string("\n[application]\nrun/main_scene.teamcreateserver=\"res://addons/team_create/server.tscn\"\n")
		f_proj_append.close()
	else:
		_abort_export(caller_ui, "Failed to modify project.godot in temp project.")
		return

	# User prefers raw project directory rather than a hidden PCK.
	# 1. ALWAYS clone temp_project_dir to target_dir/project
	print("Bundling project directory...")
	var target_project_dir = target_dir + "/project"
	if not copy_dir_recursive(temp_project_dir, target_project_dir, []):
		_abort_export(caller_ui, "Failed to bundle project directory to target location.")
		return

	# Patch target project.godot to make server.tscn the default main scene directly
	var t_proj = FileAccess.open(target_project_dir + "/project.godot", FileAccess.READ_WRITE)
	if t_proj:
		t_proj.seek_end()
		t_proj.store_string("\n[application]\nrun/main_scene=\"res://addons/team_create/server.tscn\"\n")
		t_proj.close()
	else:
		_abort_export(caller_ui, "Failed to patch project.godot in target location.")
		return

	# 2. ALWAYS generate script wrappers
	var linux_sh_path = target_dir + "/start_server.sh"
	var linux_sh = FileAccess.open(linux_sh_path, FileAccess.WRITE)
	if linux_sh:
		linux_sh.store_string(LINUX_SH_TEMPLATE)
		linux_sh.close()
		# Only run chmod if the host OS is Unix-like and supports chmod
		if OS.has_feature("linux") or OS.has_feature("macos") or OS.has_feature("bsd") or OS.has_feature("x11"):
			var global_sh_path = ProjectSettings.globalize_path(linux_sh_path)
			var output = []
			OS.execute("chmod", ["+x", global_sh_path], output)
	else:
		_abort_export(caller_ui, "Failed to write start_server.sh.")
		return

	var win_bat = FileAccess.open(target_dir + "/start_server.bat", FileAccess.WRITE)
	if win_bat:
		win_bat.store_string(WINDOWS_BAT_TEMPLATE)
		win_bat.close()
	else:
		_abort_export(caller_ui, "Failed to write start_server.bat.")
		return

	print("Export complete! Project bundled in: " + target_dir)
	print("Run the server using start_server.sh or start_server.bat!")

	caller_ui.export_btn.text = "Export Headless Server"
	caller_ui.export_btn.disabled = false


static func _abort_export(caller_ui: Control, message: String) -> void:
	printerr("Export Failed: ", message)
	caller_ui.show_error("Export Failed", message)
	caller_ui.export_btn.text = "Export Headless Server"
	caller_ui.export_btn.disabled = false
