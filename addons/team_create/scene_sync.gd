@tool
extends Node

var _file_write_mutex = Mutex.new()
# TODO: Evaluate replacing manual dictionary serialization with Godot's built-in MultiplayerSynchronizer

var network: Node
var _last_scene_path: String = ""
var _last_tracked_properties = {}
var _last_selected_ids = []
var _time_since_sync = 0.0

var _server_tracked_scenes = {}
var _server_dummy_scenes = {}
var _server_save_timer = 0.0
var _failed_scene_loads = {}
const FAILED_LOAD_COOLDOWN = 2.0
var _failed_load_timers = {}
var _broken_script_notices = {}
var _last_broken_scripts_stamp = 0


func _safe_load_headless(path: String) -> Dictionary:
	if not network.get("is_standalone_server"):
		var packed = load(path)
		if packed and packed is PackedScene:
			return {"packed": packed, "is_dummy": false}
		return {"packed": null, "is_dummy": false}



	var file = FileAccess.open(path, FileAccess.READ)
	if not file: return {"packed": null, "is_dummy": false}
	var text = file.get_as_text()
	file.close()

	var is_modified = false
	var regex2 = RegEx.new()
	regex2.compile("\\[ext_resource.*?\\]")
	var matches = regex2.search_all(text)

	var path_regex = RegEx.new()
	path_regex.compile("path=\"(res://[^\"]+)\"")

	var type_regex = RegEx.new()
	type_regex.compile("type=\"([^\"]+)\"")

	for m in matches:
		var full_match = m.get_string()

		var type = ""
		var type_match = type_regex.search(full_match)
		if type_match:
			type = type_match.get_string(1)

		var orig_path = ""
		var path_match = path_regex.search(full_match)
		if path_match:
			orig_path = path_match.get_string(1)

		if orig_path == "":
			continue
		var test_res_exists = ResourceLoader.exists(orig_path)
		if test_res_exists:
			var import_path = orig_path + ".import"
			if FileAccess.file_exists(import_path):
				var config = ConfigFile.new()
				var err = config.load(import_path)
				if err == OK:
					var dest_files = config.get_value("deps", "dest_files", [])
					for dest_file in dest_files:
						if not FileAccess.file_exists(dest_file):
							test_res_exists = false
							break
		if not test_res_exists:
			var dummy_path = network._get_or_create_dummy_resource(orig_path, type)

			var new_block = full_match.replace('path="' + orig_path + '"', 'path="' + dummy_path + '"')
			var uid_regex = RegEx.new()
			uid_regex.compile('uid="uid://.*?"\\s*')
			var uid_match = uid_regex.search(new_block)
			if uid_match:
				new_block = new_block.replace(uid_match.get_string(), "")

			text = text.replace(full_match, new_block)
			is_modified = true

	if is_modified:
		var scene_regex = RegEx.new()
		scene_regex.compile("\\[gd_scene.*?(uid=\"uid://.*?\").*?\\]")
		var scene_match = scene_regex.search(text)
		if scene_match:
			text = text.replace(scene_match.get_string(1), "")

	var temp_path = "user://tc_headless_load_" + str(Time.get_ticks_msec()) + "_" + str(randi() % 10000) + ".tscn"
	var temp_file = FileAccess.open(temp_path, FileAccess.WRITE)
	if temp_file:
		temp_file.store_string(text)
		temp_file.close()
		var temp_packed = load(temp_path)
		DirAccess.remove_absolute(temp_path)
		if temp_packed:
			temp_packed.take_over_path(path)
		return {"packed": temp_packed, "is_dummy": true}

	return {"packed": null, "is_dummy": false}

# Opened the way the editor opens scenes, so saving keeps sub-scene links instead of flattening them.
# Never added to the tree: game code must not run on the server, or its runtime state gets saved into the scene.
func _instantiate_server_scene(packed: PackedScene) -> Node:
	return packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)

func _instantiate_subscene(packed: PackedScene) -> Node:
	if network and network.get("is_standalone_server"):
		return packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	return packed.instantiate()

# A script that doesn't compile falls off its node when the scene is saved, taking its exported values with it.
func _find_broken_script(path: String, seen: Dictionary = {}) -> String:
	for dep in ResourceLoader.get_dependencies(path):
		var dep_path = dep.get_slice("::", dep.get_slice_count("::") - 1)
		if seen.has(dep_path) or not ResourceLoader.exists(dep_path):
			continue
		seen[dep_path] = true
		var ext = dep_path.get_extension()
		if ext == "gd":
			var script = load(dep_path)
			if not (script is Script and script.can_instantiate()):
				return dep_path
		elif ext in ["tscn", "scn", "tres", "res"]:
			var broken = _find_broken_script(dep_path, seen)
			if broken != "":
				return broken
	return ""

# Godot keeps serving the failed compile from its cache, so a fixed script needs recompiling by hand.
# A script only compiles once the scripts it uses do, so this repeats for as long as it's making progress.
func _recompile_broken_scripts() -> void:
	var broken = []
	var stamp = 0
	for file_path in network.file_sync.get_all_files("res://"):
		if file_path.get_extension() != "gd" or file_path.begins_with("res://addons/team_create"):
			continue
		var script = load(file_path)
		if script is GDScript and not script.can_instantiate():
			broken.append(script)
			stamp = hash([stamp, file_path, FileAccess.get_modified_time(file_path)])
	if stamp == _last_broken_scripts_stamp:
		return
	_last_broken_scripts_stamp = stamp
	for _attempt in broken.size():
		var progressed = false
		for script in broken.duplicate():
			script.source_code = FileAccess.get_file_as_string(script.resource_path)
			if script.reload() == OK and script.can_instantiate():
				broken.erase(script)
				progressed = true
		if not progressed:
			break

func _is_scene_blocked_by_script(path: String) -> bool:
	var broken = _find_broken_script(path)
	if broken != "":
		_recompile_broken_scripts()
		broken = _find_broken_script(path)
	if broken == "":
		_broken_script_notices.erase(path)
		return false
	if _broken_script_notices.get(path, "") != broken:
		_broken_script_notices[path] = broken
		network.post_server_message(path.get_file() + " can't be loaded or saved on the server until " + broken.get_file() + " compiles. Its edits aren't being kept until then.")
	return true

func _load_server_scene(path: String) -> Dictionary:
	if _is_scene_blocked_by_script(path):
		return {"packed": null, "is_dummy": false}
	return _safe_load_headless(path)

func _get_editor_interface():
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		return Engine.get_singleton("EditorInterface")
	if network and network.plugin and network.plugin.has_method("get_editor_interface"):
		return network.plugin.get_editor_interface()
	return null

func _get_connected_peers() -> PackedInt32Array:
	if network and network.is_inside_tree() and network.is_connected_to_session() and network.multiplayer and network.multiplayer.has_multiplayer_peer():
		return network.multiplayer.get_peers()
	return PackedInt32Array()

func _get_edited_scene_root() -> Node:
	var ei = _get_editor_interface()
	if ei:
		return ei.get_edited_scene_root()
	return null

func _get_target_scene(scene_path: String) -> Node:
	if network and network.get("is_standalone_server"):
		if scene_path == "" or not network.file_sync.is_safe_scene_path(scene_path):
			return null

		if _server_tracked_scenes.has(scene_path):
			var s = _server_tracked_scenes[scene_path]
			if is_instance_valid(s):
				return s
			else:
				_server_tracked_scenes.erase(scene_path)

		if _failed_scene_loads.has(scene_path):
			return null

		if ResourceLoader.exists(scene_path):
			var result = _load_server_scene(scene_path)
			var packed = result.packed
			if packed and packed is PackedScene:
				var instance = _instantiate_server_scene(packed)
				if instance:
					_check_server_copy_is_complete(scene_path, instance)
					instance.set_meta("scene_file_path", scene_path)
					_server_tracked_scenes[scene_path] = instance
					if result.is_dummy:
						_server_dummy_scenes[scene_path] = true
					else:
						_server_dummy_scenes.erase(scene_path)
					_index_scene_subresources(instance, scene_path)
					return instance

			_failed_scene_loads[scene_path] = true
			_failed_load_timers[scene_path] = FAILED_LOAD_COOLDOWN
			printerr("Team Create: Failed to load scene or its dependencies (cooldown applied): ", scene_path)
		return null
	else:
		if scene_path == "":
			return _get_edited_scene_root()

		var ei = _get_editor_interface()
		if ei and ei.has_method("get_open_scene_roots"):
			var open_roots = ei.get_open_scene_roots()
			for root in open_roots:
				if is_instance_valid(root):
					var path = root.scene_file_path
					if path == "":
						path = root.get_meta("scene_file_path", "")
					if path == scene_path:
						return root

		var active = _get_edited_scene_root()
		if active and is_instance_valid(active):
			var active_path = active.scene_file_path
			if active_path == "":
				active_path = active.get_meta("scene_file_path", "")
			if active_path == scene_path:
				return active

		return null

# The server can't always load all of a scene. A sub-scene using a texture that was never imported here just goes
# missing from the tree with no error to catch, and saving that tree would delete it from the file. So it's saved to
# a scratch file first, and if anything didn't survive, writing the real file is left to the editors.
func _check_server_copy_is_complete(path: String, instance: Node):
	_incomplete_server_scenes.erase(path)
	if not path.ends_with(".tscn"):
		return
	var packed = PackedScene.new()
	if packed.pack(instance) != OK:
		_incomplete_server_scenes[path] = true
		return
	var temp_path = "user://tc_complete_check_%d_%d.tscn" % [Time.get_ticks_msec(), randi() % 10000]
	if ResourceSaver.save(packed, temp_path) != OK:
		_incomplete_server_scenes[path] = true
		return
	network._restore_dummy_paths_in_file(temp_path)
	var saved = _scene_outline(temp_path)
	DirAccess.remove_absolute(temp_path)
	for item in _scene_outline(path):
		if not saved.has(item):
			_incomplete_server_scenes[path] = true
			network.tc_print("The server couldn't load all of " + path + " (" + item + "), so it will only keep the copies editors save")
			return

func _scene_outline(path: String) -> Dictionary:
	var regex = RegEx.new()
	regex.compile('(?m)^\\[node name="([^"]*)"(?:[^\\n]*? parent="([^"]*)")?|^\\[ext_resource [^\\n]*?path="([^"]*)"')
	var outline = {}
	for m in regex.search_all(FileAccess.get_file_as_string(path)):
		outline[m.get_string(3) if m.get_string(3) != "" else m.get_string(2) + "/" + m.get_string(1)] = true
	return outline

func _save_server_tracked_scenes():
	if not network or not network.get("is_standalone_server"):
		return

	var cached_outlines = []
	var cached_cursors = []
	if is_inside_tree() and get_tree():
		var tree = get_tree()
		cached_outlines = tree.get_nodes_in_group("TeamCreateSelectionOutlines")
		cached_cursors = tree.get_nodes_in_group("TeamCreateCursors")

	for path in _server_tracked_scenes:
		var scene_node = _server_tracked_scenes[path]
		if is_instance_valid(scene_node):
			if _is_scene_blocked_by_script(path) or _incomplete_server_scenes.has(path):
				continue

			# Temporarily remove outlines
			var outlines = []
			for node in cached_outlines:
				if is_instance_valid(node) and scene_node.is_ancestor_of(node):
					outlines.append({"node": node, "parent": node.get_parent()})
			for node in cached_cursors:
				if is_instance_valid(node) and scene_node.is_ancestor_of(node):
					outlines.append({"node": node, "parent": node.get_parent()})

			for data in outlines:
				data["parent"].remove_child(data["node"])

			# Server bookkeeping, not part of the scene
			scene_node.remove_meta("scene_file_path")
			finish_remote_moves()
			var packed = PackedScene.new()
			var pack_err = packed.pack(scene_node)
			scene_node.set_meta("scene_file_path", path)
			if pack_err == OK:
				var saved_uids = _read_scene_uids(path)
				if ResourceSaver.save(packed, path) == OK:
					network._restore_dummy_paths_in_file(path)
					_restore_scene_uids(path, saved_uids)
					if network and network.file_sync:
						network.file_sync._file_hash_cache.erase(path)
					if network.auto_save_prints_enabled:
						network.tc_print("Server automatically saved tracked scene: ", path)
				_index_scene_subresources(scene_node, path)

			for data in outlines:
				if is_instance_valid(data["parent"]) and is_instance_valid(data["node"]):
					data["parent"].add_child(data["node"])

func _read_scene_uids(path: String) -> Dictionary:
	var uids = {"scene": "", "ext": {}}
	var text = FileAccess.get_file_as_string(path)
	var uid_regex = RegEx.create_from_string('uid="(uid://[^"]+)"')
	var header_uid = uid_regex.search(text.substr(0, text.find("\n")))
	if header_uid:
		uids["scene"] = header_uid.get_string(1)
	var path_regex = RegEx.create_from_string('path="([^"]+)"')
	for m in RegEx.create_from_string("\\[ext_resource [^\\]]*\\]").search_all(text):
		var ext_uid = uid_regex.search(m.get_string())
		var ext_path = path_regex.search(m.get_string())
		if ext_uid and ext_path:
			uids["ext"][ext_path.get_string(1)] = ext_uid.get_string(1)
	return uids

# Godot only writes UIDs when the editor is running. Without them, references to this scene go stale.
func _restore_scene_uids(path: String, uids: Dictionary) -> void:
	var lines = FileAccess.get_file_as_string(path).split("\n")
	if uids["scene"] != "" and not lines[0].contains("uid=") and lines[0].ends_with("]"):
		lines[0] = lines[0].trim_suffix("]") + ' uid="' + uids["scene"] + '"]'
	var path_regex = RegEx.create_from_string(' path="([^"]+)"')
	for i in lines.size():
		if not lines[i].begins_with("[ext_resource ") or lines[i].contains("uid="):
			continue
		var m = path_regex.search(lines[i])
		if m and uids["ext"].has(m.get_string(1)):
			lines[i] = lines[i].replace(m.get_string(), ' uid="' + uids["ext"][m.get_string(1)] + '"' + m.get_string())
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string("\n".join(lines))
		file.close()

var _synced_scene_states: Dictionary = {}
var _dirty_scenes: Dictionary = {}
var _dirty_save_cooldown: float = 0.0
const SAVE_INSTRUCTION_DELAY: float = 0.5
const GROUPS_KEY = "__groups__"
const ANIMATION_KEY = "__animation__:"
var _saving_without_instruction = false
var _pending_instruction_saves: Dictionary = {}
var _relay_after_save = false
var _incomplete_server_scenes: Dictionary = {}
var _file_only_states: Dictionary = {} # scene path -> node id -> value fingerprints, as of the last save
const DIRTY_SAVE_DELAY: float = 5.0
var _is_applying_remote_update: bool = false
var _active_node_locks: Dictionary = {}

func mark_scene_dirty(scene_path: String):
	if scene_path == "":
		return
	_dirty_scenes[scene_path] = true
	_dirty_save_cooldown = DIRTY_SAVE_DELAY
	if network and network.scene_check:
		network.scene_check.note_change(scene_path)
	if not network or not network.get("is_standalone_server"):
		var ei = _get_editor_interface()
		var current_scene = _get_edited_scene_root()
		# This marks the current tab, so it would mislabel a change to a scene in another tab
		if ei and ei.has_method("mark_scene_as_unsaved") and current_scene and current_scene.scene_file_path == scene_path:
			ei.mark_scene_as_unsaved()

# Stops a remote change being sent back. A node with no entry gets a complete one on its next check, since a
# partial entry would make that check resend every other property. Entries only describe the current scene.
func _remember_remote_property(target_scene: Node, id: String, prop_name: String, value: Variant):
	if target_scene == _get_edited_scene_root() and _last_tracked_properties.has(id):
		_last_tracked_properties[id][prop_name] = value

# Tabs close without asking because the scene is gone for everyone. The trash folder has the last saved copy.
func forget_deleted_scene(path: String):
	if not (path.ends_with(".tscn") or path.ends_with(".scn")):
		return
	_dirty_scenes.erase(path)
	_pending_instruction_saves.erase(path)
	_incomplete_server_scenes.erase(path)
	_file_only_states.erase(path)
	if network and network.get("is_standalone_server"):
		var s = _server_tracked_scenes.get(path)
		if is_instance_valid(s):
			s.queue_free()
		_server_tracked_scenes.erase(path)
		_server_dummy_scenes.erase(path)
		return
	var ei = _get_editor_interface()
	if not ei or not path in ei.get_open_scenes():
		return
	var current_scene = _get_edited_scene_root()
	var prev_path = current_scene.scene_file_path if current_scene else ""
	ei.open_scene_from_path(path)
	ei.close_scene()
	if prev_path != "" and prev_path != path:
		ei.open_scene_from_path(prev_path)
		_defer_restore_camera(prev_path)
	network.show_toast("Scene deleted, so its tab was closed: " + path.get_file(), 1)

func save_dirty_scenes():
	if network and network.get("is_standalone_server"):
		_save_server_tracked_scenes()
	elif network and network.is_server:
		var ei = _get_editor_interface()
		if ei:
			_saving_without_instruction = true
			if ei.has_method("save_all_scenes"):
				ei.save_all_scenes()
			elif ei.has_method("save_scene"):
				ei.save_scene()
			_saving_without_instruction = false
	_dirty_scenes.clear()
	_dirty_save_cooldown = DIRTY_SAVE_DELAY
	if _relay_after_save:
		_relay_after_save = false
		if network and network.file_sync:
			network.file_sync._has_unrelayed_files = true
			network.file_sync._schedule_relay_sync()

func flush_all_scenes_to_disk():
	if network and network.get("is_standalone_server"):
		_save_server_tracked_scenes()
		_dirty_scenes.clear()
	else:
		var ei = _get_editor_interface()
		if ei:
			_saving_without_instruction = true
			if ei.has_method("save_all_scenes"):
				ei.save_all_scenes()
			elif ei.has_method("save_scene"):
				ei.save_scene()
			_saving_without_instruction = false
		_dirty_scenes.clear()

# Saving tells everyone to save their own copy instead of sending the file. Everyone's copy has the same live
# edits, and replacing one with a file that was saved a moment ago throws away whatever arrived since.
func on_local_scene_saved(path: String):
	if not is_inside_tree():
		return # Saving on the way out, when the editor closes
	if not _is_reloading_scene:
		_track_changes_throttled() # Anything changed since the last check has to get there before the instruction
	_send_file_only_changes(path)
	if _saving_without_instruction:
		return
	if network.is_server:
		rpc("receive_save_instruction", path)
		_relay_after_save = true
		_dirty_scenes[path] = true
		_dirty_save_cooldown = minf(_dirty_save_cooldown, SAVE_INSTRUCTION_DELAY)
	else:
		rpc_id(1, "receive_save_instruction", path)

@rpc("any_peer", "reliable")
func receive_save_instruction(path: String):
	var sender_id = multiplayer.get_remote_sender_id()
	if not network or not network.file_sync or not network.file_sync.is_safe_scene_path(path):
		return
	if network.is_server:
		if not network.peers.has(sender_id):
			return
		for peer_id in _get_connected_peers():
			if peer_id != sender_id:
				rpc_id(peer_id, "receive_save_instruction", path)
		var is_standalone = network.get("is_standalone_server")
		if not _get_target_scene(path) or _incomplete_server_scenes.has(path) or (is_standalone and _is_scene_blocked_by_script(path)):
			rpc_id(sender_id, "request_saved_scene", path)
			return
		# Brief, so a burst of saves is one write. Closed copies elsewhere update once it's done.
		_relay_after_save = true
		_dirty_scenes[path] = true
		_dirty_save_cooldown = minf(_dirty_save_cooldown, SAVE_INSTRUCTION_DELAY)
		if is_standalone:
			return
	elif sender_id != 1:
		return
	_pending_instruction_saves[path] = true
	_run_instruction_saves.call_deferred()

func _run_instruction_saves():
	if _pending_instruction_saves.is_empty():
		return
	if _is_reloading_scene:
		get_tree().create_timer(0.6).timeout.connect(_run_instruction_saves)
		return
	var ei = _get_editor_interface()
	if ei:
		var open_scenes = ei.get_open_scenes()
		var current = ei.get_edited_scene_root()
		var save_current = false
		var save_others = false
		for path in _pending_instruction_saves:
			if path in open_scenes:
				if current and current.scene_file_path == path:
					save_current = true
				else:
					save_others = true
		_saving_without_instruction = true
		# Only the current tab can be saved by itself
		if save_others:
			ei.save_all_scenes()
		elif save_current:
			ei.save_scene()
		_saving_without_instruction = false
	_pending_instruction_saves.clear()

@rpc("authority", "reliable")
func request_saved_scene(path: String):
	if network.file_sync.is_safe_scene_path(path) and FileAccess.file_exists(path):
		network.rpc_id(1, "receive_manual_save", path, FileAccess.get_file_as_bytes(path))

# Some of a scene never goes through live sync: properties only kept in the file, such as a TileMapLayer's cells,
# plus metadata. Saving looks for changes to these and passes on just those values, using the saved file as the
# way to carry them, so nobody's other work is replaced.
func _scene_groups(node: Node) -> Array:
	var groups = []
	for group in node.get_groups():
		var group_name = str(group)
		if not group_name.begins_with("_") and not group_name.begins_with("TeamCreate"):
			groups.append(group_name)
	groups.sort()
	return groups

func _read_file_only_state(node: Node) -> Dictionary:
	var state = {}
	for p in node.get_property_list():
		if not p.usage & PROPERTY_USAGE_STORAGE or p.name == "script":
			continue
		if p.name.begins_with("metadata/"):
			var meta_name = p.name.trim_prefix("metadata/")
			if meta_name == "_tc_uuid" or meta_name == "scene_file_path" or meta_name.begins_with("team_create"):
				continue
		elif _is_synced_node_property(node, p) or (node is Control and (p.name == "position" or p.name == "size")) or (node is AnimationMixer and p.name.begins_with("libraries/")):
			continue
		# With the objects included, so an edit inside a resource counts as a change
		state[p.name] = hash(var_to_bytes_with_objects(node.get(p.name)))
	return state

func _read_file_only_states(node: Node, scene_root: Node = null, states: Dictionary = {}) -> Dictionary:
	if scene_root == null:
		scene_root = node
	if node == scene_root or node.owner == scene_root:
		states[network.assign_unique_id(node)] = _read_file_only_state(node)
	for child in node.get_children():
		_read_file_only_states(child, scene_root, states)
	return states

func _send_file_only_changes(path: String):
	var scene_root = _get_target_scene(path)
	if not scene_root or not _file_only_states.has(path) or not FileAccess.file_exists(path):
		return
	var known = _file_only_states[path]
	var current = _read_file_only_states(scene_root, null, {})
	_file_only_states[path] = current

	var defaults = {}
	var changes = []
	for id in current:
		var before = known.get(id, null)
		if before == null:
			# New here. Whatever it has that a fresh node wouldn't hasn't been passed on yet.
			var node_class = network.get_node_by_unique_id(scene_root, id).get_class()
			if not defaults.has(node_class):
				defaults[node_class] = {}
				if ClassDB.can_instantiate(node_class) and ClassDB.is_parent_class(node_class, "Node"):
					var fresh = ClassDB.instantiate(node_class)
					defaults[node_class] = _read_file_only_state(fresh)
					fresh.free()
			before = defaults[node_class]
		for key in current[id]:
			if current[id][key] != before.get(key, null):
				changes.append([id, key])
		for key in before:
			if not current[id].has(key):
				changes.append([id, key])
	if changes.is_empty():
		return
	var bytes = FileAccess.get_file_as_bytes(path)
	if network.is_server:
		rpc("receive_file_only_changes", path, changes, bytes)
	else:
		rpc_id(1, "receive_file_only_changes", path, changes, bytes)

# A separate instance of a saved scene, to copy things out of. Freeing it is up to the caller.
func _instantiate_scene_bytes(path: String, bytes: PackedByteArray) -> Node:
	if bytes.is_empty():
		return null
	var temp_path = "user://tc_file_only_%d_%d.%s" % [Time.get_ticks_msec(), randi() % 10000, path.get_extension()]
	var file = FileAccess.open(temp_path, FileAccess.WRITE)
	if not file:
		return null
	file.store_buffer(bytes)
	file.close()
	var packed = _safe_load_headless(temp_path).packed
	DirAccess.remove_absolute(temp_path)
	if not packed:
		return null
	return _instantiate_server_scene(packed) if network.get("is_standalone_server") else packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)

@rpc("any_peer", "reliable")
func receive_file_only_changes(path: String, changes: Array, bytes: PackedByteArray):
	var sender_id = multiplayer.get_remote_sender_id()
	if not network or not network.file_sync or not network.file_sync.is_safe_scene_path(path):
		return
	if network.is_server:
		if not network.peers.has(sender_id):
			return
		for peer_id in _get_connected_peers():
			if peer_id != sender_id:
				rpc_id(peer_id, "receive_file_only_changes", path, changes, bytes)
	elif sender_id != 1:
		return

	var scene_root = _get_target_scene(path)
	if not scene_root:
		return
	var source_root = _instantiate_scene_bytes(path, bytes)
	if not source_root:
		return

	for change in changes:
		if not change is Array or change.size() != 2 or not change[0] is String or not change[1] is String or change[1] == "script":
			continue
		var node = network.get_node_by_unique_id(scene_root, change[0])
		var source = network.get_node_by_unique_id(source_root, change[0])
		if not node or not source:
			continue
		if change[1].begins_with("metadata/") and not source.has_meta(change[1].trim_prefix("metadata/")):
			node.remove_meta(change[1].trim_prefix("metadata/"))
		else:
			node.set(change[1], source.get(change[1]))
		# So the next save here doesn't report this as its own change
		var states = _file_only_states.get(path, {})
		if states.has(change[0]):
			var fresh = _read_file_only_state(node)
			if fresh.has(change[1]):
				states[change[0]][change[1]] = fresh[change[1]]
			else:
				states[change[0]].erase(change[1])
	source_root.free()
	mark_scene_dirty(path)

@rpc("any_peer", "reliable")
func request_node_lock(node_id: String, scene_path: String = ""):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 1
	if not (network and network.is_server):
		return
	if not _active_node_locks.has(node_id) or _active_node_locks[node_id] == 0 or _active_node_locks[node_id] == sender_id:
		_active_node_locks[node_id] = sender_id
		rpc("grant_node_lock", node_id, sender_id, scene_path)
		grant_node_lock(node_id, sender_id, scene_path)
	else:
		rpc_id(sender_id, "deny_node_lock", node_id, _active_node_locks[node_id])

@rpc("any_peer", "reliable")
func release_node_lock(node_id: String, scene_path: String = ""):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 1
	if not (network and network.is_server):
		return
	if _active_node_locks.get(node_id, 0) == sender_id or sender_id == 1:
		_active_node_locks.erase(node_id)
		rpc("grant_node_lock", node_id, 0, scene_path)
		grant_node_lock(node_id, 0, scene_path)

@rpc("any_peer", "reliable")
func grant_node_lock(node_id: String, holder_id: int, scene_path: String = ""):
	if holder_id == 0:
		_active_node_locks.erase(node_id)
	else:
		_active_node_locks[node_id] = holder_id

@rpc("any_peer", "reliable")
func deny_node_lock(node_id: String, holder_id: int):
	var holder_name = "User " + str(holder_id)
	if network and network.peers.has(holder_id):
		holder_name = network.peers[holder_id].get("username", holder_name)
	if network:
		network.tc_print("Team Create: Node is currently locked by ", holder_name)
		if network.has_method("show_toast"):
			network.show_toast("Node is locked by %s" % holder_name, 1)

func release_all_locks_for_peer(peer_id: int):
	var to_release = []
	for node_id in _active_node_locks:
		if _active_node_locks[node_id] == peer_id:
			to_release.append(node_id)
	for node_id in to_release:
		_active_node_locks.erase(node_id)
		rpc("grant_node_lock", node_id, 0, "")

const FAST_SYNC_INTERVAL = 0.1 # Normal sync rate (10 Hz) for <= 10 nodes
const SLOW_SYNC_INTERVAL = 1.0 # Throttled sync rate (1 Hz) for > 10 nodes
const LARGE_SELECTION_THRESHOLD = 10 # Selection count threshold to trigger adaptive throttling
const MAX_PROPERTY_CHECKS_PER_FRAME = 12 # Process at most 12 nodes per frame for lag-free property diffing
const MAX_LOCK_NODES = 25 # Max node locks to request to avoid flooding RPC buffers
const MAX_OUTLINE_NODES = 50 # Max visual selection outlines to create in viewport

var _pending_selection_nodes: Array = []
var _pending_selection_index: int = 0

# Per-User, Per-Scene Camera Persistence (never saved into .tscn files)
const CAMERA_CACHE_FILE = "user://tc_saved_cameras.json"
var _user_scene_cameras: Dictionary = {}
var _camera_save_timer: float = 0.0
const CAMERA_SAVE_INTERVAL: float = 1.0
var _is_camera_dirty: bool = false
var _is_switching_scene_tab: bool = false
var _tab_switch_cooldown: float = 0.0

# Shared Sub-Resource Tracking (ensures duplicated nodes sharing meshes/materials remain shared across peers and server saves)
var _resource_to_subres_id: Dictionary = {}
var _subres_id_to_resource: Dictionary = {}
var _dirty_subresources: Dictionary = {}
var _resource_prints: Dictionary = {} # resource instance id -> how it looked when last compared
var _comparing_resources = false
var _resources_to_reload: Array = []
var _pending_animations: Array = []

# Tracking structure changes locally so we don't bounce events back and forth
var _ignore_next_structure_event = false
var _is_adding_outline = false
var _is_reloading_scene = false:
	set(value):
		_is_reloading_scene = value
		if value:
			_file_only_states.clear() # What was remembered describes the scene being replaced
var _pre_removal_paths = {}
var _removed_this_frame = {}
var _removed_frame = -1
var _node_names = {}
var _force_full_sync_next_frame = false
var _pending_resource_properties = []
var _pending_subscene_instantiations: Array[Dictionary] = []
var _pending_node_properties: Array[Dictionary] = []
var _receiving_scenes: Dictionary = {}
var _receiving_scene_states: Dictionary = {}
var _receiving_properties: Dictionary = {}
var _is_forwarding_chunked_property: bool = false

func _ready():
	_load_camera_cache()
	var tree = Engine.get_main_loop() as SceneTree
	if tree:
		tree.node_added.connect(_on_node_added)
		tree.node_removed.connect(_on_node_removed)
		tree.node_renamed.connect(_on_node_renamed)

		# Hook into tree signals to capture state before the change applies
		var root = tree.root
		if root:
			# Also connect existing nodes
			_connect_tree_exiting_recursive(root)

	call_deferred("_setup_undo_redo")
	call_deferred("_setup_file_sync_signals")

func _setup_file_sync_signals():
	if network and network.file_sync:
		if network.file_sync.has_signal("asset_imported") and not network.file_sync.asset_imported.is_connected(_on_asset_imported):
			network.file_sync.asset_imported.connect(_on_asset_imported)
	var ei = _get_editor_interface()
	if ei and ei.get_resource_filesystem():
		var efs = ei.get_resource_filesystem()
		if efs.has_signal("resources_reimported") and not efs.resources_reimported.is_connected(_on_resources_reimported):
			efs.resources_reimported.connect(_on_resources_reimported)
		if efs.has_signal("filesystem_changed") and not efs.filesystem_changed.is_connected(_on_filesystem_changed_scene_sync):
			efs.filesystem_changed.connect(_on_filesystem_changed_scene_sync)

func _on_resources_reimported(resources: PackedStringArray):
	_process_pending_subscene_instantiations()
	_process_pending_resource_properties()
	_process_pending_node_properties()

func _on_filesystem_changed_scene_sync():
	_process_pending_subscene_instantiations()
	_process_pending_resource_properties()
	_process_pending_node_properties()

func _on_asset_imported(path: String):
	if not network.get("is_standalone_server") and path.get_extension() in ["tres", "res", "material"]:
		_resources_to_reload.append(path)
	_process_pending_subscene_instantiations()
	_process_pending_resource_properties()
	_process_pending_node_properties()

func _setup_undo_redo():
	var undo_redo = null
	var ei = _get_editor_interface()
	if ei and ei.has_method("get_editor_undo_redo"):
		undo_redo = ei.get_editor_undo_redo()
	elif network and network.plugin and network.plugin.has_method("get_undo_redo"):
		undo_redo = network.plugin.get_undo_redo()

	if undo_redo:
		if not undo_redo.version_changed.is_connected(_on_undo_redo_version_changed):
			undo_redo.version_changed.connect(_on_undo_redo_version_changed)
		if not undo_redo.history_changed.is_connected(_on_undo_redo_version_changed):
			undo_redo.history_changed.connect(_on_undo_redo_version_changed)

func _on_undo_redo_version_changed():
	# Trigger a full check of modified nodes on the next sync interval
	# Useful for drag-and-drop actions that aren't on actively selected nodes
	_force_full_sync_next_frame = true

func _connect_tree_exiting_recursive(node: Node):
	if not node.tree_exiting.is_connected(_on_node_tree_exiting.bind(node)):
		node.tree_exiting.connect(_on_node_tree_exiting.bind(node))

	_node_names[node.get_instance_id()] = node.name

	for child in node.get_children():
		_connect_tree_exiting_recursive(child)

func _on_node_tree_exiting(node: Node):
	if _is_reloading_scene:
		return

	var edited_scene = _get_edited_scene_root()
	if not edited_scene:
		return

	if node == edited_scene:
		return

	# Godot's own helper children have no owner. They aren't part of the scene, so their removal isn't an edit.
	if not node.owner:
		return

	var current_scene = _get_target_scene("")
	if current_scene != edited_scene:
		return

	if network and network.is_connected_to_session() and not _get_connected_peers().is_empty():
		var scene_path = ""
		if node.owner and node.owner.scene_file_path != "":
			scene_path = node.owner.scene_file_path
		elif node.scene_file_path != "":
			scene_path = node.scene_file_path
		elif current_scene:
			scene_path = current_scene.scene_file_path

		var root_node = node.owner if node.owner else edited_scene

		var parent = node.get_parent()
		_pre_removal_paths[node.get_instance_id()] = {"id": network.assign_unique_id(node), "scene_path": scene_path, "root_node": root_node, "parent_inst": parent.get_instance_id() if parent else 0}

func _process(delta):
	var expired = []
	for path in _failed_load_timers.keys():
		_failed_load_timers[path] -= delta
		if _failed_load_timers[path] <= 0:
			expired.append(path)
	for path in expired:
		_failed_load_timers.erase(path)
		_failed_scene_loads.erase(path)

	if network and network.get("is_standalone_server"):
		_server_save_timer += delta
		if _server_save_timer >= 60.0:
			_server_save_timer = 0.0
			_save_server_tracked_scenes()

	if _dirty_scenes.size() > 0:
		_dirty_save_cooldown -= delta
		if _dirty_save_cooldown <= 0.0:
			save_dirty_scenes()

	_process_pending_subscene_instantiations()
	_process_pending_resource_properties()
	_process_pending_node_properties()
	_process_pending_resource_reloads()
	_process_pending_animations()

	# Periodic camera cache flush to disk (runs online and offline)
	if _is_camera_dirty:
		_camera_save_timer += delta
		if _camera_save_timer >= CAMERA_SAVE_INTERVAL:
			_camera_save_timer = 0.0
			_save_camera_cache()

	# Always track scene tab switches first, then sync local camera
	_track_active_scene()
	_sync_cursor_throttled(delta)
	var cursors_gliding = _smooth_peer_cursors(delta)
	_smooth_remote_moves(delta)
	_update_glide_frame_rate(cursors_gliding or not _remote_moves.is_empty() or Time.get_ticks_msec() < _frame_rate_hold_until)

	if not network or not network.plugin or not network.is_connected_to_session():
		if not _pending_selection_nodes.is_empty():
			_pending_selection_nodes.clear()
			_pending_selection_index = 0
		return

	# Incrementally process any batched selection checks across frames to eliminate frame drops
	_process_batched_selection_checks()

	_time_since_sync += delta
	var active_interval = _get_active_sync_interval()
	if _time_since_sync >= active_interval:
		_time_since_sync = 0.0
		_track_selection()
		_track_changes_throttled()

func _get_active_sync_interval() -> float:
	var ei = _get_editor_interface()
	if ei:
		var selected = ei.get_selection().get_selected_nodes()
		if selected.size() > LARGE_SELECTION_THRESHOLD:
			return SLOW_SYNC_INTERVAL
	return FAST_SYNC_INTERVAL

func _process_batched_selection_checks():
	if _pending_selection_nodes.is_empty():
		return

	var checked_count = 0
	while _pending_selection_index < _pending_selection_nodes.size() and checked_count < MAX_PROPERTY_CHECKS_PER_FRAME:
		var node = _pending_selection_nodes[_pending_selection_index]
		_pending_selection_index += 1
		checked_count += 1
		if is_instance_valid(node) and node.is_inside_tree():
			_check_single_node_changes(node)

	if _pending_selection_index >= _pending_selection_nodes.size():
		_pending_selection_nodes.clear()
		_pending_selection_index = 0

func _process_pending_resource_properties():
	if _pending_resource_properties.is_empty():
		return

	var is_scanning = false
	var ei = _get_editor_interface()
	if ei and ei.get_resource_filesystem():
		is_scanning = ei.get_resource_filesystem().is_scanning()

	var ext_resource_regex = RegEx.new()
	ext_resource_regex.compile("ext_resource.*path=\"(res://[^\"]+)\"")

	for i in range(_pending_resource_properties.size() - 1, -1, -1):
		var pending = _pending_resource_properties[i]

		var is_ready = false
		var should_continue = false
		if typeof(pending.value) == TYPE_STRING and (pending.value as String).begins_with("res://"):
			if is_scanning:
				should_continue = true
			elif network and network.file_sync and pending.value in network.file_sync.downloading_files:
				should_continue = true
			elif _safe_resource_exists(pending.value):
				is_ready = true
		elif typeof(pending.value) == TYPE_DICTIONARY and pending.value.has("sub_resource_bytes"):
			is_ready = true
			if is_scanning:
				should_continue = true
				is_ready = false
			else:
				var text = pending.value.get("sub_resource_text", "")
				if text != "":
					for m in ext_resource_regex.search_all(text):
						var ext_path = m.get_string(1)
						if network and network.file_sync and ext_path in network.file_sync.downloading_files:
							should_continue = true
							is_ready = false
							break
						if not _safe_resource_exists(ext_path):
							is_ready = false
							break

		if should_continue:
			continue

		if is_ready:
			var current_scene = _get_target_scene(pending.scene_path)
			if current_scene and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) == pending.scene_path:
				var node = network.get_node_by_unique_id(current_scene, pending.id)
				if is_instance_valid(node):
					_is_applying_remote_update = true
					if typeof(pending.value) == TYPE_STRING and (pending.value as String).begins_with("res://"):
						var res = load(pending.value)
						if res:
							node.set(pending.prop_name, res)
					elif typeof(pending.value) == TYPE_DICTIONARY and pending.value.has("sub_resource_bytes"):
						var subres_id = pending.value.get("sub_resource_id", "")
						var existing_res = _get_cached_subresource(subres_id, pending.scene_path) if subres_id != "" else null
						var applied_res: Resource = null
						if existing_res:
							var updated = _update_existing_subresource(existing_res, pending.value)
							if updated:
								if node.get(pending.prop_name) != existing_res:
									node.set(pending.prop_name, existing_res)
								applied_res = existing_res
							else:
								var res = _import_sub_resource(pending.value)
								if res:
									if subres_id != "":
										_register_subresource(res, subres_id, pending.scene_path)
									node.set(pending.prop_name, res)
									applied_res = res
						else:
							var res = _import_sub_resource(pending.value)
							if res:
								if subres_id != "":
									_register_subresource(res, subres_id, pending.scene_path)
								node.set(pending.prop_name, res)
								applied_res = res
						_is_applying_remote_update = false
						mark_scene_dirty(pending.scene_path)

						_dirty_subresources.erase(pending.id + ":" + pending.prop_name)
						var stored_dict = pending.value.duplicate()
						if applied_res:
							_resource_prints[applied_res.get_instance_id()] = _resource_print(applied_res)
							stored_dict["resource_instance_id"] = applied_res.get_instance_id()
							_register_subresource_listener(applied_res, pending.id, pending.prop_name)
						_remember_remote_property(current_scene, pending.id, pending.prop_name, stored_dict)
					else:
						_is_applying_remote_update = false
						mark_scene_dirty(pending.scene_path)
			_pending_resource_properties.remove_at(i)
		else:
			if Time.get_ticks_msec() > pending.timeout:
				_pending_resource_properties.remove_at(i)

func _process_pending_subscene_instantiations():
	if _pending_subscene_instantiations.is_empty():
		return

	var now = Time.get_ticks_msec()
	for i in range(_pending_subscene_instantiations.size() - 1, -1, -1):
		var pending = _pending_subscene_instantiations[i]
		var scene_path = pending.scene_path
		var current_scene = _get_target_scene(scene_path)
		if not current_scene:
			if now > pending.timeout:
				_pending_subscene_instantiations.remove_at(i)
			continue

		var parent = network.get_node_by_unique_id(current_scene, pending.parent_id)
		if not is_instance_valid(parent):
			if now > pending.timeout:
				_pending_subscene_instantiations.remove_at(i)
			continue

		if parent.has_node(pending.new_name) or network._find_node_by_uuid(current_scene, pending.new_id):
			_pending_subscene_instantiations.remove_at(i)
			continue

		var node_scene_path = pending.node_scene_path
		var is_downloading = network and network.file_sync and node_scene_path in network.file_sync.downloading_files
		var file_exists = FileAccess.file_exists(node_scene_path)

		var scn: PackedScene = null
		if file_exists and not is_downloading:
			var res = _safe_load_headless(node_scene_path)
			scn = res.get("packed", null)

		var new_node: Node = null
		if scn:
			new_node = _instantiate_subscene(scn)
		elif now > pending.timeout:
			if ClassDB.can_instantiate(pending.type):
				new_node = ClassDB.instantiate(pending.type)
			else:
				new_node = Node.new()

		if new_node:
			_ignore_next_structure_event = true
			new_node.name = pending.new_name
			new_node.set_meta("_tc_uuid", pending.new_id)
			_node_names[new_node.get_instance_id()] = pending.new_name
			parent.add_child(new_node)
			if parent.owner and parent.owner != current_scene and parent.scene_file_path == "":
				new_node.owner = parent.owner
			else:
				new_node.owner = current_scene
			mark_scene_dirty(scene_path)
			_ignore_next_structure_event = false

			_pending_subscene_instantiations.remove_at(i)
			_process_pending_node_properties()

func _process_pending_node_properties():
	if _pending_node_properties.is_empty():
		return

	var now = Time.get_ticks_msec()
	for i in range(_pending_node_properties.size() - 1, -1, -1):
		var pending = _pending_node_properties[i]
		var current_scene = _get_target_scene(pending.scene_path)
		if not current_scene:
			if now > pending.timeout:
				_pending_node_properties.remove_at(i)
			continue

		var node = network.get_node_by_unique_id(current_scene, pending.id)
		if is_instance_valid(node):
			var prop_id = pending.id
			var prop_name = pending.prop_name
			var prop_val = pending.value
			var scn_path = pending.scene_path
			_pending_node_properties.remove_at(i)
			update_node_property(prop_id, prop_name, prop_val, scn_path)
		elif now > pending.timeout:
			_pending_node_properties.remove_at(i)

func _track_active_scene():
	if _is_reloading_scene:
		return

	var current_scene = _get_edited_scene_root()
	if not current_scene or not is_instance_valid(current_scene):
		var editor = _get_editor_interface()
		var open_scenes = editor.get_open_scenes() if editor else PackedStringArray()
		if open_scenes.is_empty() and _last_scene_path != "":
			save_current_camera_for_scene(_last_scene_path, true)
			_save_camera_cache()
			_last_scene_path = ""
			_local_3d_cursor_pos = Transform3D()
		return

	var cur_path = current_scene.scene_file_path
	if cur_path == "":
		return

	if not _file_only_states.has(cur_path):
		_file_only_states[cur_path] = _read_file_only_states(current_scene)

	# Not tied to a scene change, because reopening the last open scene doesn't count as one
	if _pending_offline_merges.has(cur_path) and not _offline_merges_scheduled.has(cur_path) and not _is_reloading_scene and network and network.is_connected_to_session() and not network.is_server:
		_offline_merges_scheduled[cur_path] = true
		get_tree().create_timer(0.5).timeout.connect(func():
			_offline_merges_scheduled.erase(cur_path)
			apply_offline_merge_deferred(cur_path)
		)

	if cur_path != _last_scene_path:
		if _last_scene_path != "":
			save_current_camera_for_scene(_last_scene_path, true)
			_save_camera_cache()

		_last_scene_path = cur_path
		# Node IDs are paths, and the root is "." in every scene, so remembered values can't carry over.
		# Remember this scene's values straight away so later changes to unselected nodes are still seen.
		finish_remote_moves()
		_last_tracked_properties.clear()
		_force_full_sync_next_frame = true
		_dirty_subresources.clear()
		_resource_prints.clear()
		_pending_selection_nodes.clear()
		_pending_selection_index = 0
		_node_names[current_scene.get_instance_id()] = current_scene.name

		# Tab switch protection: block cursor movement from overwriting cameras during transition
		_is_switching_scene_tab = true
		_tab_switch_cooldown = 0.5
		_local_3d_cursor_pos = Transform3D()

		_index_scene_subresources(current_scene)
		_defer_restore_camera(cur_path)
		if network and network.is_connected_to_session() and not network.is_server:
			if multiplayer and multiplayer.get_unique_id() != 1:
				network.report_current_scene(cur_path, _user_scene_cameras.get(cur_path, {}))
				if not _synced_scene_states.has(cur_path):
					_synced_scene_states[cur_path] = true
					rpc_id(1, "request_scene_state", cur_path)

func _track_changes_throttled():
	if _is_reloading_scene:
		return
	var current_scene = _get_edited_scene_root()
	if not current_scene:
		return

	_track_active_scene()

	if _force_full_sync_next_frame:
		_force_full_sync_next_frame = false
		_comparing_resources = true
		_check_all_nodes(current_scene, current_scene)
		_comparing_resources = false
	else:
		# ONLY track changes for selected nodes to save massive performance costs
		var ei = _get_editor_interface()
		if ei:
			var selected = ei.get_selection().get_selected_nodes()
			if selected.size() <= LARGE_SELECTION_THRESHOLD:
				# Fast path: 10 or fewer nodes. Process all immediately in this tick.
				_pending_selection_nodes.clear()
				_pending_selection_index = 0
				for node in selected:
					_check_single_node_changes(node)
			else:
				# Large selection: queue nodes and slice checks across frames to eliminate lag spikes
				_pending_selection_nodes = selected
				_pending_selection_index = 0
				_process_batched_selection_checks()

func _check_all_nodes(node: Node, scene_root: Node):
	if node.owner == scene_root or node == scene_root:
		_check_single_node_changes(node)
	for child in node.get_children():
		_check_all_nodes(child, scene_root)

func _register_subresource_listener(val: Resource, id: String, prop_name: String):
	if not is_instance_valid(val):
		return
	if not val.is_connected("changed", _on_resource_changed.bind(id, prop_name, val)):
		val.connect("changed", _on_resource_changed.bind(id, prop_name, val))

func _are_properties_equal(val_a, val_b) -> bool:
	if typeof(val_a) != typeof(val_b):
		return false
	if typeof(val_a) == TYPE_DICTIONARY:
		if val_a.has("sub_resource_bytes") and val_b.has("sub_resource_bytes"):
			var bytes_a: PackedByteArray = val_a["sub_resource_bytes"]
			var bytes_b: PackedByteArray = val_b["sub_resource_bytes"]
			if bytes_a.is_empty() != bytes_b.is_empty():
				return false
			if not bytes_a.is_empty():
				return bytes_a == bytes_b
			return val_a.get("sub_resource_id") == val_b.get("sub_resource_id") and val_a.get("resource_instance_id") == val_b.get("resource_instance_id")
	return val_a == val_b

# A Control's position and size are worked out from its parent's size, which isn't the same everywhere and
# doesn't exist on the server. Its anchors and offsets are what the scene stores, so those are what get synced.
func _is_synced_node_property(node: Node, property: Dictionary) -> bool:
	if node is Control:
		if property.name == "position" or property.name == "size":
			return false
		if (property.name.begins_with("anchor_") or property.name.begins_with("offset_")) and property.usage & PROPERTY_USAGE_STORAGE:
			return true
	return property.usage & PROPERTY_USAGE_EDITOR or property.name == "transform" or property.name == "name" or property.name == "unique_name_in_owner"

func _check_single_node_changes(node: Node):
	if _is_applying_remote_update or _remote_moves.has(node):
		return
	var id = network.assign_unique_id(node)
	var my_id = multiplayer.get_unique_id() if (network and network.is_connected_to_session()) else 1
	if _active_node_locks.has(id) and _active_node_locks[id] != my_id:
		# The animation panel needs its player selected, which shouldn't stop others working on its other animations
		if node is AnimationMixer and _last_tracked_properties.has(id):
			var animations = {}
			_track_animations(node, id, animations, _last_scene_path, false)
			_send_tracked_changes(id, animations)
		return

	var props = node.get_property_list()
	var current_props = {}
	# Ahead of the properties, since those can name an animation
	if node is AnimationMixer:
		_track_animations(node, id, current_props, _last_scene_path, false)
	current_props[GROUPS_KEY] = _scene_groups(node)
	for p in props:
		# Filter for export or essential properties
		if _is_synced_node_property(node, p):
			if p.name.begins_with("metadata/"):
				continue
			var val = node.get(p.name)
			if typeof(val) == TYPE_OBJECT:
				# For resources like Mesh or Material, sync the resource path if possible
				if val == null:
					# Kept so that filling or emptying the slot counts as a change
					if p.hint == PROPERTY_HINT_RESOURCE_TYPE:
						current_props[p.name] = null
				elif val is Resource:
					if not _is_built_in_subresource(val):
						var r_path = val.resource_path
						if network and network.get("_dummy_path_to_original") and network._dummy_path_to_original.has(r_path):
							r_path = network._dummy_path_to_original[r_path]
						current_props[p.name] = r_path
					else:
						current_props[p.name] = _tracked_built_in_value(val, id, p.name)
			else:
				current_props[p.name] = val

	var connections = []
	var signals = node.get_signal_list()
	for sig in signals:
		var conns = node.get_signal_connection_list(sig.name)
		for c in conns:
			if c.flags & CONNECT_PERSIST:
				var target_obj = c.callable.get_object()
				if target_obj is Node:
					var target_id = network.assign_unique_id(target_obj)
					connections.append({
						"signal": sig.name,
						"target_id": target_id,
						"method": c.callable.get_method(),
						"flags": c.flags,
						"unbinds": c.callable.get_unbound_arguments_count() if c.callable.get_unbound_arguments_count() > 0 else 0,
						"binds": c.callable.get_bound_arguments()
					})
	current_props["__connections__"] = connections

	if not _last_tracked_properties.has(id):
		_last_tracked_properties[id] = current_props
	else:
		_send_tracked_changes(id, current_props)

func _send_tracked_changes(id: String, current_props: Dictionary):
	var last_props = _last_tracked_properties[id]
	for prop_name in current_props:
		if not last_props.has(prop_name) or typeof(last_props[prop_name]) != typeof(current_props[prop_name]) or not _are_properties_equal(last_props[prop_name], current_props[prop_name]):
			_send_update_node_property(id, prop_name, current_props[prop_name], _last_scene_path)
			last_props[prop_name] = current_props[prop_name]
	for prop_name in last_props.keys():
		if prop_name.begins_with(ANIMATION_KEY) and not current_props.has(prop_name):
			_send_update_node_property(id, prop_name, null, _last_scene_path)
			last_props.erase(prop_name)

# What to remember for a built-in resource, with its contents only once they've changed
func _tracked_built_in_value(val: Resource, id: String, prop_name: String) -> Variant:
	if not _last_tracked_properties.has(id):
		_register_subresource_listener(val, id, prop_name)
		_resource_prints[val.get_instance_id()] = _resource_print(val)
		return {
			"resource_instance_id": val.get_instance_id(),
			"sub_resource_id": _get_or_create_subresource_id(val, _last_scene_path),
			"sub_resource_bytes": PackedByteArray()
		}
	var dirty_key = id + ":" + prop_name
	var force_res_update = false
	var last_val = _last_tracked_properties[id].get(prop_name)
	var last_inst_id = last_val.get("resource_instance_id", 0) if typeof(last_val) == TYPE_DICTIONARY else 0
	if last_inst_id != val.get_instance_id():
		force_res_update = true
	elif _dirty_subresources.has(dirty_key):
		_dirty_subresources.erase(dirty_key)
		force_res_update = true
	elif _comparing_resources and _resource_print_changed(val):
		force_res_update = true

	_register_subresource_listener(val, id, prop_name)

	if not force_res_update:
		return last_val
	_resource_prints[val.get_instance_id()] = _resource_print(val)
	var new_dict = export_sub_resource_dict(val, _last_scene_path)
	var last_bytes = last_val.get("sub_resource_bytes", PackedByteArray()) if typeof(last_val) == TYPE_DICTIONARY else PackedByteArray()
	if not last_bytes.is_empty() and last_bytes == new_dict.get("sub_resource_bytes", PackedByteArray()):
		return last_val
	return new_dict

func _track_selection():
	if _is_reloading_scene:
		return
	var editor = _get_editor_interface()
	if not editor:
		return
	var selection = editor.get_selection().get_selected_nodes()
	var selected_ids = []
	for node in selection:
		var id = network.assign_unique_id(node)
		selected_ids.append(id)

	if selected_ids != _last_selected_ids:
		var deselected = []
		for id in _last_selected_ids:
			if not selected_ids.has(id):
				deselected.append(id)
		for id in deselected:
			if _active_node_locks.has(id):
				if network and network.is_connected_to_session():
					if network.is_server:
						release_node_lock(id, _last_scene_path)
					elif multiplayer and multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() != 1:
						rpc_id(1, "release_node_lock", id, _last_scene_path)

		var lock_count = 0
		for id in selected_ids:
			if lock_count >= MAX_LOCK_NODES:
				break
			if not _last_selected_ids.has(id):
				if network and network.is_connected_to_session():
					if network.is_server:
						request_node_lock(id, _last_scene_path)
					elif multiplayer and multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() != 1:
						rpc_id(1, "request_node_lock", id, _last_scene_path)
			lock_count += 1

		_last_selected_ids = selected_ids
		if network and network.is_connected_to_session():
			var my_uid = multiplayer.get_unique_id()
			if network.is_server:
				for pid in _get_connected_peers():
					if pid != my_uid:
						rpc_id(pid, "update_peer_selection", my_uid, selected_ids, _last_scene_path)
			elif my_uid != 1:
				rpc_id(1, "update_peer_selection", my_uid, selected_ids, _last_scene_path)

func _get_2d_node_rect(node: Node) -> Rect2:
	if node is Control:
		return Rect2(Vector2.ZERO, node.size)

	if node is CanvasItem:
		if node.has_method("_edit_use_rect") and node.call("_edit_use_rect"):
			var r = node.call("_edit_get_rect")
			if r is Rect2 and r.size != Vector2.ZERO:
				return r

		if node is Sprite2D:
			if node.texture:
				return node.get_rect()
		elif node is AnimatedSprite2D:
			if node.sprite_frames and node.sprite_frames.has_animation(node.animation):
				var tex = node.sprite_frames.get_frame_texture(node.animation, node.frame)
				if tex:
					var sz = tex.get_size()
					var pos = -sz / 2.0 if node.centered else Vector2.ZERO
					pos += node.offset
					return Rect2(pos, sz)
		elif node is MeshInstance2D:
			if node.mesh:
				var aabb = node.mesh.get_aabb()
				return Rect2(aabb.position.x, aabb.position.y, aabb.size.x, aabb.size.y)
		elif node is MultiMeshInstance2D:
			if node.multimesh:
				var aabb = node.multimesh.get_aabb()
				return Rect2(aabb.position.x, aabb.position.y, aabb.size.x, aabb.size.y)
		elif node is CollisionShape2D:
			if node.shape:
				return node.shape.get_rect()
		elif node is CollisionPolygon2D:
			if node.polygon.size() > 0:
				var min_p = node.polygon[0]
				var max_p = node.polygon[0]
				for p in node.polygon:
					min_p = min_p.min(p)
					max_p = max_p.max(p)
				return Rect2(min_p, max_p - min_p)
		elif node is Marker2D:
			var ext = node.gizmo_extents if "gizmo_extents" in node else 10.0
			return Rect2(-Vector2(ext, ext), Vector2(ext, ext) * 2.0)
		elif node.has_method("_edit_get_rect"):
			var r = node.call("_edit_get_rect")
			if r is Rect2 and r.size != Vector2.ZERO:
				return r

	return Rect2(Vector2(-10, -10), Vector2(20, 20))

@rpc("any_peer", "reliable")
func update_peer_selection(peer_id: int, selected_ids: Array, scene_path: String = ""):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if network and network.is_server and sender_id != 0:
		for pid in _get_connected_peers():
			if pid != sender_id:
				rpc_id(pid, "update_peer_selection", peer_id, selected_ids, scene_path)

	if network and (network.get("is_standalone_server") or DisplayServer.get_name() == "headless"):
		return
	var outline_group_name = _get_selection_group_name(peer_id)
	var outline_name = _get_selection_outline_name(peer_id)

	# Add custom selection drawing logic
	var color = network.get_user_color(peer_id)
	var current_scene = _get_target_scene(scene_path)
	if not current_scene:
		return

	# Clear previous indicators globally for this peer in the current scene
	var tree = current_scene.get_tree()
	if tree:
		for node in tree.get_nodes_in_group(outline_group_name):
			if is_instance_valid(node):
				node.queue_free()

	# If the peer is selecting nodes in a different scene than our active tab, don't draw outlines here
	var active_scene = _get_edited_scene_root()
	var active_path = active_scene.scene_file_path if active_scene else ""
	if active_path == "" and active_scene:
		active_path = active_scene.get_meta("scene_file_path", "")
	if scene_path != "" and active_path != "" and active_path != scene_path:
		return

	# Add new indicators (cap at MAX_OUTLINE_NODES to avoid viewport render stalls on large selections)
	var drawn_count = 0
	for id in selected_ids:
		if drawn_count >= MAX_OUTLINE_NODES:
			break
		var node = network.get_node_by_unique_id(current_scene, id)
		if node:
			drawn_count += 1
			if node is Node3D:
				var outline = MeshInstance3D.new()
				outline.name = outline_name
				outline.set_meta("team_create_outline_peer", peer_id)
				outline.add_to_group(outline_group_name)
				outline.add_to_group("TeamCreateSelectionOutlines")
				var mat = StandardMaterial3D.new()
				mat.albedo_color = color
				mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				mat.albedo_color.a = 0.5

				# Attempt to fit box to mesh if available
				var box_mesh = BoxMesh.new()
				if node is MeshInstance3D and node.mesh:
					var aabb = node.mesh.get_aabb()
					box_mesh.size = aabb.size * 1.05
					outline.position = aabb.position + aabb.size/2
				else:
					box_mesh.size = Vector3(1.1, 1.1, 1.1)

				outline.mesh = box_mesh
				outline.material_override = mat
				_is_adding_outline = true
				if is_instance_valid(node) and node.is_inside_tree():
					node.add_child(outline)
				_is_adding_outline = false

			elif node is Node2D:
				# Not a Control, whose position is rounded to whole units. Under a large scale that shows as an offset
				var node_rect = _get_2d_node_rect(node)
				var corners = PackedVector2Array([node_rect.position, Vector2(node_rect.end.x, node_rect.position.y), node_rect.end, Vector2(node_rect.position.x, node_rect.end.y)])
				var outline = Polygon2D.new()
				outline.name = outline_name
				outline.set_meta("team_create_outline_peer", peer_id)
				outline.add_to_group(outline_group_name)
				outline.add_to_group("TeamCreateSelectionOutlines")
				outline.color = Color(color, 0.15)
				outline.polygon = corners

				var border = Line2D.new()
				border.name = "OutlineBorder"
				corners.append(corners[0])
				border.points = corners
				border.default_color = Color(color, 0.6)
				# It's a child of the node, so a large scale would thicken it just as much
				var node_scale = node.global_scale.abs()
				border.width = 1.0 / maxf(maxf(node_scale.x, node_scale.y), 0.001)
				outline.add_child(border)

				_is_adding_outline = true
				if is_instance_valid(node) and node.is_inside_tree():
					node.add_child(outline)
				_is_adding_outline = false

			elif node is Control:
				var outline = ColorRect.new()
				outline.name = outline_name
				outline.set_meta("team_create_outline_peer", peer_id)
				outline.add_to_group(outline_group_name)
				outline.add_to_group("TeamCreateSelectionOutlines")
				outline.color = color
				outline.color.a = 0.15

				var node_rect = _get_2d_node_rect(node)
				outline.position = node_rect.position
				outline.size = node_rect.size

				# Border reference rect for crisp outline
				var border = ReferenceRect.new()
				border.name = "OutlineBorder"
				border.position = Vector2.ZERO
				border.size = node_rect.size
				border.border_color = Color(color.r, color.g, color.b, 0.6)
				border.border_width = 1.0
				border.editor_only = false
				border.mouse_filter = Control.MOUSE_FILTER_IGNORE
				outline.add_child(border)

				# Ensure it doesn't block mouse
				outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
				_is_adding_outline = true
				if is_instance_valid(node) and node.is_inside_tree():
					node.add_child(outline)
				_is_adding_outline = false

func clear_peer_selections(peer_id: int):
	var outline_group_name = _get_selection_group_name(peer_id)
	var current_scene = _get_edited_scene_root()
	if not current_scene:
		return

	var tree = current_scene.get_tree()
	if tree:
		for node in tree.get_nodes_in_group(outline_group_name):
			if is_instance_valid(node):
				node.queue_free()

func push_current_scene():
	if network and network.is_server:
		if _dirty_scenes.size() > 0:
			save_dirty_scenes()
		var current_scene = _get_edited_scene_root()
		if current_scene:
			var path = current_scene.scene_file_path
			if path != "":
				if FileAccess.file_exists(path):
					var bytes = FileAccess.get_file_as_bytes(path)
					var total_size = bytes.size()

					if total_size == 0:
						rpc("receive_scene", path, randi(), bytes, true)
						return

					rpc("receive_scene", path, randi(), bytes, true)

func push_specific_scene_to_peer(scene_path: String, id: int):
	if not (network and network.is_server):
		return
	if not network.file_sync.is_safe_scene_path(scene_path):
		printerr("Team Create: Blocked scene request for invalid path: ", scene_path)
		return

	if _dirty_scenes.size() > 0:
		save_dirty_scenes()

	if not (network and network.get("is_standalone_server")):
		var current_scene = _get_edited_scene_root()
		if current_scene and current_scene.scene_file_path == scene_path:
			push_current_scene_to_peer(id)
			return

	if network and network.get("is_standalone_server"):
		_save_server_tracked_scenes()

	# Flush to disk ensures peer gets exact authoritative scene file with UIDs intact
	if FileAccess.file_exists(scene_path):
		var bytes = FileAccess.get_file_as_bytes(scene_path)
		_send_scene_bytes_to_peer(scene_path, bytes, id)

func _send_scene_bytes_to_peer(path: String, bytes: PackedByteArray, id: int):
	var total_size = bytes.size()

	if total_size == 0:
		rpc_id(id, "receive_scene", path, randi(), bytes, true)
		return

	rpc_id(id, "receive_scene", path, randi(), bytes, true)

func push_current_scene_to_peer(id: int):
	if network and network.is_server:
		if _dirty_scenes.size() > 0:
			save_dirty_scenes()
		var current_scene = _get_edited_scene_root()
		if current_scene:
			var path = current_scene.scene_file_path
			if path != "":
				var ei = _get_editor_interface()
				if ei and ei.has_method("save_scene"):
					ei.save_scene()
				if FileAccess.file_exists(path):
					var bytes = FileAccess.get_file_as_bytes(path)
					_send_scene_bytes_to_peer(path, bytes, id)

func _on_node_added(node: Node):
	if not is_instance_valid(node):
		return
	if node.name.begins_with("TeamCreateSelectionOutline_") or node.name.begins_with("TeamCreateCursor"):
		return

	# Connect for tracking before removal
	if not node.tree_exiting.is_connected(_on_node_tree_exiting.bind(node)):
		node.tree_exiting.connect(_on_node_tree_exiting.bind(node))

	_node_names[node.get_instance_id()] = node.name

	# A node that left the tree earlier this frame is being moved, and _on_node_removed reports that
	var was_moved = _was_removed_this_frame(node.get_instance_id())

	if network and not network.is_connected_to_session() and not was_moved:
		_mark_offline_addition(node)

	if _is_applying_remote_update or _ignore_next_structure_event or _is_reloading_scene or not (network and network.is_connected_to_session()) or _get_connected_peers().is_empty():
		return

	if was_moved:
		return

	# Capture owner state before the frame delay.
	# Nodes instantiated from a PackedScene (like during a scene reload or sub-scene drag-and-drop)
	# will already have their owner set. Nodes added manually via the editor GUI will have owner = null.
	var owner_at_add = node.owner

	if not is_inside_tree():
		return

	# Delay execution slightly so properties are set if instantiated via code
	await get_tree().process_frame

	# Ensure the node still exists and has a parent after the frame delay
	if not is_instance_valid(node) or not node.get_parent():
		return

	# Catch unintentionally duplicated outline nodes from Godot's native duplication
	if "TeamCreateSelectionOutline_" in node.name and not _is_adding_outline:
		node.queue_free()
		return

	# Prevent syncing internal nodes like editor UI or auto-generated items
	if node.name.begins_with("TeamCreateSelectionOutline_") or node.name.begins_with("TeamCreateCursor"):
		return

	var current_scene = _get_edited_scene_root()
	if not current_scene:
		return

	# Never sync the root scene node itself
	if node == current_scene:
		return

	# Only sync nodes that are part of the edited scene
	if node.owner != current_scene:
		return

	# PREVENT SCENE FLOODING AND EMPTY MESHES:
	# If the node already had an owner when it was added to the tree, it was loaded from a file
	# (e.g., scene reload, sub-scene instantiation). Do NOT broadcast these to other peers as new nodes,
	# because the other peers either already have them (from file sync) or they are internal children of a sub-scene.
	if owner_at_add != null:
		return

	# Always generate a fresh distinct UUID for newly added/duplicated nodes
	# so duplicate nodes (Ctrl+D) never inherit the original node's UUID
	var new_uuid = str(ResourceUID.create_id())
	node.set_meta("_tc_uuid", new_uuid)

	var parent_id = network.assign_unique_id(node.get_parent())
	var type = node.get_class()
	var new_name = node.name
	var new_id = network.assign_unique_id(node)
	var node_scene_path = node.scene_file_path if node.scene_file_path != "" else ""

	_node_names[node.get_instance_id()] = new_name

	var scene_path = current_scene.scene_file_path
	rpc("remote_node_added", parent_id, type, new_name, new_uuid, scene_path, node_scene_path)
	mark_scene_dirty(scene_path)

	# Immediately sync properties of the new node to catch duplicates
	_sync_all_node_properties(node, new_id, scene_path)

# For a node that never reached the server. Keeps its id if it has one, as others may know it by that.
func send_node_again(node: Node, scene_path: String):
	var uuid = node.get_meta("_tc_uuid", str(ResourceUID.create_id()))
	node.set_meta("_tc_uuid", uuid)
	rpc("remote_node_added", network.assign_unique_id(node.get_parent()), node.get_class(), node.name, uuid, scene_path, node.scene_file_path)
	_sync_all_node_properties(node, network.assign_unique_id(node), scene_path)

func send_resource_again(node: Node, id: String, prop_name: String, scene_path: String):
	var res = null
	if node:
		res = animation_from_key(node, prop_name) if prop_name.begins_with(ANIMATION_KEY) else node.get(prop_name)
	if not res is Resource:
		return
	var value = export_sub_resource_dict(res, scene_path) if _is_built_in_subresource(res) else network._dummy_path_to_original.get(res.resource_path, res.resource_path)
	if _last_tracked_properties.has(id):
		_last_tracked_properties[id][prop_name] = value
	_send_update_node_property(id, prop_name, value, scene_path)

func _sync_all_node_properties(node: Node, id: String, scene_path: String = ""):
	if scene_path == "":
		scene_path = _last_scene_path
	_finish_remote_move(node)
	# Create a temporary default instance to compare against
	var type = node.get_class()
	if not ClassDB.can_instantiate(type):
		return

	var default_node = ClassDB.instantiate(type)
	if not default_node:
		return

	var props = node.get_property_list()
	var current_props = {}
	if node is AnimationMixer:
		_track_animations(node, id, current_props, scene_path, true)
	if not _scene_groups(node).is_empty():
		current_props[GROUPS_KEY] = _scene_groups(node)

	for p in props:
		if _is_synced_node_property(node, p):
			if p.name.begins_with("metadata/"):
				continue

			var val = node.get(p.name)
			var default_val = default_node.get(p.name)

			# Check if the property differs from the default value
			var is_different = false
			if typeof(val) != typeof(default_val):
				is_different = true
			elif typeof(val) == TYPE_OBJECT:
				if val != default_val and val != null:
					is_different = true
			else:
				if val != default_val:
					is_different = true

			if is_different:
				if typeof(val) == TYPE_OBJECT:
					if val is Resource:
						if not _is_built_in_subresource(val):
							var r_path = val.resource_path
							if network and network.get("_dummy_path_to_original") and network._dummy_path_to_original.has(r_path):
								r_path = network._dummy_path_to_original[r_path]
							current_props[p.name] = r_path
						else:
							_register_subresource_listener(val, id, p.name)
							current_props[p.name] = export_sub_resource_dict(val, scene_path)
				else:
					current_props[p.name] = val

	default_node.free()

	var connections = []
	var signals = node.get_signal_list()
	for sig in signals:
		var conns = node.get_signal_connection_list(sig.name)
		for c in conns:
			if c.flags & CONNECT_PERSIST:
				var target_obj = c.callable.get_object()
				if target_obj is Node:
					var target_id = network.assign_unique_id(target_obj)
					connections.append({
						"signal": sig.name,
						"target_id": target_id,
						"method": c.callable.get_method(),
						"flags": c.flags,
						"unbinds": c.callable.get_unbound_arguments_count() if c.callable.get_unbound_arguments_count() > 0 else 0,
						"binds": c.callable.get_bound_arguments()
					})
	if connections.size() > 0:
		current_props["__connections__"] = connections

	if not _last_tracked_properties.has(id):
		_last_tracked_properties[id] = current_props
	else:
		var last_props = _last_tracked_properties[id]
		for prop_name in current_props:
			last_props[prop_name] = current_props[prop_name]

	# Send all non-default properties
	for prop_name in current_props:
		_send_update_node_property(id, prop_name, current_props[prop_name], scene_path)

func _on_node_removed(node: Node):
	var inst_id = node.get_instance_id()
	var pre_data = _pre_removal_paths.get(inst_id, {})
	var id = ""
	var scene_path = ""
	var root_node = null
	var old_parent_inst = 0
	if typeof(pre_data) == TYPE_DICTIONARY:
		id = pre_data.get("id", "")
		scene_path = pre_data.get("scene_path", "")
		root_node = pre_data.get("root_node")
		old_parent_inst = pre_data.get("parent_inst", 0)
	elif typeof(pre_data) == TYPE_STRING:
		id = pre_data

	if _pre_removal_paths.has(inst_id):
		_pre_removal_paths.erase(inst_id)

	if id != "" or not (network and network.is_connected_to_session()):
		_note_removed_this_frame(inst_id)

	if _ignore_next_structure_event or _is_reloading_scene or not (network and network.is_connected_to_session()) or _get_connected_peers().is_empty() or id == "":
		if _node_names.has(inst_id):
			_node_names.erase(inst_id)
		if id != "" and _last_tracked_properties.has(id):
			_last_tracked_properties.erase(id)
		return

	if id == ".":
		return

	if not is_inside_tree():
		return

	# Delay execution slightly to check if the node was reparented or if scene root was closed
	await get_tree().process_frame
	await get_tree().process_frame

	if not is_inside_tree() or not (network and network.is_connected_to_session()):
		return

	if _is_reloading_scene:
		return

	# Check if node was reparented rather than deleted
	if is_instance_valid(node) and node.is_inside_tree():
		var current_scene = _get_edited_scene_root()
		var new_parent = node.get_parent()
		if new_parent and current_scene and (node.owner == current_scene or node == current_scene or new_parent == current_scene or new_parent.owner == current_scene):
			_node_names[inst_id] = node.name
			_last_tracked_properties.erase(id)
			# Same parent means an ancestor was moved, and this node travels with it
			if new_parent.get_instance_id() == old_parent_inst:
				return
			rpc("remote_node_reparented", id, network.assign_unique_id(new_parent), node.get_index(), scene_path, node.name)
			mark_scene_dirty(scene_path)
			_send_moved_node_layout(node, scene_path)
			return

	if _node_names.has(inst_id):
		_node_names.erase(inst_id)
	if id != "" and _last_tracked_properties.has(id):
		_last_tracked_properties.erase(id)

	# If the root node that owned this node is no longer valid, the entire scene was closed or reloaded.
	# We should NOT broadcast individual node removals for a destroyed scene.
	if root_node == null or not is_instance_valid(root_node) or not root_node.is_inside_tree():
		return

	# Prevent sending removal if the user is just closing/switching scenes.
	var current_scene = _get_edited_scene_root()
	if current_scene:
		var active_scene_path = current_scene.scene_file_path
		if scene_path != "" and active_scene_path != scene_path:
			return
		if root_node != current_scene and root_node.owner != current_scene:
			return
	else:
		# If current_scene is null, they are closing the last scene tab.
		return

	rpc("remote_node_removed", id, scene_path)
	mark_scene_dirty(scene_path)

func _note_removed_this_frame(inst_id: int):
	var frame = Engine.get_process_frames()
	if frame != _removed_frame:
		_removed_this_frame.clear()
		_removed_frame = frame
	_removed_this_frame[inst_id] = true

func _was_removed_this_frame(inst_id: int) -> bool:
	return _removed_frame == Engine.get_process_frames() and _removed_this_frame.has(inst_id)

# A move can change a node's local position to its default value, which a property diff wouldn't send
func _send_moved_node_layout(node: Node, scene_path: String):
	var id = network.assign_unique_id(node)
	var layout_props = []
	if node is Node3D or node is Node2D:
		layout_props = ["transform"]
	elif node is Control:
		layout_props = ["offset_left", "offset_top", "offset_right", "offset_bottom"]
	for prop_name in layout_props:
		_send_update_node_property(id, prop_name, node.get(prop_name), scene_path)

func _on_node_renamed(node: Node):
	if _ignore_next_structure_event or _is_reloading_scene or not (network and network.is_connected_to_session()) or _get_connected_peers().is_empty():
		return

	var inst_id = node.get_instance_id()
	# Moving onto a name that's taken renames the node, which the move message already carries
	if _was_removed_this_frame(inst_id):
		_node_names[inst_id] = node.name
		return

	var current_scene = _get_edited_scene_root()
	var scene_path = current_scene.scene_file_path if current_scene else ""

	# Check if this node is the top-level scene root itself
	if current_scene and node == current_scene:
		var old_name = _node_names.get(inst_id, "")
		var new_name = node.name
		if new_name.begins_with("@"):
			return # Never rename scene root to an internal engine temporary name
		if old_name != "" and old_name != new_name:
			_node_names[inst_id] = new_name
			rpc("remote_node_renamed_exact", "__SCENE_ROOT__", old_name, new_name, scene_path)
			mark_scene_dirty(scene_path)
		elif old_name == "":
			_node_names[inst_id] = new_name
		return

	var parent = node.get_parent()
	if parent and _node_names.has(inst_id):
		var old_name = _node_names[inst_id]
		var new_name = node.name

		if old_name != new_name:
			_node_names[inst_id] = new_name
			var parent_id = network.assign_unique_id(parent)
			rpc("remote_node_renamed_exact", parent_id, old_name, new_name, scene_path)
			mark_scene_dirty(scene_path)

@rpc("any_peer", "reliable")
func remote_node_reparented(id: String, new_parent_id: String, new_index: int, scene_path: String = "", new_name: String = ""):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if network and network.is_server and sender_id != 0:
		for peer_id in _get_connected_peers():
			if peer_id != sender_id:
				rpc_id(peer_id, "remote_node_reparented", id, new_parent_id, new_index, scene_path, new_name)

	_is_applying_remote_update = true
	_ignore_next_structure_event = true
	var current_scene = _get_target_scene(scene_path)
	if current_scene:
		if scene_path != "" and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) != scene_path:
			_ignore_next_structure_event = false
			_is_applying_remote_update = false
			return
		var node = network.get_node_by_unique_id(current_scene, id)
		var new_parent = network.get_node_by_unique_id(current_scene, new_parent_id)
		if is_instance_valid(node) and is_instance_valid(new_parent) and node != current_scene:
			if node.get_parent() != new_parent:
				node.reparent(new_parent, false)
			if new_name != "" and str(node.name) != new_name:
				node.name = new_name
			if new_index >= 0 and new_index < new_parent.get_child_count():
				new_parent.move_child(node, new_index)
			if new_parent.owner and new_parent.owner != current_scene and new_parent.scene_file_path == "":
				node.owner = new_parent.owner
			else:
				node.owner = current_scene
			_node_names[node.get_instance_id()] = node.name
			mark_scene_dirty(scene_path)
	_ignore_next_structure_event = false
	_is_applying_remote_update = false

@rpc("any_peer", "reliable")
func remote_node_added(parent_id: String, type: String, new_name: String, new_id: String, scene_path: String = "", node_scene_path: String = ""):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if node_scene_path != "" and network and network.file_sync and not network.file_sync.is_safe_scene_path(node_scene_path):
		printerr("Team Create: Blocked sub-scene with invalid path: ", node_scene_path)
		return
	if network and network.is_server and sender_id != 0:
		for peer_id in _get_connected_peers():
			if peer_id != sender_id:
				rpc_id(peer_id, "remote_node_added", parent_id, type, new_name, new_id, scene_path, node_scene_path)

	_ignore_next_structure_event = true
	var current_scene = _get_target_scene(scene_path)
	if current_scene:
		if scene_path != "" and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) != scene_path:
			_ignore_next_structure_event = false
			return
		var parent = network.get_node_by_unique_id(current_scene, parent_id)
		if not parent:
			if node_scene_path != "":
				_pending_subscene_instantiations.append({
					"parent_id": parent_id,
					"type": type,
					"new_name": new_name,
					"new_id": new_id,
					"scene_path": scene_path,
					"node_scene_path": node_scene_path,
					"sender_id": sender_id,
					"timeout": Time.get_ticks_msec() + 30000
				})
			_ignore_next_structure_event = false
			return

		# Prevent duplicates. If the exact node name already exists under the parent,
		# DO NOT instantiate a new one. This fundamentally prevents exponential rejoin floods.
		# The same goes for a node we already have under another name or parent.
		if parent.has_node(new_name) or network._find_node_by_uuid(current_scene, new_id):
			_ignore_next_structure_event = false
			return

		var new_node = null
		if node_scene_path != "":
			var is_downloading = network and network.file_sync and node_scene_path in network.file_sync.downloading_files
			var file_exists = FileAccess.file_exists(node_scene_path)
			if file_exists and not is_downloading:
				var res = _safe_load_headless(node_scene_path)
				var scn = res.get("packed", null)
				if scn and scn is PackedScene:
					new_node = _instantiate_subscene(scn)

			if not new_node:
				_pending_subscene_instantiations.append({
					"parent_id": parent_id,
					"type": type,
					"new_name": new_name,
					"new_id": new_id,
					"scene_path": scene_path,
					"node_scene_path": node_scene_path,
					"sender_id": sender_id,
					"timeout": Time.get_ticks_msec() + 30000
				})
				if network and network.file_sync and not file_exists and not is_downloading:
					network.file_sync.request_asset_immediately(node_scene_path, sender_id)
				_ignore_next_structure_event = false
				return

		if not new_node:
			if ClassDB.can_instantiate(type):
				new_node = ClassDB.instantiate(type)
			else:
				new_node = Node.new()

		new_node.name = new_name
		new_node.set_meta("_tc_uuid", new_id)
		_node_names[new_node.get_instance_id()] = new_name
		parent.add_child(new_node)
		if parent.owner and parent.owner != current_scene and parent.scene_file_path == "":
			new_node.owner = parent.owner
		else:
			new_node.owner = current_scene
		mark_scene_dirty(scene_path)
		_process_pending_node_properties()
	_ignore_next_structure_event = false

@rpc("any_peer", "reliable")
func remote_node_removed(id: String, scene_path: String = ""):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if network and network.is_server and sender_id != 0:
		for peer_id in _get_connected_peers():
			if peer_id != sender_id:
				rpc_id(peer_id, "remote_node_removed", id, scene_path)

	_ignore_next_structure_event = true
	var current_scene = _get_target_scene(scene_path)
	if current_scene:
		if scene_path != "" and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) != scene_path:
			_ignore_next_structure_event = false
			return
		var node = network.get_node_by_unique_id(current_scene, id)
		if is_instance_valid(node) and node != current_scene:
			_node_names.erase(node.get_instance_id())
			var parent = node.get_parent()
			if is_instance_valid(parent):
				parent.remove_child(node)
			node.queue_free()
			mark_scene_dirty(scene_path)
	_ignore_next_structure_event = false

@rpc("any_peer", "reliable")
func remote_node_renamed(new_id: String, new_name: String):
	# Kept for compatibility but superseded by remote_node_renamed_exact
	pass

@rpc("any_peer", "reliable")
func remote_node_renamed_exact(parent_id: String, old_name: String, new_name: String, scene_path: String = ""):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if network and network.is_server and sender_id != 0:
		for peer_id in _get_connected_peers():
			if peer_id != sender_id:
				rpc_id(peer_id, "remote_node_renamed_exact", parent_id, old_name, new_name, scene_path)

	_ignore_next_structure_event = true
	var current_scene = _get_target_scene(scene_path)
	if current_scene:
		if scene_path != "" and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) != scene_path:
			_ignore_next_structure_event = false
			return
		if parent_id == "__SCENE_ROOT__":
			if new_name.begins_with("@"):
				_ignore_next_structure_event = false
				return
			current_scene.name = new_name
			_node_names[current_scene.get_instance_id()] = new_name
			mark_scene_dirty(scene_path)
			_ignore_next_structure_event = false
			return
		var parent = network.get_node_by_unique_id(current_scene, parent_id)
		if parent:
			var node = parent.get_node_or_null(old_name)
			if node:
				node.name = new_name
				_node_names[node.get_instance_id()] = new_name
				mark_scene_dirty(scene_path)
	_ignore_next_structure_event = false

func _send_update_node_property(id: String, prop_name: String, value: Variant, scene_path: String = ""):
	if not is_inside_tree() or not (network and network.is_connected_to_session()):
		return
	if typeof(value) == TYPE_DICTIONARY and value.has("sub_resource_bytes") and (value["sub_resource_bytes"] as PackedByteArray).is_empty():
		return

	var bytes = PackedByteArray()

	# Always serialize to check size
	bytes = var_to_bytes_with_objects(value)

	if bytes.size() > 60000:
		var transfer_id = randi()
		var total_size = bytes.size()
		var sent = 0
		while sent < total_size:
			var to_send = min(60000, total_size - sent)
			var chunk = bytes.slice(sent, sent + to_send)
			sent += to_send
			var is_final = sent >= total_size
			rpc("update_node_property_chunked", id, prop_name, transfer_id, chunk, scene_path, is_final)
	else:
		rpc("update_node_property", id, prop_name, value, scene_path)

@rpc("any_peer", "reliable")
func update_node_property_chunked(id: String, prop_name: String, transfer_id: int, chunk: PackedByteArray, scene_path: String = "", is_final: bool = true):
	var sender_id = multiplayer.get_remote_sender_id() if (network and network.is_connected_to_session()) else 0

	if network and network.is_server and sender_id != 0:
		for peer_id in _get_connected_peers():
			if peer_id != sender_id:
				rpc_id(peer_id, "update_node_property_chunked", id, prop_name, transfer_id, chunk, scene_path, is_final)

	var prop_key = str(sender_id) + "_" + id + "_" + prop_name + "_" + str(transfer_id)

	if not _receiving_properties.has(prop_key):
		_receiving_properties[prop_key] = PackedByteArray()

	_receiving_properties[prop_key].append_array(chunk)

	if is_final:
		var full_bytes = _receiving_properties[prop_key]
		_receiving_properties.erase(prop_key)

		var reassembled_value = bytes_to_var_with_objects(full_bytes)

		# Forward the reassembled value to the main property handler without duplicate relay
		_is_forwarding_chunked_property = true
		update_node_property(id, prop_name, reassembled_value, scene_path)
		_is_forwarding_chunked_property = false

@rpc("any_peer", "reliable")
func update_node_property(id: String, prop_name: String, value: Variant, scene_path: String = ""):
	var sender_id = multiplayer.get_remote_sender_id() if (network and network.is_connected_to_session()) else 0

	if network and network.is_server and sender_id != 0 and not _is_forwarding_chunked_property:
		for peer_id in _get_connected_peers():
			if peer_id != sender_id:
				rpc_id(peer_id, "update_node_property", id, prop_name, value, scene_path)

	# Block metadata updates for security
	if prop_name.begins_with("metadata/"):
		printerr("Team Create: Blocked unsafe property sync: ", prop_name)
		return
	var current_scene = _get_target_scene(scene_path)
	if current_scene:
		if scene_path != "" and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) != scene_path:
			return
		var node = network.get_node_by_unique_id(current_scene, id)
		if node and prop_name.begins_with(ANIMATION_KEY):
			_receive_animation(current_scene, node, id, prop_name, value, scene_path, sender_id)
		elif node:
			_is_applying_remote_update = true
			if typeof(value) == TYPE_STRING and (value as String).begins_with("res://"):
				# Validate path to prevent directory traversal
				if ".." in (value as String):
					printerr("Team Create: Invalid resource path received: ", value)
					_is_applying_remote_update = false
					return

				# It's a resource path
				var is_downloading = network and network.file_sync and value in network.file_sync.downloading_files
				var is_scanning = false
				var ei = _get_editor_interface()
				if ei and ei.get_resource_filesystem():
					is_scanning = ei.get_resource_filesystem().is_scanning()

				var res = null
				var safe_exists = _safe_resource_exists(value)
				if not is_downloading and not is_scanning and safe_exists:
					res = load(value)

				if res:
					node.set(prop_name, res)
				elif network.get("is_standalone_server"):
					# Standalone server cannot load imported resources. Create a dummy.
					var dummy_path = network._get_or_create_dummy_resource(value, "Resource")
					var dummy_res = load(dummy_path)
					if dummy_res:
						node.set(prop_name, dummy_res)
				else:
					# Request immediately from peer and queue for import completion
					if network and network.file_sync:
						network.file_sync.request_asset_immediately(value, sender_id)
					_pending_resource_properties.append({"id": id, "prop_name": prop_name, "value": value, "scene_path": scene_path, "sender_id": sender_id, "timeout": Time.get_ticks_msec() + 30000})
			elif typeof(value) == TYPE_DICTIONARY and value.has("sub_resource_bytes"):
				var is_scanning = false
				var ei = _get_editor_interface()
				if ei and ei.get_resource_filesystem():
					is_scanning = ei.get_resource_filesystem().is_scanning()

				var is_ready = true
				if is_scanning:
					is_ready = false
				else:
					var text = value.get("sub_resource_text", "")
					if text != "":
						var regex = RegEx.new()
						regex.compile("ext_resource.*path=\"(res://[^\"]+)\"")
						for m in regex.search_all(text):
							var ext_path = m.get_string(1)
							if network and network.file_sync and ext_path in network.file_sync.downloading_files:
								is_ready = false
								break
							if not _safe_resource_exists(ext_path):
								is_ready = false
								if network and network.file_sync:
									network.file_sync.request_asset_immediately(ext_path, sender_id)
								break

				if is_ready:
					var subres_id = value.get("sub_resource_id", "")
					var existing_res = _get_cached_subresource(subres_id, scene_path) if subres_id != "" else null
					var applied_res: Resource = null
					if existing_res:
						var updated = _update_existing_subresource(existing_res, value)
						if updated:
							if node.get(prop_name) != existing_res:
								node.set(prop_name, existing_res)
							applied_res = existing_res
						else:
							var res = _import_sub_resource(value)
							if res:
								if subres_id != "":
									_register_subresource(res, subres_id, scene_path)
								node.set(prop_name, res)
								applied_res = res
					else:
						var res = _import_sub_resource(value)
						if res:
							if subres_id != "":
								_register_subresource(res, subres_id, scene_path)
							node.set(prop_name, res)
							applied_res = res
				else:
					_pending_resource_properties.append({"id": id, "prop_name": prop_name, "value": value, "scene_path": scene_path, "sender_id": sender_id, "timeout": Time.get_ticks_msec() + 30000})
			elif prop_name == "__connections__":
				_apply_connections(node, value, current_scene)
			elif prop_name == GROUPS_KEY:
				_apply_groups(node, value)
			elif not _start_remote_move(node, prop_name, value):
				node.set(prop_name, value)

			_is_applying_remote_update = false
			mark_scene_dirty(scene_path)

			_dirty_subresources.erase(id + ":" + prop_name)

			if typeof(value) == TYPE_DICTIONARY and value.has("sub_resource_bytes"):
				var stored_dict = value.duplicate()
				var cur_obj = node.get(prop_name)
				if is_instance_valid(cur_obj) and cur_obj is Resource:
					_resource_prints[cur_obj.get_instance_id()] = _resource_print(cur_obj)
					stored_dict["resource_instance_id"] = cur_obj.get_instance_id()
					_register_subresource_listener(cur_obj, id, prop_name)
				_remember_remote_property(current_scene, id, prop_name, stored_dict)
			else:
				_remember_remote_property(current_scene, id, prop_name, value)
		else:
			_pending_node_properties.append({
				"id": id,
				"prop_name": prop_name,
				"value": value,
				"scene_path": scene_path,
				"sender_id": sender_id,
				"timeout": Time.get_ticks_msec() + 30000
			})

# ==============================================================================
# Automatic Semantic Offline Scene Merge
# ==============================================================================

var _pending_offline_merges = {}
var _offline_merges_scheduled = {}

# Marks nodes added while disconnected, so that rejoining can tell them apart from
# nodes that others renamed, moved or deleted in the meantime.
func _mark_offline_addition(node: Node):
	if node.owner != null or _is_reloading_scene:
		return
	var edited_scene = _get_edited_scene_root()
	if edited_scene and edited_scene.is_ancestor_of(node):
		node.set_meta("_tc_offline_added", true)

func prepare_offline_scene_merge(path: String, incoming_server_bytes: PackedByteArray) -> Dictionary:
	if network and network.is_server:
		return {}
	if network and network.get("is_standalone_server"):
		return {}
	if incoming_server_bytes.is_empty():
		return {}
	if path == "" or not (path.ends_with(".tscn") or path.ends_with(".scn")):
		return {}

	# If the file exists locally and content is identical, no merge needed
	if FileAccess.file_exists(path):
		var existing_bytes = FileAccess.get_file_as_bytes(path)
		if existing_bytes == incoming_server_bytes:
			return {}
	else:
		return {}

	# 1. Obtain local scene root
	var ei = _get_editor_interface()
	var local_root: Node = null
	var is_temp_local = false
	if ei:
		var active_scene = ei.get_edited_scene_root()
		if active_scene and (active_scene.scene_file_path == path or active_scene.get_meta("scene_file_path", "") == path):
			local_root = active_scene

	if not local_root and FileAccess.file_exists(path):
		var local_packed = load(path)
		if local_packed and local_packed is PackedScene:
			local_root = local_packed.instantiate()
			is_temp_local = true

	if not is_instance_valid(local_root):
		return {}

	# 2. Instantiate incoming server scene from buffer
	var temp_server_path = "user://tc_merge_temp_" + str(randi()) + ".tscn"
	var f = FileAccess.open(temp_server_path, FileAccess.WRITE)
	if not f:
		if is_temp_local and is_instance_valid(local_root):
			local_root.free()
		return {}
	f.store_buffer(incoming_server_bytes)
	f.close()

	var server_packed = load(temp_server_path)
	DirAccess.remove_absolute(temp_server_path)
	if not server_packed or not (server_packed is PackedScene):
		if is_temp_local and is_instance_valid(local_root):
			local_root.free()
		return {}

	var server_root = server_packed.instantiate()
	if not is_instance_valid(server_root):
		if is_temp_local and is_instance_valid(local_root):
			local_root.free()
		return {}

	# 3. Collect all paths and UUIDs from server scene
	var server_paths = {}
	var server_uuids = {}
	_collect_node_paths_and_uuids(server_root, server_root, server_paths, server_uuids)

	# 4. Find all nodes in local scene that do not exist on server
	var added_nodes = []
	_find_offline_added_nodes(local_root, local_root, server_paths, server_uuids, added_nodes, path)

	# Cleanup temporary server and local instances
	if is_instance_valid(server_root):
		server_root.free()
	if is_temp_local and is_instance_valid(local_root):
		local_root.free()

	if added_nodes.is_empty():
		return {}

	var merge_data = {
		"scene_path": path,
		"added_nodes": added_nodes
	}
	_pending_offline_merges[path] = merge_data
	network.tc_print("Team Create: Detected ", str(added_nodes.size()), " offline additions to merge for ", path)
	return merge_data

func _collect_node_paths_and_uuids(root: Node, node: Node, paths: Dictionary, uuids: Dictionary):
	if not is_instance_valid(node):
		return
	var rel_path = "." if node == root else str(root.get_path_to(node))
	paths[rel_path] = true
	if node.has_meta("_tc_uuid"):
		uuids[str(node.get_meta("_tc_uuid"))] = true
	for child in node.get_children():
		_collect_node_paths_and_uuids(root, child, paths, uuids)

func _find_offline_added_nodes(local_root: Node, node: Node, server_paths: Dictionary, server_uuids: Dictionary, added_nodes: Array, scene_path: String, parent_is_addition: bool = false):
	if not is_instance_valid(node):
		return
	for child in node.get_children():
		if not is_instance_valid(child):
			continue
		if child.is_in_group("TeamCreateSelectionOutlines") or child.is_in_group("TeamCreateCursors"):
			continue
		if child.name.begins_with("TeamCreateSelectionOutline") or child.name.begins_with("TeamCreateCursor"):
			continue

		var rel_path = str(local_root.get_path_to(child))
		var uuid = str(child.get_meta("_tc_uuid")) if child.has_meta("_tc_uuid") else ""
		var exists_on_server = server_paths.has(rel_path) or (uuid != "" and server_uuids.has(uuid))

		var is_addition = not exists_on_server and child.owner != null and (parent_is_addition or child.has_meta("_tc_offline_added"))

		if is_addition:
			var parent = child.get_parent()
			var parent_id = "." if parent == local_root else str(local_root.get_path_to(parent))
			var node_type = child.get_class()
			var node_name = child.name
			var new_id = network.assign_unique_id(child)
			var node_scene_path = child.scene_file_path if child.scene_file_path != "" else ""
			var props = _extract_node_properties_for_merge(child)

			added_nodes.append({
				"parent_id": parent_id,
				"type": node_type,
				"name": node_name,
				"id": new_id,
				"uuid": uuid,
				"scene_path": scene_path,
				"node_scene_path": node_scene_path,
				"properties": props
			})

			# Instantiated sub-scenes load their internal children automatically
			if node_scene_path != "":
				continue

		_find_offline_added_nodes(local_root, child, server_paths, server_uuids, added_nodes, scene_path, is_addition)

func _extract_node_properties_for_merge(node: Node) -> Dictionary:
	var type = node.get_class()
	if not ClassDB.can_instantiate(type):
		return {}

	var default_node = ClassDB.instantiate(type)
	if not default_node:
		return {}

	var props = node.get_property_list()
	var current_props = {}

	for p in props:
		if _is_synced_node_property(node, p):
			if p.name.begins_with("metadata/"):
				continue

			var val = node.get(p.name)
			var default_val = default_node.get(p.name)

			var is_different = false
			if typeof(val) != typeof(default_val):
				is_different = true
			elif typeof(val) == TYPE_OBJECT:
				if val != default_val and val != null:
					is_different = true
			else:
				if val != default_val:
					is_different = true

			if is_different:
				if typeof(val) == TYPE_OBJECT:
					if val is Resource:
						if not _is_built_in_subresource(val):
							var r_path = val.resource_path
							if network and network.get("_dummy_path_to_original") and network._dummy_path_to_original.has(r_path):
								r_path = network._dummy_path_to_original[r_path]
							current_props[p.name] = r_path
						else:
							current_props[p.name] = export_sub_resource_dict(val, node.scene_file_path if node.scene_file_path != "" else _last_scene_path)
				else:
					current_props[p.name] = val

	default_node.free()
	return current_props

func apply_offline_merge_deferred(path: String, merge_data: Dictionary = {}):
	if merge_data.is_empty():
		if _pending_offline_merges.has(path):
			merge_data = _pending_offline_merges[path]
		else:
			return

	if merge_data.is_empty() or not merge_data.has("added_nodes"):
		return
	var added = merge_data["added_nodes"]
	if added.is_empty():
		return

	if not (network and network.is_connected_to_session()):
		return

	network.tc_print("Team Create: Applying ", str(added.size()), " offline additions for ", path)

	for item in added:
		var parent_id = item["parent_id"]
		var type = item["type"]
		var new_name = item["name"]
		var new_id = item["id"]
		var scene_path = item["scene_path"]
		var node_scene_path = item["node_scene_path"]
		var props = item["properties"]
		var uuid = item.get("uuid", "")
		if uuid == "":
			uuid = str(ResourceUID.create_id())

		# 1. Instantiate locally
		remote_node_added(parent_id, type, new_name, uuid, scene_path, node_scene_path)

		# 2. Broadcast to server & peers
		rpc("remote_node_added", parent_id, type, new_name, uuid, scene_path, node_scene_path)

		# 3. Apply and broadcast properties
		for prop_name in props:
			var val = props[prop_name]
			update_node_property(new_id, prop_name, val, scene_path)
			_send_update_node_property(new_id, prop_name, val, scene_path)

		mark_scene_dirty(scene_path)

	_pending_offline_merges.erase(path)

@rpc("any_peer", "reliable")
func receive_scene(path: String, transfer_id: int, bytes: PackedByteArray, is_final: bool = true):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	# Only the server pushes scenes, peers save theirs through receive_manual_save
	if sender_id != 1 and sender_id != 0:
		printerr("Team Create: Blocked scene push from peer: ", sender_id)
		return
	if not network.file_sync.is_safe_scene_path(path):
		printerr("Invalid scene path received: ", path)
		return

	var scene_key = str(sender_id) + "_" + str(transfer_id) + "_" + path
	if not _receiving_scenes.has(scene_key):
		_receiving_scenes[scene_key] = PackedByteArray()

	_receiving_scenes[scene_key].append_array(bytes)

	if not is_final:
		return

	var full_bytes = _receiving_scenes[scene_key]
	_receiving_scenes.erase(scene_key)
	bytes = full_bytes

	if network and network.plugin:
		if network.get("is_standalone_server"):
			if bytes.size() > 0:
				_file_write_mutex.lock()
				var file = FileAccess.open(path + ".tmp", FileAccess.WRITE)
				if file:
					file.store_buffer(bytes)
					file.close()
					if DirAccess.remove_absolute(path) == OK or not FileAccess.file_exists(path):
						DirAccess.rename_absolute(path + ".tmp", path)
				_file_write_mutex.unlock()

			if _server_tracked_scenes.has(path):
				var s = _server_tracked_scenes[path]
				if is_instance_valid(s):
					s.queue_free()
				_server_tracked_scenes.erase(path)
			var result = _load_server_scene(path)
			var packed = result.packed
			if packed and packed is PackedScene:
				var instance = _instantiate_server_scene(packed)
				if instance:
					instance.set_meta("scene_file_path", path)
					_server_tracked_scenes[path] = instance
					if result.is_dummy:
						_server_dummy_scenes[path] = true
					else:
						_server_dummy_scenes.erase(path)
					_index_scene_subresources(instance, path)
			return
		else:
			_synced_scene_states[path] = true
			if FileAccess.file_exists(path):
				var disk_bytes = FileAccess.get_file_as_bytes(path)
				if disk_bytes.size() == bytes.size() and disk_bytes == bytes:
					_last_scene_path = path
					return

			var editor = _get_editor_interface()
			var current_scene = editor.get_edited_scene_root() if editor else null
			var open_scenes = editor.get_open_scenes() if editor else PackedStringArray()

			var is_active = false
			if current_scene and current_scene.scene_file_path == path:
				is_active = true

			if is_active and editor:
				var merge_data = prepare_offline_scene_merge(path, bytes)

				# Save camera for active view immediately before reloading
				save_current_camera_for_scene(path, true)
				_save_camera_cache()

				# 1. Write to disk and force reload
				if bytes.size() > 0:
					if network and network.file_sync:
						network.file_sync.backup_scene(path)
					_file_write_mutex.lock()
					var file = FileAccess.open(path + ".tmp", FileAccess.WRITE)
					if file:
						file.store_buffer(bytes)
						file.close()
						if DirAccess.remove_absolute(path) == OK or not FileAccess.file_exists(path):
							DirAccess.rename_absolute(path + ".tmp", path)
					_file_write_mutex.unlock()
				_is_reloading_scene = true
				_last_scene_path = path
				_force_full_sync_next_frame = true

				editor.reload_scene_from_path(path)
				network.tc_print("Team Create: Applying received scene to active view.")
				_defer_restore_camera(path)
				var cur_reloaded = _get_edited_scene_root()
				if cur_reloaded:
					_index_scene_subresources(cur_reloaded)

				get_tree().create_timer(0.5).timeout.connect(func():
					_is_reloading_scene = false
					_last_scene_path = path
					if merge_data.size() > 0 and merge_data.get("added_nodes", []).size() > 0:
						apply_offline_merge_deferred(path, merge_data)
				)
				return
			elif path in open_scenes and editor:
				var merge_data = prepare_offline_scene_merge(path, bytes)

				# 2. Scene is open in tabs but not active. Write to disk and cleanly reload without closing tab.
				if bytes.size() > 0:
					if network and network.file_sync:
						network.file_sync.backup_scene(path)
					_file_write_mutex.lock()
					var tmp_path = path + ".tmp"
					var file = FileAccess.open(tmp_path, FileAccess.WRITE)
					var saved_ok = false
					if file:
						file.store_buffer(bytes)
						file.close()
						if DirAccess.remove_absolute(path) == OK or not FileAccess.file_exists(path):
							if DirAccess.rename_absolute(tmp_path, path) == OK:
								saved_ok = true
						if not saved_ok:
							file = FileAccess.open(path, FileAccess.WRITE)
							if file:
								file.store_buffer(bytes)
								file.close()
							DirAccess.remove_absolute(tmp_path)
					_file_write_mutex.unlock()

				_is_reloading_scene = true
				editor.reload_scene_from_path(path)
				get_tree().create_timer(0.5).timeout.connect(func():
					_is_reloading_scene = false
				)
				var prev_path = current_scene.scene_file_path if current_scene else ""
				if prev_path != "":
					editor.open_scene_from_path(prev_path)
					_defer_restore_camera(prev_path)

				network.tc_print("Team Create: Safely reloaded background scene tab: ", path)
				return

	if bytes.size() > 0:
		var merge_data = prepare_offline_scene_merge(path, bytes)
		if network and network.file_sync:
			network.file_sync.backup_scene(path)
		_file_write_mutex.lock()
		var file = FileAccess.open(path + ".tmp", FileAccess.WRITE)
		if file:
			file.store_buffer(bytes)
			file.close()
			if DirAccess.remove_absolute(path) == OK or not FileAccess.file_exists(path):
				DirAccess.rename_absolute(path + ".tmp", path)
			network.tc_print("Received scene: ", path)
		_file_write_mutex.unlock()

@rpc("any_peer", "reliable")
func request_scene_state(scene_path: String):
	if scene_path == "":
		return
	if not (network and network.is_server):
		return
	if not network.file_sync.is_safe_scene_path(scene_path):
		printerr("Team Create: Blocked scene state request for invalid path: ", scene_path)
		return

	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0

	if _dirty_scenes.size() > 0:
		save_dirty_scenes()

	if network.get("is_standalone_server"):
		_save_server_tracked_scenes()
	else:
		var ei = _get_editor_interface()
		if ei and ei.has_method("save_scene"):
			var cur_scene = ei.get_edited_scene_root()
			if cur_scene and cur_scene.scene_file_path == scene_path:
				_saving_without_instruction = true
				ei.save_scene()
				_saving_without_instruction = false

	if FileAccess.file_exists(scene_path):
		var bytes = FileAccess.get_file_as_bytes(scene_path)
		rpc_id(sender_id, "receive_scene_state", scene_path, randi(), bytes, true)

@rpc("any_peer", "reliable")
func receive_scene_state(path: String, transfer_id: int, bytes: PackedByteArray, is_final: bool = true):
	var sender_id = multiplayer.get_remote_sender_id() if multiplayer else 0
	if sender_id != 1 and sender_id != 0:
		printerr("Team Create: Blocked scene state from peer: ", sender_id)
		return
	if not network.file_sync.is_safe_scene_path(path):
		printerr("Invalid scene state path received: ", path)
		return

	var state_key = str(sender_id) + "_" + str(transfer_id) + "_" + path
	if not _receiving_scene_states.has(state_key):
		_receiving_scene_states[state_key] = PackedByteArray()

	_receiving_scene_states[state_key].append_array(bytes)

	if not is_final:
		return

	var full_bytes = _receiving_scene_states[state_key]
	_receiving_scene_states.erase(state_key)
	bytes = full_bytes

	if bytes.size() > 0:
		_synced_scene_states[path] = true
		var current_disk_bytes = PackedByteArray()
		if FileAccess.file_exists(path):
			current_disk_bytes = FileAccess.get_file_as_bytes(path)
		var is_identical = (current_disk_bytes.size() == bytes.size() and current_disk_bytes == bytes)

		if is_identical:
			_last_scene_path = path
			if not (network and network.get("is_standalone_server")):
				return

		var merge_data = prepare_offline_scene_merge(path, bytes)

		_file_write_mutex.lock()
		var file = FileAccess.open(path + ".tmp", FileAccess.WRITE)
		if file:
			file.store_buffer(bytes)
			file.close()
			if DirAccess.remove_absolute(path) == OK or not FileAccess.file_exists(path):
				DirAccess.rename_absolute(path + ".tmp", path)
			network.tc_print("Team Create: Received up-to-date scene state for ", path)
		_file_write_mutex.unlock()

		if network and network.plugin:
			if network.get("is_standalone_server"):
				# Headless server just reloads the scene into memory
				if _server_tracked_scenes.has(path):
					var s = _server_tracked_scenes[path]
					if is_instance_valid(s):
						s.queue_free()
					_server_tracked_scenes.erase(path)

				var result = _load_server_scene(path)
				var packed = result.packed
				if packed and packed is PackedScene:
					var instance = _instantiate_server_scene(packed)
					if instance:
						instance.set_meta("scene_file_path", path)
						_server_tracked_scenes[path] = instance
						if result.is_dummy:
							_server_dummy_scenes[path] = true
						else:
							_server_dummy_scenes.erase(path)
						_index_scene_subresources(instance, path)
			else:
				var editor = _get_editor_interface()
				if editor:
					var current_scene = editor.get_edited_scene_root()
					if current_scene and current_scene.scene_file_path == path:
						save_current_camera_for_scene(path, true)
						_save_camera_cache()
						_is_reloading_scene = true
						_last_scene_path = path
						editor.reload_scene_from_path(path)
						_defer_restore_camera(path)
						var cur_reloaded = editor.get_edited_scene_root()
						if is_instance_valid(cur_reloaded):
							_index_scene_subresources(cur_reloaded)
						get_tree().create_timer(0.5).timeout.connect(func():
							_is_reloading_scene = false
							_last_scene_path = path
							if merge_data.size() > 0 and merge_data.get("added_nodes", []).size() > 0:
								apply_offline_merge_deferred(path, merge_data)
						)



# Dictionary caches to avoid repeated string concatenation and StringName allocations
var _cached_selection_group_names = {}
var _cached_selection_outline_names = {}
var _cached_cursor_3d_group_names = {}
var _cached_cursor_2d_group_names = {}

func _get_selection_group_name(peer_id: int) -> StringName:
	if not _cached_selection_group_names.has(peer_id):
		_cached_selection_group_names[peer_id] = StringName("TeamCreateSelectionOutlines_" + str(peer_id))
	return _cached_selection_group_names[peer_id]

func _get_selection_outline_name(peer_id: int) -> StringName:
	if not _cached_selection_outline_names.has(peer_id):
		_cached_selection_outline_names[peer_id] = StringName("TeamCreateSelectionOutline_" + str(peer_id))
	return _cached_selection_outline_names[peer_id]

func _get_cursor_3d_group_name(peer_id: int) -> StringName:
	if not _cached_cursor_3d_group_names.has(peer_id):
		_cached_cursor_3d_group_names[peer_id] = StringName("TeamCreateCursor3D_" + str(peer_id))
	return _cached_cursor_3d_group_names[peer_id]

func _get_cursor_2d_group_name(peer_id: int) -> StringName:
	if not _cached_cursor_2d_group_names.has(peer_id):
		_cached_cursor_2d_group_names[peer_id] = StringName("TeamCreateCursor2D_" + str(peer_id))
	return _cached_cursor_2d_group_names[peer_id]

# Tracking cursor positions
var _last_cursor_sync = 0.0
const CURSOR_SYNC_INTERVAL = 0.05
const CURSOR_SMOOTH_SPEED = 10.0
const CURSOR_2D_SIZE = 1.0
const CURSOR_GLIDE_MS = 500
const GLIDE_FRAME_SLEEP_USEC = 16000
const REMOTE_MOVE_PROPS = ["position", "rotation", "scale", "transform", "quaternion", "basis"]
const REMOTE_MOVE_SPEED = 12.0
const REMOTE_MOVE_HOLD_MS = 300
var _local_3d_cursor_pos: Transform3D = Transform3D()
var _local_2d_cursor_pos: Vector2 = Vector2.ZERO
var _has_3d_cursor = false
var _has_2d_cursor = false

var _peer_cursors_3d = {}
var _cursor_targets = {} # cursor node -> {"to": where it's heading, "ends": msec, 0 once it has arrived}
var _glide_frame_rate_raised = false
var _frame_rate_hold_until = 0
var _remote_moves = {} # node -> {"target": pose, "exact": {property: value}, "ends": msec}
var _peer_cursors_2d = {}


func _sync_cursor_throttled(delta):
	if DisplayServer.get_name() == "headless" or (network and network.get("is_standalone_server")):
		return

	if _tab_switch_cooldown > 0.0:
		_tab_switch_cooldown -= delta
		if _tab_switch_cooldown <= 0.0:
			_is_switching_scene_tab = false

	_last_cursor_sync += delta
	if _last_cursor_sync >= CURSOR_SYNC_INTERVAL:
		_last_cursor_sync = 0.0
		var data = _get_local_cursor_data()
		if typeof(data) == TYPE_DICTIONARY and data.get("has_3d", false):
			var pos_3d = data.get("pos_3d", Transform3D())
			if pos_3d != _local_3d_cursor_pos:
				var was_initial = (_local_3d_cursor_pos == Transform3D())
				_local_3d_cursor_pos = pos_3d
				# Camera moved! Save camera position in memory for active scene, but only if:
				# 1. Not the initial transform right after a tab switch/reset
				# 2. Not during tab switch settling cooldown
				# 3. Not during active camera restore
				# 4. Not during scene reload
				# 5. Currently edited scene genuinely matches _last_scene_path
				if not was_initial and not _is_switching_scene_tab and not _is_restoring_camera and not _is_reloading_scene:
					var cur_scn = _get_edited_scene_root()
					if cur_scn and cur_scn.scene_file_path != "" and cur_scn.scene_file_path == _last_scene_path:
						if pos_3d.origin.is_finite() and pos_3d.basis.is_finite():
							_user_scene_cameras[cur_scn.scene_file_path] = {
								"has_3d": true,
								"origin": [pos_3d.origin.x, pos_3d.origin.y, pos_3d.origin.z],
								"basis_x": [pos_3d.basis.x.x, pos_3d.basis.x.y, pos_3d.basis.x.z],
								"basis_y": [pos_3d.basis.y.x, pos_3d.basis.y.y, pos_3d.basis.y.z],
								"basis_z": [pos_3d.basis.z.x, pos_3d.basis.z.y, pos_3d.basis.z.z]
							}
							_is_camera_dirty = true
				if network and network.is_connected_to_session():
					var my_uid = multiplayer.get_unique_id()
					if network.is_server:
						for pid in _get_connected_peers():
							if pid != my_uid:
								rpc_id(pid, "update_peer_cursor_3d", my_uid, _local_3d_cursor_pos, _last_scene_path)
					elif my_uid != 1:
						rpc_id(1, "update_peer_cursor_3d", my_uid, _local_3d_cursor_pos, _last_scene_path)
		elif typeof(data) == TYPE_DICTIONARY and data.get("has_2d", false):
			var pos_2d = data.get("pos_2d", Vector2.ZERO)
			if pos_2d != _local_2d_cursor_pos:
				_local_2d_cursor_pos = pos_2d
				if network and network.is_connected_to_session():
					var my_uid = multiplayer.get_unique_id()
					if network.is_server:
						for pid in _get_connected_peers():
							if pid != my_uid:
								rpc_id(pid, "update_peer_cursor_2d", my_uid, _local_2d_cursor_pos, _last_scene_path)
					elif my_uid != 1:
						rpc_id(1, "update_peer_cursor_2d", my_uid, _local_2d_cursor_pos, _last_scene_path)


@rpc("any_peer", "unreliable")
func update_peer_cursor_3d(peer_id: int, pos: Transform3D, scene_path: String = ""):
	var sender_id = multiplayer.get_remote_sender_id() if (network and network.is_connected_to_session()) else 0
	if network and network.is_server and sender_id != 0:
		for pid in _get_connected_peers():
			if pid != sender_id:
				rpc_id(pid, "update_peer_cursor_3d", peer_id, pos, scene_path)

	if network and (network.get("is_standalone_server") or DisplayServer.get_name() == "headless"):
		return

	var active_scene = _get_edited_scene_root()
	var active_path = active_scene.scene_file_path if active_scene else ""
	if active_path == "" and active_scene:
		active_path = active_scene.get_meta("scene_file_path", "")

	if not active_scene or (scene_path != "" and active_path != "" and active_path != scene_path):
		_clear_peer_cursor(peer_id)
		return

	var current_scene = active_scene
	var tree = current_scene.get_tree()
	if not tree: return

	_clear_peer_cursor_2d(peer_id, current_scene)

	var cursor = _get_or_create_peer_cursor_3d(peer_id, current_scene)
	if cursor:
		if not _cursor_targets.has(cursor):
			cursor.global_transform = pos
		_cursor_targets[cursor] = {"to": pos, "ends": Time.get_ticks_msec() + CURSOR_GLIDE_MS}

@rpc("any_peer", "unreliable")
func update_peer_cursor_2d(peer_id: int, pos: Vector2, scene_path: String = ""):
	var sender_id = multiplayer.get_remote_sender_id() if (network and network.is_connected_to_session()) else 0
	if network and network.is_server and sender_id != 0:
		for pid in _get_connected_peers():
			if pid != sender_id:
				rpc_id(pid, "update_peer_cursor_2d", peer_id, pos, scene_path)

	if network and (network.get("is_standalone_server") or DisplayServer.get_name() == "headless"):
		return

	var active_scene = _get_edited_scene_root()
	var active_path = active_scene.scene_file_path if active_scene else ""
	if active_path == "" and active_scene:
		active_path = active_scene.get_meta("scene_file_path", "")

	if not active_scene or (scene_path != "" and active_path != "" and active_path != scene_path):
		_clear_peer_cursor(peer_id)
		return

	var current_scene = active_scene
	var tree = current_scene.get_tree()
	if not tree: return

	_clear_peer_cursor_3d(peer_id, current_scene)

	var cursor = _get_or_create_peer_cursor_2d(peer_id, current_scene)
	if cursor:
		if not _cursor_targets.has(cursor):
			cursor.global_position = pos
			_keep_cursor_screen_size(cursor)
			cursor.global_rotation = 0.0
		_cursor_targets[cursor] = {"to": pos, "ends": Time.get_ticks_msec() + CURSOR_GLIDE_MS}

# TODO: Implement cursor object pooling instead of repeatedly instantiating/freeing cursor meshes
func _get_or_create_peer_cursor_3d(peer_id: int, current_scene: Node) -> Node3D:
	var group_name = _get_cursor_3d_group_name(peer_id)
	var cursor_name = _get_cursor_3d_group_name(peer_id)
	var tree = current_scene.get_tree() if (is_instance_valid(current_scene) and current_scene.is_inside_tree()) else null
	if tree:
		var nodes = tree.get_nodes_in_group(group_name)
		if nodes.size() > 0 and is_instance_valid(nodes[0]):
			_peer_cursors_3d[peer_id] = nodes[0]
			return nodes[0]
	elif _peer_cursors_3d.has(peer_id) and is_instance_valid(_peer_cursors_3d[peer_id]):
		return _peer_cursors_3d[peer_id]

	var cursor = Node3D.new()
	cursor.name = cursor_name
	cursor.add_to_group(group_name)
	cursor.add_to_group("TeamCreateCursors")
	cursor.set_meta("_edit_lock_", true)

	# The ball
	var sphere_mesh = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.2
	sphere.height = 0.4

	var mat = StandardMaterial3D.new()
	var color = network.get_user_color(peer_id)
	mat.albedo_color = color
	mat.albedo_color.a = 0.5
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true

	sphere_mesh.mesh = sphere
	sphere_mesh.material_override = mat
	sphere_mesh.position.z = 0.0
	cursor.add_child(sphere_mesh)

	# The line/cylinder connecting the ball to the cone
	var stick_mesh = MeshInstance3D.new()
	var stick = CylinderMesh.new()
	stick.top_radius = 0.02
	stick.bottom_radius = 0.02
	stick.height = 0.2
	stick_mesh.mesh = stick
	stick_mesh.material_override = mat
	stick_mesh.position.z = -0.2
	stick_mesh.rotation.x = -PI / 2.0
	cursor.add_child(stick_mesh)

	# The pointer arrow (cone)
	var arrow_mesh = MeshInstance3D.new()
	var arrow = CylinderMesh.new()
	arrow.top_radius = 0.0
	arrow.bottom_radius = 0.08
	arrow.height = 0.2
	arrow_mesh.mesh = arrow
	arrow_mesh.material_override = mat
	arrow_mesh.position.z = -0.4
	arrow_mesh.rotation.x = -PI / 2.0
	cursor.add_child(arrow_mesh)

	# Username label
	var label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.text = network.get_username(peer_id)
	label.position.y = 0.45
	label.position.z = 0.0
	label.no_depth_test = true
	label.modulate = color
	label.font_size = 32
	cursor.add_child(label)

	current_scene.add_child(cursor)
	_peer_cursors_3d[peer_id] = cursor
	return cursor

func _get_or_create_peer_cursor_2d(peer_id: int, current_scene: Node) -> Node2D:
	var group_name = _get_cursor_2d_group_name(peer_id)
	var cursor_name = _get_cursor_2d_group_name(peer_id)
	var tree = current_scene.get_tree() if (is_instance_valid(current_scene) and current_scene.is_inside_tree()) else null
	if tree:
		var nodes = tree.get_nodes_in_group(group_name)
		if nodes.size() > 0 and is_instance_valid(nodes[0]):
			_peer_cursors_2d[peer_id] = nodes[0]
			return nodes[0]
	elif _peer_cursors_2d.has(peer_id) and is_instance_valid(_peer_cursors_2d[peer_id]):
		return _peer_cursors_2d[peer_id]

	var cursor = Node2D.new()
	cursor.name = cursor_name
	cursor.add_to_group(group_name)
	cursor.add_to_group("TeamCreateCursors")
	cursor.set_meta("_edit_lock_", true)

	# Draw a simple cursor shape (like a colored circle or pointer) using a script or polygon
	# We can use a Sprite2D with a generated image, or a Polygon2D
	var poly = Polygon2D.new()
	var color = network.get_user_color(peer_id)
	poly.color = color
	poly.color.a = 1.0
	poly.polygon = PackedVector2Array([
		Vector2(0, 0),
		Vector2(12, 12),
		Vector2(5, 12),
		Vector2(0, 17)
	])

	var outline = Line2D.new()
	outline.points = poly.polygon
	outline.closed = true
	outline.width = 1.5
	outline.default_color = Color(0.3, 0.3, 0.3, 0.8)
	cursor.add_child(outline)

	cursor.add_child(poly)

	var label = Label.new()
	label.name = "UsernameLabel"
	label.text = network.get_username(peer_id)
	label.position = Vector2(14, 10)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.modulate = color
	# Rendered at its final size and scaled back, as scaling up small text would blur it
	var cursor_size = _get_cursor_2d_size()
	label.add_theme_font_size_override("font_size", roundi(11 * cursor_size))
	label.scale = Vector2.ONE / cursor_size
	cursor.add_child(label)

	# Above everything in the scene, whatever z index or order the nodes have
	cursor.z_as_relative = false
	cursor.z_index = RenderingServer.CANVAS_ITEM_Z_MAX
	current_scene.add_child(cursor)
	_peer_cursors_2d[peer_id] = cursor
	return cursor

func _smooth_peer_cursors(delta: float) -> bool:
	var weight = 1.0 - exp(-delta * CURSOR_SMOOTH_SPEED)
	var now = Time.get_ticks_msec()
	var gliding = false
	for cursor in _cursor_targets.keys():
		if not is_instance_valid(cursor) or not cursor.is_inside_tree():
			_cursor_targets.erase(cursor)
			continue
		if cursor is Node2D:
			_keep_cursor_screen_size(cursor)
		var move = _cursor_targets[cursor]
		if move["ends"] == 0:
			continue
		var step = weight
		if now >= move["ends"]:
			move["ends"] = 0
			step = 1.0
		else:
			gliding = true
		if cursor is Node3D:
			cursor.global_transform = cursor.global_transform.interpolate_with(move["to"], step)
		else:
			cursor.global_position = cursor.global_position.lerp(move["to"], step)
			cursor.global_rotation = 0.0
	return gliding

# Follows the editor's display scale, which is 2 on most high resolution screens
func _get_cursor_2d_size() -> float:
	var ei = _get_editor_interface()
	return CURSOR_2D_SIZE * (ei.get_editor_scale() if ei else 1.0)

# Cancels the 2D view's zoom. Only written when it changes, because every write makes the editor redraw
func _keep_cursor_screen_size(cursor: Node2D):
	var zoom = cursor.get_viewport().global_canvas_transform.get_scale().abs()
	if zoom.x <= 0.0 or zoom.y <= 0.0:
		return
	var wanted = Vector2.ONE * _get_cursor_2d_size() / zoom
	if not cursor.global_scale.is_equal_approx(wanted):
		cursor.global_scale = wanted

func hold_frame_rate():
	_frame_rate_hold_until = Time.get_ticks_msec() + CURSOR_GLIDE_MS

# An unfocused editor only runs about 10 frames a second, far too few to see anything glide, so it
# gets a normal frame rate while something is moving. The editor sets its own value whenever focus
# changes, so this only ever replaces the unfocused value, and only puts back what it replaced.
func _update_glide_frame_rate(gliding: bool):
	if not gliding and not _glide_frame_rate_raised:
		return
	var ei = _get_editor_interface()
	if not ei:
		return
	var unfocused_sleep = ei.get_editor_settings().get_setting("interface/editor/unfocused_low_processor_mode_sleep_usec")
	if gliding:
		if OS.low_processor_usage_mode_sleep_usec == unfocused_sleep and unfocused_sleep > GLIDE_FRAME_SLEEP_USEC:
			OS.low_processor_usage_mode_sleep_usec = GLIDE_FRAME_SLEEP_USEC
			_glide_frame_rate_raised = true
	else:
		if OS.low_processor_usage_mode_sleep_usec == GLIDE_FRAME_SLEEP_USEC:
			OS.low_processor_usage_mode_sleep_usec = unfocused_sleep
		_glide_frame_rate_raised = false

# Moves from other editors arrive in steps, so the node glides between them. The exact values go
# back on as soon as the moves stop, and before anything reads the node to save or send it.
func _start_remote_move(node: Node, prop_name: String, value: Variant) -> bool:
	if not prop_name in REMOTE_MOVE_PROPS or not (node is Node2D or node is Node3D) or not node.is_inside_tree():
		return false
	if network and (network.get("is_standalone_server") or DisplayServer.get_name() == "headless"):
		return false

	var shown = _read_pose(node)
	if _remote_moves.has(node):
		_write_pose(node, _remote_moves[node]["target"])
	else:
		_remote_moves[node] = {"exact": {}}
	node.set(prop_name, value)

	var move = _remote_moves[node]
	move["exact"].erase(prop_name)
	move["exact"][prop_name] = value
	move["target"] = _read_pose(node)
	move["ends"] = Time.get_ticks_msec() + REMOTE_MOVE_HOLD_MS
	_write_pose(node, shown)
	return true

func _smooth_remote_moves(delta: float):
	var weight = 1.0 - exp(-delta * REMOTE_MOVE_SPEED)
	var now = Time.get_ticks_msec()
	for node in _remote_moves.keys():
		if not is_instance_valid(node) or now >= _remote_moves[node]["ends"]:
			_finish_remote_move(node)
			continue
		var target = _remote_moves[node]["target"]
		node.position = node.position.lerp(target[0], weight)
		if node is Node2D:
			node.rotation = lerp_angle(node.rotation, target[1], weight)
		else:
			var rot = node.rotation
			node.rotation = Vector3(lerp_angle(rot.x, target[1].x, weight), lerp_angle(rot.y, target[1].y, weight), lerp_angle(rot.z, target[1].z, weight))
		node.scale = node.scale.lerp(target[2], weight)

func _finish_remote_move(node: Variant):
	if not _remote_moves.has(node):
		return
	var move = _remote_moves[node]
	_remote_moves.erase(node)
	if is_instance_valid(node):
		_write_pose(node, move["target"])
		for prop_name in move["exact"]:
			node.set(prop_name, move["exact"][prop_name])

func finish_remote_moves():
	for node in _remote_moves.keys():
		_finish_remote_move(node)

func _read_pose(node: Node) -> Array:
	return [node.position, node.rotation, node.scale]

func _write_pose(node: Node, pose: Array):
	node.position = pose[0]
	node.rotation = pose[1]
	node.scale = pose[2]

func _clear_peer_cursor(peer_id: int):
	var current_scene = _get_edited_scene_root()
	if not current_scene: return
	_clear_peer_cursor_3d(peer_id, current_scene)
	_clear_peer_cursor_2d(peer_id, current_scene)

func _clear_peer_cursor_3d(peer_id: int, current_scene: Node):
	var group_name = _get_cursor_3d_group_name(peer_id)
	for node in current_scene.get_tree().get_nodes_in_group(group_name):
		if is_instance_valid(node): node.queue_free()

func _clear_peer_cursor_2d(peer_id: int, current_scene: Node):
	var group_name = _get_cursor_2d_group_name(peer_id)
	for node in current_scene.get_tree().get_nodes_in_group(group_name):
		if is_instance_valid(node): node.queue_free()

func clear_all_peer_indicators():
	_peer_cursors_3d.clear()
	_peer_cursors_2d.clear()
	var current_scene = _get_edited_scene_root()
	if not current_scene:
		return

	var tree = current_scene.get_tree()
	if tree:
		for node in tree.get_nodes_in_group("TeamCreateSelectionOutlines"):
			if is_instance_valid(node):
				node.queue_free()
		for node in tree.get_nodes_in_group("TeamCreateCursors"):
			if is_instance_valid(node):
				node.queue_free()

func _update_cursor_username(peer_id: int, username: String):
	if _peer_cursors_3d.has(peer_id) and is_instance_valid(_peer_cursors_3d[peer_id]):
		for child in _peer_cursors_3d[peer_id].get_children():
			if child is Label3D:
				child.text = username

	if _peer_cursors_2d.has(peer_id) and is_instance_valid(_peer_cursors_2d[peer_id]):
		for child in _peer_cursors_2d[peer_id].get_children():
			if child is Label:
				child.text = username

	var current_scene = _get_edited_scene_root()
	var tree = current_scene.get_tree() if (is_instance_valid(current_scene) and current_scene.is_inside_tree()) else (get_tree() if is_inside_tree() else null)
	if not tree: return

	var group_name_3d = _get_cursor_3d_group_name(peer_id)
	for node in tree.get_nodes_in_group(group_name_3d):
		if is_instance_valid(node):
			for child in node.get_children():
				if child is Label3D:
					child.text = username
	var group_name_2d = _get_cursor_2d_group_name(peer_id)
	for node in tree.get_nodes_in_group(group_name_2d):
		if is_instance_valid(node):
			for child in node.get_children():
				if child is Label:
					child.text = username

func _update_peer_color(peer_id: int, color: Color):
	var tree = get_tree() if is_inside_tree() else null
	if not tree:
		return
	for group_name in [_get_selection_group_name(peer_id), _get_cursor_3d_group_name(peer_id), _get_cursor_2d_group_name(peer_id)]:
		for node in tree.get_nodes_in_group(group_name):
			if is_instance_valid(node):
				_apply_peer_color(node, color)

func _apply_peer_color(node: Node, color: Color):
	if node is MeshInstance3D and node.material_override is StandardMaterial3D:
		node.material_override.albedo_color = Color(color, node.material_override.albedo_color.a)
	elif node is ColorRect or node is Polygon2D:
		node.color = Color(color, node.color.a)
	elif node is ReferenceRect:
		node.border_color = Color(color, node.border_color.a)
	elif node is Line2D and node.name == "OutlineBorder":
		node.default_color = Color(color, node.default_color.a)
	elif node is Label3D or node is Label:
		node.modulate = color
	for child in node.get_children():
		_apply_peer_color(child, color)

func _find_editor_viewport(node: Node, type_name: String) -> Node:
	if node.get_class() == type_name:
		return node
	for i in range(node.get_child_count()):
		var res = _find_editor_viewport(node.get_child(i), type_name)
		if res: return res
	return null

func _find_editor_camera_3d(node: Node) -> Camera3D:
	if node is Camera3D:
		return node
	for i in range(node.get_child_count()):
		var res = _find_editor_camera_3d(node.get_child(i))
		if res: return res
	return null


var _cached_3d_viewport: Node = null
var _cached_2d_viewport: Control = null
var _cached_3d_camera: Camera3D = null

func _get_local_cursor_data() -> Dictionary:
	var result = {"has_3d": false, "pos_3d": Transform3D(), "has_2d": false, "pos_2d": Vector2.ZERO}
	if DisplayServer.get_name() == "headless" or (network and network.get("is_standalone_server")):
		return result
	var ei = _get_editor_interface()
	if not ei or not ei.has_method("get_editor_main_screen"): return result

	var main_screen = ei.get_editor_main_screen()
	if not is_instance_valid(main_screen) or not main_screen.is_inside_tree(): return result

	# 3D Editor Viewport
	if not is_instance_valid(_cached_3d_viewport):
		_cached_3d_viewport = _find_editor_viewport(main_screen, "Node3DEditorViewport")
	if is_instance_valid(_cached_3d_viewport) and _cached_3d_viewport is CanvasItem and _cached_3d_viewport.is_visible_in_tree():
		if not is_instance_valid(_cached_3d_camera):
			_cached_3d_camera = _find_editor_camera_3d(_cached_3d_viewport)
		var cam = _cached_3d_camera
		if is_instance_valid(cam):
			result["has_3d"] = true
			result["pos_3d"] = cam.global_transform

	# 2D Editor Viewport
	if not is_instance_valid(_cached_2d_viewport):
		_cached_2d_viewport = _find_editor_viewport(main_screen, "CanvasItemEditorViewport")

	if is_instance_valid(_cached_2d_viewport) and _cached_2d_viewport is CanvasItem and _cached_2d_viewport.is_visible_in_tree():
		var mouse_pos = _cached_2d_viewport.get_local_mouse_position()
		var rect = Rect2(Vector2.ZERO, _cached_2d_viewport.size)
		if rect.has_point(mouse_pos):
			result.has_2d = true
			var current_scene = _get_edited_scene_root()
			if is_instance_valid(current_scene):
				var scene_vp = current_scene.get_viewport()
				if scene_vp and scene_vp.global_canvas_transform.determinant() != 0:
					result.pos_2d = scene_vp.global_canvas_transform.affine_inverse() * mouse_pos
				else:
					result.pos_2d = mouse_pos
			else:
				result.pos_2d = mouse_pos

	return result

func _apply_connections(node: Node, connections_data: Array, current_scene: Node):
	# First disconnect existing persistent connections to avoid duplicates
	var signals = node.get_signal_list()
	for sig in signals:
		var conns = node.get_signal_connection_list(sig.name)
		for c in conns:
			if c.flags & CONNECT_PERSIST:
				node.disconnect(sig.name, c.callable)

	for c_data in connections_data:
		var target = network.get_node_by_unique_id(current_scene, c_data["target_id"])
		if is_instance_valid(target):
			var callable = Callable(target, c_data["method"])
			if c_data.has("binds") and typeof(c_data["binds"]) == TYPE_ARRAY and c_data["binds"].size() > 0:
				callable = callable.bindv(c_data["binds"])
			if c_data.has("unbinds") and c_data["unbinds"] > 0:
				callable = callable.unbind(c_data["unbinds"])
			node.connect(c_data["signal"], callable, c_data["flags"])

func _safe_resource_exists(path: String) -> bool:
	if network and network.get("is_standalone_server"):
		return FileAccess.file_exists(path)
	if not FileAccess.file_exists(path):
		return false
	var ext = path.get_extension().to_lower()
	if ext in ["png", "jpg", "jpeg", "svg", "webp", "wav", "ogg", "mp3", "glb", "gltf", "fbx", "dae"]:
		var import_path = path + ".import"
		if not FileAccess.file_exists(import_path):
			return false
		var config = ConfigFile.new()
		if config.load(import_path) == OK:
			if config.has_section("remap"):
				var target_remap = ""
				for key in config.get_section_keys("remap"):
					if key.begins_with("path."):
						var feat = key.get_slice(".", 1)
						if OS.has_feature(feat):
							target_remap = config.get_value("remap", key, "")
							break
				if target_remap == "" and config.has_section_key("remap", "path"):
					target_remap = config.get_value("remap", "path", "")
				if target_remap != "" and not FileAccess.file_exists(target_remap):
					return false

			var dest_files = config.get_value("deps", "dest_files", [])
			if dest_files.size() > 0:
				for dest_file in dest_files:
					if not FileAccess.file_exists(dest_file):
						return false
		else:
			return false
	return true

func _import_sub_resource(value: Dictionary) -> Resource:
	var temp_path = "user://tc_sync_import_" + str(value.hash()) + ".tres"
	var file = FileAccess.open(temp_path, FileAccess.WRITE)
	if file:
		if network and network.get("is_standalone_server"):
			var s_text = value.get("sub_resource_text", "")
			if s_text != "":
				var ext_regex = RegEx.new()
				ext_regex.compile("\\[ext_resource.*?\\]")
				var p_regex = RegEx.new()
				p_regex.compile('path="(res://[^"]+)"')
				var t_regex = RegEx.new()
				t_regex.compile('type="([^"]+)"')
				for m in ext_regex.search_all(s_text):
					var full_m = m.get_string()
					var p_m = p_regex.search(full_m)
					var t_m = t_regex.search(full_m)
					if p_m:
						var orig_p = p_m.get_string(1)
						var r_type = t_m.get_string(1) if t_m else ""
						var can_load = ResourceLoader.exists(orig_p)
						if can_load:
							var import_path = orig_p + ".import"
							if FileAccess.file_exists(import_path):
								var config = ConfigFile.new()
								if config.load(import_path) == OK:
									var dest_files = config.get_value("deps", "dest_files", [])
									for dest_file in dest_files:
										if not FileAccess.file_exists(dest_file):
											can_load = false
											break
						if not can_load:
							var dummy_p = network._get_or_create_dummy_resource(orig_p, r_type)
							var new_m = full_m.replace('path="' + orig_p + '"', 'path="' + dummy_p + '"')
							var uid_regex = RegEx.new()
							uid_regex.compile('uid="uid://.*?"\\s*')
							new_m = uid_regex.sub(new_m, "")
							s_text = s_text.replace(full_m, new_m)
				file.store_string(s_text)
			else:
				file.store_buffer(value["sub_resource_bytes"])
		else:
			file.store_buffer(value["sub_resource_bytes"])
		file.close()

	var res = load(temp_path)
	DirAccess.remove_absolute(temp_path)
	if res is Resource:
		var path = value.get("resource_path", "")
		if path != "" and path.begins_with("res://") and not "::" in path:
			res.take_over_path(path)
		else:
			res.resource_path = ""
		var u_id = value.get("scene_unique_id", "")
		if u_id == "":
			u_id = _clean_unique_id(value.get("sub_resource_id", ""))
		if u_id != "":
			res.set_scene_unique_id(u_id)
		return res
	return null

func _on_resource_changed(target, prop_name: String, res: Resource):
	if _is_applying_remote_update:
		return
	var id = ""
	if typeof(target) == TYPE_STRING:
		id = target
	elif is_instance_valid(target) and target is Node:
		id = network.assign_unique_id(target)
	else:
		return

	_dirty_subresources[id + ":" + prop_name] = true

# Most resources don't fire changed when edited, and none pass it up from a resource inside them. So when
# something goes through the undo history, built-in resources are compared with how they last looked.
func _resource_print_changed(res: Resource) -> bool:
	var new_print = _resource_print(res)
	var key = res.get_instance_id()
	var changed = _resource_prints.has(key) and _resource_prints[key] != new_print
	_resource_prints[key] = new_print
	return changed

func _resource_print(res: Resource, seen: Dictionary = {}) -> int:
	if seen.has(res):
		return 0
	seen[res] = true
	var parts = [res.get_class()]
	# Reading these back can mean fetching the whole thing from the GPU
	if res is ArrayMesh or res is ImageTexture or res is PortableCompressedTexture2D:
		return hash(parts)
	for p in res.get_property_list():
		if p.usage & PROPERTY_USAGE_STORAGE and not p.name.begins_with("resource_") and p.name != "script" and not p.name.begins_with("metadata/"):
			parts.append(p.name)
			parts.append(_value_print(res.get(p.name), seen))
	return hash(parts)

func _value_print(value: Variant, seen: Dictionary) -> int:
	match typeof(value):
		TYPE_OBJECT:
			if value is Resource:
				return _resource_print(value, seen) if _is_built_in_subresource(value) else _original_path(value).hash()
			return 0
		TYPE_ARRAY:
			return hash(value.map(func(item): return _value_print(item, seen)))
		TYPE_DICTIONARY:
			var parts = []
			for key in value:
				parts.append(hash([_value_print(key, seen), _value_print(value[key], seen)]))
			parts.sort()
			return hash(parts)
	return hash(value)

# The server can only make stand-ins for files it can't load, and those shouldn't look like a change
func _original_path(res: Resource) -> String:
	return network._dummy_path_to_original.get(res.resource_path, res.resource_path)

func _apply_groups(node: Node, groups: Variant):
	if not groups is Array:
		return
	for group in _scene_groups(node):
		if not group in groups:
			node.remove_from_group(group)
	for group in groups:
		if group is String:
			node.add_to_group(group, true)

# A mixer's libraries don't sync like other properties, so each has its own tracked entries. "__animation__:lib:"
# says the library is there, and "__animation__:lib:name" is one animation in it, so that people working on
# different animations don't replace each other's work. Neither name can contain a colon.
func _animation_key(lib_name: StringName, anim_name: StringName = &"") -> String:
	return ANIMATION_KEY + str(lib_name) + ":" + str(anim_name)

# Part of this scene's file, or a temporary copy of it. Anything else has a file of its own, which syncs when saved.
func _is_resource_in_scene(res: Resource, scene_path: String) -> bool:
	if not _is_built_in_subresource(res):
		return false
	var path = res.resource_path
	return path == "" or path.begins_with("user://") or _clean_scene_path(path.get_slice("::", 0)) == _clean_scene_path(scene_path)

func _track_animations(node: AnimationMixer, id: String, current_props: Dictionary, scene_path: String, with_contents: bool):
	for lib_name in node.get_animation_library_list():
		var lib = node.get_animation_library(lib_name)
		if not _is_resource_in_scene(lib, scene_path):
			current_props[_animation_key(lib_name)] = _original_path(lib)
			continue
		current_props[_animation_key(lib_name)] = true
		for anim_name in lib.get_animation_list():
			var anim = lib.get_animation(anim_name)
			var key = _animation_key(lib_name, anim_name)
			if not _is_resource_in_scene(anim, scene_path):
				current_props[key] = _original_path(anim)
			elif with_contents:
				_register_subresource_listener(anim, id, key)
				_resource_prints[anim.get_instance_id()] = _resource_print(anim)
				current_props[key] = export_sub_resource_dict(anim, scene_path)
			else:
				current_props[key] = _tracked_built_in_value(anim, id, key)

# The animations scene checks compare. Ones with their own file aren't updated on the server until they arrive.
func animation_prints(node: AnimationMixer, scene_path: String) -> Dictionary:
	var prints = {}
	for lib_name in node.get_animation_library_list():
		var lib = node.get_animation_library(lib_name)
		if _is_resource_in_scene(lib, scene_path):
			for anim_name in lib.get_animation_list():
				if _is_resource_in_scene(lib.get_animation(anim_name), scene_path):
					prints[_animation_key(lib_name, anim_name)] = _resource_print(lib.get_animation(anim_name))
	return prints

func animation_from_key(node: Node, key: String) -> Animation:
	var parts = key.trim_prefix(ANIMATION_KEY).split(":")
	if not node is AnimationMixer or parts.size() != 2 or not node.has_animation_library(parts[0]):
		return null
	var lib = node.get_animation_library(parts[0])
	return lib.get_animation(parts[1]) if lib.has_animation(parts[1]) else null

func _built_in_library(node: AnimationMixer, lib_name: StringName, scene_path: String) -> AnimationLibrary:
	if node.has_animation_library(lib_name):
		var lib = node.get_animation_library(lib_name)
		if _is_resource_in_scene(lib, scene_path):
			return lib
		node.remove_animation_library(lib_name)
	var new_lib = AnimationLibrary.new()
	node.add_animation_library(lib_name, new_lib)
	return new_lib

# Keeps the same animation, since the editor's animation panel may be showing it
func _put_animation(lib: AnimationLibrary, anim_name: StringName, fresh: Animation, scene_path: String) -> Animation:
	var current = lib.get_animation(anim_name) if lib.has_animation(anim_name) else null
	if current and _is_resource_in_scene(current, scene_path):
		current.clear()
		for marker in current.get_marker_names():
			current.remove_marker(marker)
		for p in fresh.get_property_list():
			if p.usage & PROPERTY_USAGE_STORAGE and not p.name.begins_with("resource_") and p.name != "script" and not p.name.begins_with("metadata/"):
				current.set(p.name, fresh.get(p.name))
		return current
	if current:
		lib.remove_animation(anim_name)
	lib.add_animation(anim_name, fresh)
	return fresh

func _apply_animation(node: Node, key: String, value: Variant, scene_path: String) -> Animation:
	var parts = key.trim_prefix(ANIMATION_KEY).split(":")
	if not node is AnimationMixer or parts.size() != 2:
		return null
	var lib_name = StringName(parts[0])
	var anim_name = StringName(parts[1])
	if anim_name == &"":
		if value == null:
			if node.has_animation_library(lib_name):
				node.remove_animation_library(lib_name)
		elif value is String:
			var file_lib = load(value)
			if file_lib is AnimationLibrary and (not node.has_animation_library(lib_name) or node.get_animation_library(lib_name) != file_lib):
				if node.has_animation_library(lib_name):
					node.remove_animation_library(lib_name)
				node.add_animation_library(lib_name, file_lib)
		else:
			_built_in_library(node, lib_name, scene_path)
		return null
	if value == null:
		if node.has_animation_library(lib_name) and node.get_animation_library(lib_name).has_animation(anim_name):
			node.get_animation_library(lib_name).remove_animation(anim_name)
		return null
	var lib = _built_in_library(node, lib_name, scene_path)
	if value is String:
		var file_anim = load(value)
		if file_anim is Animation:
			if lib.has_animation(anim_name):
				lib.remove_animation(anim_name)
			lib.add_animation(anim_name, file_anim)
		return null
	if value is Dictionary and value.has("sub_resource_bytes"):
		var fresh = _import_sub_resource(value)
		if fresh is Animation:
			return _put_animation(lib, anim_name, fresh, scene_path)
	return null

func copy_animation(node: Node, source: Node, key: String, scene_path: String):
	var fresh = animation_from_key(source, key)
	var parts = key.trim_prefix(ANIMATION_KEY).split(":")
	if fresh and node is AnimationMixer:
		_put_animation(_built_in_library(node, parts[0], scene_path), parts[1], fresh.duplicate(true), scene_path)

func _resource_value_ready(value: Variant, sender_id: int) -> bool:
	var paths = []
	if value is String:
		paths.append(value)
	elif value is Dictionary:
		var regex = RegEx.new()
		regex.compile("ext_resource.*path=\"(res://[^\"]+)\"")
		for m in regex.search_all(value.get("sub_resource_text", "")):
			paths.append(m.get_string(1))
	var ei = _get_editor_interface()
	if not paths.is_empty() and ei and ei.get_resource_filesystem() and ei.get_resource_filesystem().is_scanning():
		return false
	for path in paths:
		if network.file_sync and path in network.file_sync.downloading_files:
			return false
		if not _safe_resource_exists(path):
			if network.file_sync and sender_id != 0:
				network.file_sync.request_asset_immediately(path, sender_id)
			return false
	return true

func _receive_animation(scene_root: Node, node: Node, id: String, key: String, value: Variant, scene_path: String, sender_id: int):
	if value is String and (not value.begins_with("res://") or ".." in value):
		printerr("Team Create: Invalid resource path received: ", value)
		return
	if not _resource_value_ready(value, sender_id):
		_pending_animations.append({"id": id, "key": key, "value": value, "scene_path": scene_path, "timeout": Time.get_ticks_msec() + 30000})
		return
	_is_applying_remote_update = true
	var applied = _apply_animation(node, key, value, scene_path)
	_is_applying_remote_update = false
	mark_scene_dirty(scene_path)
	_dirty_subresources.erase(id + ":" + key)
	if value == null:
		if scene_root == _get_edited_scene_root() and _last_tracked_properties.has(id):
			_last_tracked_properties[id].erase(key)
		return
	var remembered = value
	if applied:
		_resource_prints[applied.get_instance_id()] = _resource_print(applied)
		_register_subresource_listener(applied, id, key)
		remembered = value.duplicate()
		remembered["resource_instance_id"] = applied.get_instance_id()
	_remember_remote_property(scene_root, id, key, remembered)

func _process_pending_animations():
	var now = Time.get_ticks_msec()
	for i in range(_pending_animations.size() - 1, -1, -1):
		var pending = _pending_animations[i]
		if now > pending.timeout:
			_pending_animations.remove_at(i)
		elif _resource_value_ready(pending.value, 0):
			_pending_animations.remove_at(i)
			update_node_property(pending.id, pending.key, pending.value, pending.scene_path)

# A saved resource that's open here is the same copy nodes are already using, so it has to change in place.
# Waits for downloads, since it may refer to a file that's still on its way.
func _process_pending_resource_reloads():
	if _resources_to_reload.is_empty() or (network.file_sync and not network.file_sync.downloading_files.is_empty()):
		return
	var paths = _resources_to_reload
	_resources_to_reload = []
	var was_applying = _is_applying_remote_update
	_is_applying_remote_update = true
	for path in paths:
		if ResourceLoader.has_cached(path):
			ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	_is_applying_remote_update = was_applying

func _clean_scene_path(path: String) -> String:
	if path == "":
		return ""
	var p = path
	p = p.replace(".server_temp.tscn", ".tscn")
	p = p.replace(".server_save.tscn", ".tscn")
	if p.ends_with(".tmp"):
		p = p.substr(0, p.length() - 4)
	return p

func _clean_unique_id(subres_id: String) -> String:
	if subres_id == "":
		return ""
	if "::" in subres_id:
		return subres_id.get_slice("::", 1)
	return subres_id

func _is_built_in_subresource(res: Resource) -> bool:
	if not res:
		return false
	var p = res.resource_path
	if p.begins_with("user://tc_dummy_"):
		return false
	if network and network.get("_dummy_path_to_original") and network._dummy_path_to_original.has(p):
		return false
	if p != "" and p.begins_with("res://") and not "::" in p:
		return false
	return true

func _get_or_create_subresource_id(res: Resource, scene_path: String = "") -> String:
	if not res or not _is_built_in_subresource(res):
		return ""
	var inst_id = res.get_instance_id()
	if _resource_to_subres_id.has(inst_id):
		var existing_id = _resource_to_subres_id[inst_id]
		if not _subres_id_to_resource.has(existing_id):
			_subres_id_to_resource[existing_id] = weakref(res)
		var u = _clean_unique_id(existing_id)
		if u != "" and not _subres_id_to_resource.has(u):
			_subres_id_to_resource[u] = weakref(res)
		return existing_id

	var unique_id = ""
	if res.resource_path != "" and "::" in res.resource_path:
		unique_id = _clean_unique_id(res.resource_path)
	elif res.get_scene_unique_id() != "":
		unique_id = res.get_scene_unique_id()
	else:
		unique_id = res.get_class() + "_" + Resource.generate_scene_unique_id()
		res.set_scene_unique_id(unique_id)

	var effective_scene = scene_path
	if effective_scene == "" and res.resource_path != "" and "::" in res.resource_path:
		effective_scene = _clean_scene_path(res.resource_path.get_slice("::", 0))
	if effective_scene == "":
		effective_scene = _last_scene_path
	effective_scene = _clean_scene_path(effective_scene)

	var sub_id = (effective_scene + "::" + unique_id) if effective_scene != "" else unique_id

	_resource_to_subres_id[inst_id] = sub_id
	_subres_id_to_resource[sub_id] = weakref(res)
	if unique_id != "":
		_subres_id_to_resource[unique_id] = weakref(res)
	return sub_id

func _register_subresource(res: Resource, subres_id: String, scene_path: String = ""):
	if not res or subres_id == "" or not _is_built_in_subresource(res):
		return
	var inst_id = res.get_instance_id()
	var u_id = _clean_unique_id(subres_id)
	if u_id != "":
		res.set_scene_unique_id(u_id)

	var effective_scene = scene_path
	if effective_scene == "" and "::" in subres_id:
		effective_scene = _clean_scene_path(subres_id.get_slice("::", 0))
	if effective_scene == "":
		effective_scene = _last_scene_path
	effective_scene = _clean_scene_path(effective_scene)

	var canonical_id = (effective_scene + "::" + u_id) if (effective_scene != "" and u_id != "") else subres_id

	_resource_to_subres_id[inst_id] = canonical_id
	_subres_id_to_resource[canonical_id] = weakref(res)
	_subres_id_to_resource[subres_id] = weakref(res)
	if u_id != "":
		_subres_id_to_resource[u_id] = weakref(res)

func _get_cached_subresource(subres_id: String, scene_path: String = "") -> Resource:
	if subres_id == "":
		return null

	var candidates = []
	candidates.append(subres_id)

	var u_id = _clean_unique_id(subres_id)
	var scn = scene_path
	if scn == "" and "::" in subres_id:
		scn = _clean_scene_path(subres_id.get_slice("::", 0))
	if scn == "":
		scn = _last_scene_path
	scn = _clean_scene_path(scn)

	if scn != "" and u_id != "":
		candidates.append(scn + "::" + u_id)
	if u_id != "" and not candidates.has(u_id):
		candidates.append(u_id)

	for key in candidates:
		if _subres_id_to_resource.has(key):
			var wr = _subres_id_to_resource[key]
			if wr is WeakRef:
				var ref = wr.get_ref()
				if is_instance_valid(ref) and ref is Resource:
					return ref
			_subres_id_to_resource.erase(key)
	return null

func _update_existing_subresource(existing_res: Resource, value: Dictionary) -> bool:
	if not existing_res:
		return false
	var temp_res = _import_sub_resource(value)
	if not temp_res:
		return false
	if temp_res.get_class() != existing_res.get_class():
		return false

	var sub_id = value.get("sub_resource_id", "")
	var u_id = value.get("scene_unique_id", "")
	if u_id == "":
		u_id = _clean_unique_id(sub_id)
	if u_id != "":
		existing_res.set_scene_unique_id(u_id)

	for p in temp_res.get_property_list():
		if (p.usage & PROPERTY_USAGE_STORAGE) or (p.usage & PROPERTY_USAGE_EDITOR):
			if p.name == "resource_path" or p.name == "resource_name" or p.name == "script" or p.name.begins_with("metadata/"):
				continue
			var new_val = temp_res.get(p.name)
			var cur_val = existing_res.get(p.name)
			if typeof(new_val) != typeof(cur_val) or new_val != cur_val:
				existing_res.set(p.name, new_val)

	existing_res.emit_changed()
	return true

func _index_scene_subresources(node, scene_path: String = ""):
	if not is_instance_valid(node) or not (node is Node):
		return
	var scn = scene_path
	if scn == "":
		if node.scene_file_path != "":
			scn = node.scene_file_path
		elif node.has_meta("scene_file_path"):
			scn = node.get_meta("scene_file_path")
		else:
			scn = _last_scene_path
	scn = _clean_scene_path(scn)

	var visited = {}
	_index_object_resources_recursive(node, scn, visited)

func _index_object_resources_recursive(obj: Object, scene_path: String, visited: Dictionary):
	if not is_instance_valid(obj):
		return
	var obj_id = obj.get_instance_id()
	if visited.has(obj_id):
		return
	visited[obj_id] = true

	var props = obj.get_property_list()
	for p in props:
		if (p.usage & PROPERTY_USAGE_STORAGE) or (p.usage & PROPERTY_USAGE_EDITOR):
			if p.name.begins_with("metadata/"):
				continue
			var val = obj.get(p.name)
			if val is Resource:
				if _is_built_in_subresource(val):
					_get_or_create_subresource_id(val, scene_path)
					_index_object_resources_recursive(val, scene_path, visited)

	if obj is Node:
		for child in obj.get_children():
			_index_object_resources_recursive(child, scene_path, visited)

func export_sub_resource_dict(res: Resource, scene_path: String = "") -> Dictionary:
	if not res:
		return {}
	var subres_id = _get_or_create_subresource_id(res, scene_path)
	var temp_path = "user://tc_sync_export_" + str(res.get_instance_id()) + ".tres"
	ResourceSaver.save(res, temp_path)
	var bytes = PackedByteArray()
	var text = ""
	if FileAccess.file_exists(temp_path):
		bytes = FileAccess.get_file_as_bytes(temp_path)
		text = FileAccess.get_file_as_string(temp_path)
		DirAccess.remove_absolute(temp_path)
		if network and network.get("_dummy_path_to_original"):
			for dummy_p in network._dummy_path_to_original:
				if text.contains(dummy_p):
					text = text.replace(dummy_p, network._dummy_path_to_original[dummy_p])
	var rpath = res.resource_path
	if rpath.begins_with("user://"):
		rpath = ""
	var u_id = res.get_scene_unique_id()
	if u_id == "":
		u_id = _clean_unique_id(subres_id)
	return {
		"sub_resource_bytes": bytes,
		"sub_resource_text": text,
		"resource_path": rpath,
		"resource_instance_id": res.get_instance_id(),
		"sub_resource_id": subres_id,
		"scene_unique_id": u_id
	}

# ==============================================================================
# Per-User, Per-Scene Camera Persistence
# ==============================================================================

func _load_camera_cache():
	if FileAccess.file_exists(CAMERA_CACHE_FILE):
		var f = FileAccess.open(CAMERA_CACHE_FILE, FileAccess.READ)
		if f:
			var txt = f.get_as_text()
			f.close()
			var json = JSON.new()
			if json.parse(txt) == OK and typeof(json.data) == TYPE_DICTIONARY:
				_user_scene_cameras = json.data

func _save_camera_cache():
	if not _is_camera_dirty:
		return
	_is_camera_dirty = false
	var f = FileAccess.open(CAMERA_CACHE_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_user_scene_cameras, "\t"))
		f.close()

func save_current_camera_for_scene(scene_path: String, force: bool = false):
	if scene_path == "" or DisplayServer.get_name() == "headless" or (network and network.get("is_standalone_server")):
		return
	if not force and (_is_restoring_camera or _is_reloading_scene or _is_switching_scene_tab):
		return
	var cur_scn = _get_edited_scene_root()
	if not cur_scn or cur_scn.scene_file_path == "" or cur_scn.scene_file_path != scene_path:
		# Strict safety guard: only save camera if the requested scene is currently active in the editor!
		return
	var data = _get_local_cursor_data()
	if typeof(data) == TYPE_DICTIONARY and data.get("has_3d", false):
		var t: Transform3D = data.get("pos_3d", Transform3D())
		if not t.origin.is_finite() or not t.basis.is_finite():
			return
		_user_scene_cameras[scene_path] = {
			"has_3d": true,
			"origin": [t.origin.x, t.origin.y, t.origin.z],
			"basis_x": [t.basis.x.x, t.basis.x.y, t.basis.x.z],
			"basis_y": [t.basis.y.x, t.basis.y.y, t.basis.y.z],
			"basis_z": [t.basis.z.x, t.basis.z.y, t.basis.z.z]
		}
		_is_camera_dirty = true

func restore_camera_for_scene(scene_path: String):
	if scene_path == "" or not _user_scene_cameras.has(scene_path):
		return
	if DisplayServer.get_name() == "headless" or (network and network.get("is_standalone_server")):
		return

	var cam_data = _user_scene_cameras[scene_path]
	if not (typeof(cam_data) == TYPE_DICTIONARY and cam_data.get("has_3d", false)):
		return

	var o = cam_data.get("origin", [0, 0, 0])
	var bx = cam_data.get("basis_x", [1, 0, 0])
	var by = cam_data.get("basis_y", [0, 1, 0])
	var bz = cam_data.get("basis_z", [0, 0, 1])

	var origin = Vector3(o[0], o[1], o[2])
	var basis = Basis(
		Vector3(bx[0], bx[1], bx[2]),
		Vector3(by[0], by[1], by[2]),
		Vector3(bz[0], bz[1], bz[2])
	)
	var target_transform = Transform3D(basis, origin)

	var ei = _get_editor_interface()
	if not ei or not ei.has_method("get_editor_main_screen"):
		return
	var main_screen = ei.get_editor_main_screen()
	if not is_instance_valid(main_screen) or not main_screen.is_inside_tree():
		return

	if not is_instance_valid(_cached_3d_viewport) or not _cached_3d_viewport.is_inside_tree():
		_cached_3d_viewport = _find_editor_viewport(main_screen, "Node3DEditorViewport")
	if is_instance_valid(_cached_3d_viewport):
		if not is_instance_valid(_cached_3d_camera) or not _cached_3d_camera.is_inside_tree():
			_cached_3d_camera = _find_editor_camera_3d(_cached_3d_viewport)
		if is_instance_valid(_cached_3d_camera):
			_cached_3d_camera.global_transform = target_transform
			_local_3d_cursor_pos = target_transform

var _is_restoring_camera: bool = false
var _restore_camera_token: int = 0

func _defer_restore_camera(scene_path: String):
	if scene_path == "" or DisplayServer.get_name() == "headless" or (network and network.get("is_standalone_server")):
		return

	_restore_camera_token += 1
	var token = _restore_camera_token
	_is_restoring_camera = true

	if not _user_scene_cameras.has(scene_path):
		_load_camera_cache()
	if not _user_scene_cameras.has(scene_path):
		_is_restoring_camera = false
		return

	# Wait 2 process frames for scene hierarchy and viewports to mount
	await get_tree().process_frame
	await get_tree().process_frame
	if token != _restore_camera_token:
		return

	var cur_scn = _get_edited_scene_root()
	if cur_scn and cur_scn.scene_file_path == scene_path:
		restore_camera_for_scene(scene_path)

	# Re-apply after 0.15s to ensure Godot's internal viewport initialization does not override
	await get_tree().create_timer(0.15).timeout
	if token != _restore_camera_token:
		return

	cur_scn = _get_edited_scene_root()
	if cur_scn and cur_scn.scene_file_path == scene_path:
		restore_camera_for_scene(scene_path)

	# Final stabilization pass at 0.30s
	await get_tree().create_timer(0.15).timeout
	if token != _restore_camera_token:
		return

	cur_scn = _get_edited_scene_root()
	if cur_scn and cur_scn.scene_file_path == scene_path:
		restore_camera_for_scene(scene_path)

	if token == _restore_camera_token:
		_is_restoring_camera = false

func on_scene_closed(filepath: String):
	if filepath == "" or DisplayServer.get_name() == "headless":
		return
	_save_camera_cache()
	if _last_scene_path == filepath:
		_last_scene_path = ""
		_local_3d_cursor_pos = Transform3D()

func _exit_tree():
	var cur_scn = _get_edited_scene_root()
	if cur_scn and cur_scn.scene_file_path != "":
		save_current_camera_for_scene(cur_scn.scene_file_path, true)
	_save_camera_cache()
