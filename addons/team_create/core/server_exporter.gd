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
	network.call_deferred("host_server")"""

const TSCN_TEMPLATE = """[gd_scene load_steps=2 format=3 uid="uid://teamcreateserver01"]

[ext_resource type="Script" path="res://addons/team_create/server.gd" id="1_1"]

[node name="Server" type="Node"]
script = ExtResource("1_1")
"""

const LINUX_SH_TEMPLATE = """#!/bin/bash
# Team Create Linux Headless Server
# This script launches the project in headless mode as a server.

cd "$(dirname "$0")"

# Check for updates
CFG_FILE="project/addons/team_create/plugin.cfg"
if [ -f "$CFG_FILE" ]; then
    echo "Checking for Godot Team Create updates..."
    LOCAL_VER=$(grep -i '^version=' "$CFG_FILE" | head -n1 | cut -d'=' -f2 | tr -d ' "\\r')
    REMOTE_CFG=""
    if command -v curl >/dev/null 2>&1; then
        REMOTE_CFG=$(curl -sL --max-time 5 "https://raw.githubusercontent.com/N3rmis/Godot-Team-Create/main/addons/team_create/plugin.cfg" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        REMOTE_CFG=$(wget -qO- --timeout=5 "https://raw.githubusercontent.com/N3rmis/Godot-Team-Create/main/addons/team_create/plugin.cfg" 2>/dev/null)
    fi
    REMOTE_VER=$(echo "$REMOTE_CFG" | grep -i '^version=' | head -n1 | cut -d'=' -f2 | tr -d ' "\\r')

    IS_NEWER=0
    if [ -n "$REMOTE_VER" ] && [ "$REMOTE_VER" != "$LOCAL_VER" ]; then
        HIGHEST=$(printf '%s\n%s\n' "$LOCAL_VER" "$REMOTE_VER" | sort -V 2>/dev/null | tail -n1)
        if [ "$HIGHEST" = "$REMOTE_VER" ]; then
            IS_NEWER=1
        fi
    fi

    if [ "$IS_NEWER" -eq 1 ]; then
        echo ""
        echo "==================================================="
        echo " A new version of Godot Team Create is available!"
        echo " Current version: $LOCAL_VER"
        echo " Latest version:  $REMOTE_VER"
        echo "==================================================="
        echo ""

        choice="n"
        if [ -t 0 ]; then
            if read -t 15 -r -p "Do you want to update? (y/n) [n]: " user_choice; then
                choice=$(echo "$user_choice" | tr '[:upper:]' '[:lower:]' | tr -d ' \\r\\t')
            fi
        else
            echo "Non-interactive session detected. Skipping auto-update prompt."
        fi

        if [ "$choice" = "y" ] || [ "$choice" = "yes" ]; then
            echo "Downloading update from GitHub..."
            TEMP_ZIP="/tmp/tc_update_$$.zip"
            if command -v curl >/dev/null 2>&1; then
                curl -sL "https://github.com/N3rmis/Godot-Team-Create/archive/refs/heads/main.zip" -o "$TEMP_ZIP"
            elif command -v wget >/dev/null 2>&1; then
                wget -qO "$TEMP_ZIP" "https://github.com/N3rmis/Godot-Team-Create/archive/refs/heads/main.zip"
            fi

            if [ -f "$TEMP_ZIP" ]; then
                if command -v unzip >/dev/null 2>&1; then
                    echo "Extracting updated files..."
                    EXTRACT_DIR="/tmp/tc_extract_$$"
                    mkdir -p "$EXTRACT_DIR"
                    unzip -q -o "$TEMP_ZIP" -d "$EXTRACT_DIR"
                    FOUND_DIR=$(find "$EXTRACT_DIR" -type d -name "team_create" | head -n1)
                    if [ -n "$FOUND_DIR" ] && [ -d "$FOUND_DIR" ]; then
                        cp -r "$FOUND_DIR"/* project/addons/team_create/
                        echo "Update applied successfully!"
                    else
                        echo "Error: Could not find team_create folder in downloaded archive."
                    fi
                    rm -rf "$EXTRACT_DIR" "$TEMP_ZIP"
                    echo ""
                elif command -v python3 >/dev/null 2>&1; then
                    echo "Extracting updated files..."
                    python3 -c "
import zipfile, os, shutil
with zipfile.ZipFile('$TEMP_ZIP', 'r') as z:
    for m in z.infolist():
        if 'addons/team_create/' in m.filename and not m.filename.endswith('/'):
            rel = m.filename.split('addons/team_create/', 1)[1]
            t = os.path.join('project/addons/team_create', rel)
            os.makedirs(os.path.dirname(t), exist_ok=True)
            with z.open(m) as s, open(t, 'wb') as d:
                shutil.copyfileobj(s, d)
"
                    rm -f "$TEMP_ZIP"
                    echo "Update applied successfully!"
                    echo ""
                else
                    echo "Error: Neither 'unzip' nor 'python3' found to extract the update."
                    rm -f "$TEMP_ZIP"
                    echo ""
                fi
            else
                echo "Error: Failed to download update file."
                echo ""
            fi
        else
            echo "Skipping update."
            echo ""
        fi
    elif [ -n "$REMOTE_VER" ]; then
        echo "Team Create is up to date (v$LOCAL_VER)."
    fi
fi

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

cd /d "%~dp0"

:: Check for new version before starting Godot
if exist "%~dp0check_updates.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_updates.ps1"
)

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

const CHECK_UPDATES_PS1_TEMPLATE = """# Team Create Headless Server Update Checker
$ErrorActionPreference = 'SilentlyContinue'

Write-Host "Checking for Godot Team Create updates..." -ForegroundColor Cyan

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$cfgPath = Join-Path $scriptDir "project\\addons\\team_create\\plugin.cfg"
$localVer = "Unknown"
if (Test-Path $cfgPath) {
    Get-Content $cfgPath | ForEach-Object {
        $trimmed = $_.Trim()
        if ($trimmed.StartsWith("version=")) {
            $localVer = $trimmed.Split("=")[1].Replace('"', '').Trim()
        }
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$remoteVer = ""
try {
    $wc = New-Object Net.WebClient
    $wc.Headers.Add("User-Agent", "Godot-Team-Create-Updater")
    $raw = $wc.DownloadString("https://raw.githubusercontent.com/N3rmis/Godot-Team-Create/main/addons/team_create/plugin.cfg")
    $raw -split "`r?`n" | ForEach-Object {
        $trimmed = $_.Trim()
        if ($trimmed.StartsWith("version=")) {
            $remoteVer = $trimmed.Split("=")[1].Replace('"', '').Trim()
        }
    }
} catch {
    Write-Host "Could not check for updates (offline or GitHub unreachable)." -ForegroundColor Yellow
}

function Compare-SemVer($v1, $v2) {
    try {
        $a = [System.Version]($v1 -replace '[^0-9\\.]','')
        $b = [System.Version]($v2 -replace '[^0-9\\.]','')
        return $a.CompareTo($b)
    } catch {
        return 0
    }
}

$isNewer = $false
if ($remoteVer -and ($remoteVer -ne $localVer)) {
    if ((Compare-SemVer $remoteVer $localVer) -gt 0) {
        $isNewer = $true
    }
}

if ($isNewer) {
    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host " A new version of Godot Team Create is available!" -ForegroundColor Green
    Write-Host " Current version: $localVer" -ForegroundColor White
    Write-Host " Latest version:  $remoteVer" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host ""

    $choice = ""
    while ($choice -ne "y" -and $choice -ne "yes" -and $choice -ne "n" -and $choice -ne "no") {
        $choice = (Read-Host "Do you want to update? (y/n)").Trim().ToLower()
        if ($choice -ne "y" -and $choice -ne "yes" -and $choice -ne "n" -and $choice -ne "no") {
            Write-Host "Please type 'y' (yes) or 'n' (no)." -ForegroundColor Yellow
        }
    }

    if ($choice -eq "y" -or $choice -eq "yes") {
        Write-Host "Downloading update from GitHub..." -ForegroundColor Yellow
        $tempZip = Join-Path $env:TEMP "tc_update_$(Get-Random).zip"
        try {
            $wc.DownloadFile("https://github.com/N3rmis/Godot-Team-Create/archive/refs/heads/main.zip", $tempZip)
            Write-Host "Extracting updated files..." -ForegroundColor Yellow
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $destDir = Join-Path $scriptDir "project\\addons\\team_create"
            $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
            $count = 0
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName.Contains("addons/team_create/")) {
                    $idx = $entry.FullName.IndexOf("addons/team_create/")
                    $rel = $entry.FullName.Substring($idx + "addons/team_create/".Length)
                    if ($rel -and -not $rel.EndsWith("/")) {
                        $target = Join-Path $destDir $rel
                        $dir = [System.IO.Path]::GetDirectoryName($target)
                        if (-not (Test-Path $dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                        $count++
                    }
                }
            }
            $zip.Dispose()
            Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
            Write-Host "Update applied successfully ($count files updated)!" -ForegroundColor Green
            Write-Host ""
        } catch {
            Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
        }
    } else {
        Write-Host "Skipping update." -ForegroundColor Yellow
        Write-Host ""
    }
} else {
    if ($remoteVer) {
        Write-Host "Team Create is up to date (v$localVer)." -ForegroundColor Green
    }
}
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

	var win_ps1 = FileAccess.open(target_dir + "/check_updates.ps1", FileAccess.WRITE)
	if win_ps1:
		win_ps1.store_string(CHECK_UPDATES_PS1_TEMPLATE)
		win_ps1.close()

	print("Export complete! Project bundled in: " + target_dir)
	print("Run the server using start_server.sh or start_server.bat!")

	caller_ui.export_btn.text = "Export Headless Server"
	caller_ui.export_btn.disabled = false


static func _abort_export(caller_ui: Control, message: String) -> void:
	printerr("Export Failed: ", message)
	caller_ui.show_error("Export Failed", message)
	caller_ui.export_btn.text = "Export Headless Server"
	caller_ui.export_btn.disabled = false
