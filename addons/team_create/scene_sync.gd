@tool
extends Node
# TODO: Evaluate replacing manual dictionary serialization with Godot's built-in MultiplayerSynchronizer

var network: Node
var _last_scene_path: String = ""
var _last_tracked_properties = {}
var _last_selected_ids = []
var _time_since_sync = 0.0

var _server_tracked_scenes = {}
var _server_save_timer = 0.0
var _failed_scene_loads = {}
const FAILED_LOAD_COOLDOWN = 2.0
var _failed_load_timers = {}

func _get_target_scene(scene_path: String) -> Node:
	var current_scene = null
	if network and network.plugin:
		current_scene = network.plugin.get_editor_interface().get_edited_scene_root()

	if network.get("is_standalone_server"):
		if scene_path == "":
			return current_scene

		if _server_tracked_scenes.has(scene_path):
			var s = _server_tracked_scenes[scene_path]
			if is_instance_valid(s):
				return s
			else:
				_server_tracked_scenes.erase(scene_path)

		if _failed_scene_loads.has(scene_path):
			return null

		if ResourceLoader.exists(scene_path):
			var packed = load(scene_path)
			if packed and packed is PackedScene:
				var instance = packed.instantiate()
				if instance:
					instance.set_meta("scene_file_path", scene_path)
					_server_tracked_scenes[scene_path] = instance
					get_tree().root.add_child(instance)
					return instance

			_failed_scene_loads[scene_path] = true
			_failed_load_timers[scene_path] = FAILED_LOAD_COOLDOWN
			printerr("Team Create: Failed to load scene or its dependencies (cooldown applied): ", scene_path)
		return null
	else:
		return current_scene

func _save_server_tracked_scenes():
	if not network.get("is_standalone_server"):
		return

	var cached_outlines = []
	var cached_cursors = []
	var tree = get_tree()
	if tree:
		cached_outlines = tree.get_nodes_in_group("TeamCreateSelectionOutlines")
		cached_cursors = tree.get_nodes_in_group("TeamCreateCursors")

	for path in _server_tracked_scenes:
		var scene_node = _server_tracked_scenes[path]
		if is_instance_valid(scene_node):
			# Temporarily remove outlines
			var outlines = []
			for node in cached_outlines:
				if is_instance_valid(node) and node.is_ancestor_of(scene_node):
					outlines.append({"node": node, "parent": node.get_parent()})
			for node in cached_cursors:
				if is_instance_valid(node) and node.is_ancestor_of(scene_node):
					outlines.append({"node": node, "parent": node.get_parent()})

			for data in outlines:
				data["parent"].remove_child(data["node"])

			var packed = PackedScene.new()
			if packed.pack(scene_node) == OK:
				ResourceSaver.save(packed, path)
				print("Server automatically saved tracked scene: ", path)

			for data in outlines:
				if is_instance_valid(data["parent"]) and is_instance_valid(data["node"]):
					data["parent"].add_child(data["node"])

const SYNC_INTERVAL = 0.1 # Sync 10 times a second max

# Tracking structure changes locally so we don't bounce events back and forth
var _ignore_next_structure_event = false
var _is_adding_outline = false
var _is_reloading_scene = false
var _pre_removal_paths = {}
var _node_names = {}
var _force_full_sync_next_frame = false
var _pending_resource_properties = []
var _receiving_scenes: Dictionary = {}
var _receiving_scene_states: Dictionary = {}
var _receiving_properties: Dictionary = {}

func _ready():
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

func _setup_undo_redo():
	if network and network.plugin:
		var undo_redo = network.plugin.get_undo_redo()
		if undo_redo:
			if not undo_redo.version_changed.is_connected(_on_undo_redo_version_changed):
				undo_redo.version_changed.connect(_on_undo_redo_version_changed)

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
	if multiplayer.has_multiplayer_peer() and not multiplayer.get_peers().is_empty():
		var current_scene = null
		if network and network.plugin:
			current_scene = network.plugin.get_editor_interface().get_edited_scene_root()

		var scene_path = ""
		if node.owner and node.owner.scene_file_path != "":
			scene_path = node.owner.scene_file_path
		elif node.scene_file_path != "":
			scene_path = node.scene_file_path
		elif current_scene:
			scene_path = current_scene.scene_file_path

		var root_node = node.owner if node.owner else current_scene
		if node == current_scene:
			root_node = node

		_pre_removal_paths[node.get_instance_id()] = {"id": network.assign_unique_id(node), "scene_path": scene_path, "root_node": root_node}

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

	if not network or not network.plugin or not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	_time_since_sync += delta
	if _time_since_sync >= SYNC_INTERVAL:
		_time_since_sync = 0.0
		_track_selection()
		_track_changes_throttled()
	_sync_cursor_throttled(delta)

	# Process pending resource properties (waiting for file sync)
	for i in range(_pending_resource_properties.size() - 1, -1, -1):
		var pending = _pending_resource_properties[i]
		if network and network.file_sync and pending.value in network.file_sync.downloading_files:
			continue
		if ResourceLoader.exists(pending.value):
			var current_scene = _get_target_scene(pending.scene_path)
			if current_scene and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) == pending.scene_path:
				var node = network.get_node_by_unique_id(current_scene, pending.id)
				if is_instance_valid(node):
					var res = load(pending.value)
					if res:
						node.set(pending.prop_name, res)
			_pending_resource_properties.remove_at(i)
		else:
			pending.retries -= 1
			if pending.retries <= 0:
				_pending_resource_properties.remove_at(i)

func _track_changes_throttled():
	var current_scene = null
	if network and network.plugin:
		current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
	if not current_scene:
		return

	if current_scene.scene_file_path != _last_scene_path:
		_last_scene_path = current_scene.scene_file_path
		_last_tracked_properties.clear()

		if _last_scene_path != "":
			rpc("request_scene_state", _last_scene_path)

	if _force_full_sync_next_frame:
		_force_full_sync_next_frame = false
		_check_all_nodes(current_scene, current_scene)
	else:
		# ONLY track changes for selected nodes to save massive performance costs
		var selected = network.plugin.get_editor_interface().get_selection().get_selected_nodes()
		for node in selected:
			_check_single_node_changes(node)

func _check_all_nodes(node: Node, scene_root: Node):
	if node.owner == scene_root or node == scene_root:
		_check_single_node_changes(node)
	for child in node.get_children():
		_check_all_nodes(child, scene_root)

func _check_single_node_changes(node: Node):
	var id = network.assign_unique_id(node)

	var props = node.get_property_list()
	var current_props = {}
	for p in props:
		# Filter for export or essential properties
		if p.usage & PROPERTY_USAGE_EDITOR or p.name == "transform" or p.name == "name":
			if p.name.begins_with("metadata/"):
				continue
			var val = node.get(p.name)
			if typeof(val) == TYPE_OBJECT:
				# For resources like Mesh or Material, sync the resource path if possible
				if val is Resource:
					if val.resource_path != "" and not "::" in val.resource_path:
						current_props[p.name] = val.resource_path
					else:
						# Serialize local sub-resources or resources without a file path
						var bytes = var_to_bytes_with_objects(val)
						current_props[p.name] = {"sub_resource_bytes": bytes, "resource_path": val.resource_path}
			else:
				current_props[p.name] = val

	if not _last_tracked_properties.has(id):
		_last_tracked_properties[id] = current_props
	else:
		var last_props = _last_tracked_properties[id]
		for prop_name in current_props:
			if not last_props.has(prop_name) or last_props[prop_name] != current_props[prop_name]:
				_send_update_node_property(id, prop_name, current_props[prop_name], _last_scene_path)
				last_props[prop_name] = current_props[prop_name]

func _track_selection():
	var editor = network.plugin.get_editor_interface()
	var selection = editor.get_selection().get_selected_nodes()
	var selected_ids = []
	for node in selection:
		var id = network.assign_unique_id(node)
		selected_ids.append(id)

	if selected_ids != _last_selected_ids:
		_last_selected_ids = selected_ids
		rpc("update_peer_selection", multiplayer.get_unique_id(), selected_ids, _last_scene_path)

@rpc("any_peer", "reliable")
func update_peer_selection(peer_id: int, selected_ids: Array, scene_path: String = ""):
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

	# If the peer is selecting nodes in a different scene, we don't draw new indicators here.
	if scene_path != "" and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) != scene_path:
		return

	# Add new indicators
	for id in selected_ids:
		var node = network.get_node_by_unique_id(current_scene, id)
		if node:
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

			elif node is Node2D or node is Control:
				var outline = ColorRect.new()
				outline.name = outline_name
				outline.set_meta("team_create_outline_peer", peer_id)
				outline.add_to_group(outline_group_name)
				outline.add_to_group("TeamCreateSelectionOutlines")
				outline.color = color
				outline.color.a = 0.5

				if node is Node2D:
					outline.size = Vector2(50, 50)
					outline.position = Vector2(-25, -25)
				else: # Control
					outline.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 0)
					outline.size = node.size

				# Ensure it doesn't block mouse
				outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
				_is_adding_outline = true
				if is_instance_valid(node) and node.is_inside_tree():
					node.add_child(outline)
				_is_adding_outline = false

func clear_peer_selections(peer_id: int):
	var outline_group_name = _get_selection_group_name(peer_id)
	var current_scene = null
	if network and network.plugin:
		current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
	if not current_scene:
		return

	var tree = current_scene.get_tree()
	if tree:
		for node in tree.get_nodes_in_group(outline_group_name):
			if is_instance_valid(node):
				node.queue_free()

func push_current_scene():
	if multiplayer.is_server():
		var editor = network.plugin.get_editor_interface()
		var current_scene = editor.get_edited_scene_root()
		if current_scene:
			var path = current_scene.scene_file_path
			if path != "":
				if FileAccess.file_exists(path):
					var bytes = FileAccess.get_file_as_bytes(path)
					var total_size = bytes.size()

					if total_size == 0:
						rpc("receive_scene", path, randi(), bytes, true)
						return

					if network and network.is_webrtc:
						var chunk_size = 60000
						var offset = 0
						var transfer_id = randi()
						while offset < total_size:
							var end_idx = min(offset + chunk_size, total_size)
							var chunk = bytes.slice(offset, end_idx)
							var is_final = (end_idx == total_size)
							rpc("receive_scene", path, transfer_id, chunk, is_final)
							offset += chunk_size
							if not is_final:
								await get_tree().process_frame
					else:
						rpc("receive_scene", path, randi(), bytes, true)

func push_specific_scene_to_peer(scene_path: String, id: int):
	if multiplayer.is_server():
		var editor = network.plugin.get_editor_interface()
		var current_scene = editor.get_edited_scene_root()

		if not network.get("is_standalone_server"):
			if current_scene and current_scene.scene_file_path == scene_path:
				push_current_scene_to_peer(id)
				return

		# This is called on the standalone server. We pack the tracked scene or read from file.
		if _server_tracked_scenes.has(scene_path):
			var scene_node = _server_tracked_scenes[scene_path]
			if is_instance_valid(scene_node):
				# Temporarily remove outlines
				var outlines = []
				var tree = scene_node.get_tree()
				if tree:
					for node in tree.get_nodes_in_group("TeamCreateSelectionOutlines"):
						if is_instance_valid(node) and node.is_ancestor_of(scene_node):
							outlines.append({"node": node, "parent": node.get_parent()})
					for node in tree.get_nodes_in_group("TeamCreateCursors"):
						if is_instance_valid(node) and node.is_ancestor_of(scene_node):
							outlines.append({"node": node, "parent": node.get_parent()})

				for data in outlines:
					data["parent"].remove_child(data["node"])

				var packed = PackedScene.new()
				if packed.pack(scene_node) == OK:
					var temp_path = "user://temp_scene_state_server_" + str(id) + ".tscn"
					if ResourceSaver.save(packed, temp_path) == OK:
						if FileAccess.file_exists(temp_path):
							var bytes = FileAccess.get_file_as_bytes(temp_path)
							_send_scene_bytes_to_peer(scene_path, bytes, id)
						DirAccess.remove_absolute(temp_path)

				for data in outlines:
					if is_instance_valid(data["parent"]) and is_instance_valid(data["node"]):
						data["parent"].add_child(data["node"])
				return

		# Fallback to disk
		if FileAccess.file_exists(scene_path):
			var bytes = FileAccess.get_file_as_bytes(scene_path)
			_send_scene_bytes_to_peer(scene_path, bytes, id)

func _send_scene_bytes_to_peer(path: String, bytes: PackedByteArray, id: int):
	var total_size = bytes.size()

	if total_size == 0:
		rpc_id(id, "receive_scene", path, randi(), bytes, true)
		return

	if network and network.is_webrtc:
		var chunk_size = 60000
		var offset = 0
		var transfer_id = randi()
		while offset < total_size:
			var end_idx = min(offset + chunk_size, total_size)
			var chunk = bytes.slice(offset, end_idx)
			var is_final = (end_idx == total_size)
			rpc_id(id, "receive_scene", path, transfer_id, chunk, is_final)
			offset += chunk_size
			if not is_final:
				await get_tree().process_frame
	else:
		rpc_id(id, "receive_scene", path, randi(), bytes, true)

func push_current_scene_to_peer(id: int):
	if multiplayer.is_server():
		var editor = network.plugin.get_editor_interface()
		var current_scene = editor.get_edited_scene_root()
		if current_scene:
			var path = current_scene.scene_file_path
			if path != "":
				if FileAccess.file_exists(path):
					var bytes = FileAccess.get_file_as_bytes(path)
					_send_scene_bytes_to_peer(path, bytes, id)

func _on_node_added(node: Node):
	# Connect for tracking before removal
	if not node.tree_exiting.is_connected(_on_node_tree_exiting.bind(node)):
		node.tree_exiting.connect(_on_node_tree_exiting.bind(node))

	_node_names[node.get_instance_id()] = node.name

	if _ignore_next_structure_event or _is_reloading_scene or not multiplayer.has_multiplayer_peer() or multiplayer.get_peers().is_empty():
		return

	# Capture owner state before the frame delay.
	# Nodes instantiated from a PackedScene (like during a scene reload or sub-scene drag-and-drop)
	# will already have their owner set. Nodes added manually via the editor GUI will have owner = null.
	var owner_at_add = node.owner

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
	if node.name.begins_with("@") or node.name.begins_with("TeamCreateSelectionOutline_") or node.name.begins_with("TeamCreateCursor"):
		return

	var current_scene = null
	if network and network.plugin:
		current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
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

	var parent_id = network.assign_unique_id(node.get_parent())
	var type = node.get_class()
	var new_name = node.name
	var new_id = network.assign_unique_id(node)

	_node_names[node.get_instance_id()] = new_name

	var scene_path = current_scene.scene_file_path
	rpc("remote_node_added", parent_id, type, new_name, new_id, scene_path)

	# Immediately sync properties of the new node to catch duplicates
	_sync_all_node_properties(node, new_id)

func _sync_all_node_properties(node: Node, id: String):
	# Create a temporary default instance to compare against
	var type = node.get_class()
	if not ClassDB.can_instantiate(type):
		return

	var default_node = ClassDB.instantiate(type)
	if not default_node:
		return

	var props = node.get_property_list()
	var current_props = {}

	for p in props:
		if p.usage & PROPERTY_USAGE_EDITOR or p.name == "transform" or p.name == "name":
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
						if val.resource_path != "" and not "::" in val.resource_path:
							current_props[p.name] = val.resource_path
						else:
							var bytes = var_to_bytes_with_objects(val)
							current_props[p.name] = {"sub_resource_bytes": bytes, "resource_path": val.resource_path}
				else:
					current_props[p.name] = val

	default_node.free()

	if not _last_tracked_properties.has(id):
		_last_tracked_properties[id] = current_props
	else:
		var last_props = _last_tracked_properties[id]
		for prop_name in current_props:
			last_props[prop_name] = current_props[prop_name]

	# Send all non-default properties
	for prop_name in current_props:
		_send_update_node_property(id, prop_name, current_props[prop_name], _last_scene_path)

func _on_node_removed(node: Node):
	var inst_id = node.get_instance_id()
	var pre_data = _pre_removal_paths.get(inst_id, {})
	var id = ""
	var scene_path = ""
	var root_node = null
	if typeof(pre_data) == TYPE_DICTIONARY:
		id = pre_data.get("id", "")
		scene_path = pre_data.get("scene_path", "")
		root_node = pre_data.get("root_node")
	elif typeof(pre_data) == TYPE_STRING:
		id = pre_data

	if _pre_removal_paths.has(inst_id):
		_pre_removal_paths.erase(inst_id)

	if _node_names.has(inst_id):
		_node_names.erase(inst_id)

	if id != "" and _last_tracked_properties.has(id):
		_last_tracked_properties.erase(id)

	if _ignore_next_structure_event or _is_reloading_scene or not multiplayer.has_multiplayer_peer() or multiplayer.get_peers().is_empty() or id == "":
		return

	if id == ".":
		return

	# Delay execution slightly to check if the scene root is also being destroyed
	# (which happens during scene reload/close)
	await get_tree().process_frame

	# If the root node that owned this node is no longer valid, the entire scene was closed or reloaded.
	# We should NOT broadcast individual node removals for a destroyed scene.
	if root_node != null and (not is_instance_valid(root_node) or not root_node.is_inside_tree()):
		return

	# Prevent sending removal if the user is just closing/switching scenes.
	if network and network.plugin:
		var current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
		if current_scene:
			var active_scene_path = current_scene.scene_file_path
			if scene_path != "" and active_scene_path != scene_path:
				return
		else:
			# If current_scene is null, they are closing the last scene tab.
			return

	rpc("remote_node_removed", id, scene_path)

func _on_node_renamed(node: Node):
	if _ignore_next_structure_event or _is_reloading_scene or not multiplayer.has_multiplayer_peer() or multiplayer.get_peers().is_empty():
		return

	var parent = node.get_parent()
	var inst_id = node.get_instance_id()
	if parent and _node_names.has(inst_id):
		var old_name = _node_names[inst_id]
		var new_name = node.name

		if old_name != new_name:
			_node_names[inst_id] = new_name
			var parent_id = network.assign_unique_id(parent)
			var scene_path = ""
			var current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
			if current_scene:
				scene_path = current_scene.scene_file_path
			rpc("remote_node_renamed_exact", parent_id, old_name, new_name, scene_path)

@rpc("any_peer", "reliable")
func remote_node_added(parent_id: String, type: String, new_name: String, new_id: String, scene_path: String = ""):
	_ignore_next_structure_event = true
	var current_scene = _get_target_scene(scene_path)
	if current_scene:
		if scene_path != "" and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) != scene_path:
			_ignore_next_structure_event = false
			return
		var parent = network.get_node_by_unique_id(current_scene, parent_id)
		if parent:
			# Prevent duplicates. If the exact node name already exists under the parent,
			# DO NOT instantiate a new one. This fundamentally prevents exponential rejoin floods.
			if not parent.has_node(new_name):
				var new_node = ClassDB.instantiate(type) as Node
				if new_node:
					new_node.name = new_name
					parent.add_child(new_node)
					new_node.owner = current_scene # Important for saving in scene
					_node_names[new_node.get_instance_id()] = new_name
	_ignore_next_structure_event = false

@rpc("any_peer", "reliable")
func remote_node_removed(id: String, scene_path: String = ""):
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
	_ignore_next_structure_event = false

@rpc("any_peer", "reliable")
func remote_node_renamed(new_id: String, new_name: String):
	# Kept for compatibility but superseded by remote_node_renamed_exact
	pass

@rpc("any_peer", "reliable")
func remote_node_renamed_exact(parent_id: String, old_name: String, new_name: String, scene_path: String = ""):
	_ignore_next_structure_event = true
	var current_scene = _get_target_scene(scene_path)
	if current_scene:
		if scene_path != "" and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) != scene_path:
			_ignore_next_structure_event = false
			return
		var parent = network.get_node_by_unique_id(current_scene, parent_id)
		if parent:
			var node = parent.get_node_or_null(old_name)
			if node:
				node.name = new_name
				_node_names[node.get_instance_id()] = new_name
	_ignore_next_structure_event = false

func _send_update_node_property(id: String, prop_name: String, value: Variant, scene_path: String = ""):
	var needs_chunking = false
	var bytes = PackedByteArray()

	# Always serialize to check size
	bytes = var_to_bytes_with_objects(value)
	if network and network.is_webrtc and bytes.size() > 60000:
		needs_chunking = true

	if needs_chunking:
		var chunk_size = 60000
		var total_size = bytes.size()
		var offset = 0
		var transfer_id = randi()

		if total_size == 0:
			rpc("update_node_property_chunked", id, prop_name, transfer_id, bytes, scene_path, true)
			return

		while offset < total_size:
			var end_idx = min(offset + chunk_size, total_size)
			var chunk = bytes.slice(offset, end_idx)
			var is_final = (end_idx == total_size)
			rpc("update_node_property_chunked", id, prop_name, transfer_id, chunk, scene_path, is_final)
			offset += chunk_size
	else:
		rpc("update_node_property", id, prop_name, value, scene_path)

@rpc("any_peer", "reliable")
func update_node_property_chunked(id: String, prop_name: String, transfer_id: int, chunk: PackedByteArray, scene_path: String = "", is_final: bool = true):
	var sender_id = multiplayer.get_remote_sender_id()
	var prop_key = str(sender_id) + "_" + id + "_" + prop_name + "_" + str(transfer_id)

	if not _receiving_properties.has(prop_key):
		_receiving_properties[prop_key] = PackedByteArray()

	_receiving_properties[prop_key].append_array(chunk)

	if is_final:
		var full_bytes = _receiving_properties[prop_key]
		_receiving_properties.erase(prop_key)

		var reassembled_value = bytes_to_var_with_objects(full_bytes)

		# Forward the reassembled value to the main property handler
		update_node_property(id, prop_name, reassembled_value, scene_path)

@rpc("any_peer", "reliable")
func update_node_property(id: String, prop_name: String, value: Variant, scene_path: String = ""):
	# Block metadata updates for security
	if prop_name.begins_with("metadata/"):
		printerr("Team Create: Blocked unsafe property sync: ", prop_name)
		return
	var current_scene = _get_target_scene(scene_path)
	if current_scene:
		if scene_path != "" and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) != scene_path:
			return
		var node = network.get_node_by_unique_id(current_scene, id)
		if node:
			if typeof(value) == TYPE_STRING and (value as String).begins_with("res://"):
				# Validate path to prevent directory traversal
				if ".." in (value as String):
					printerr("Team Create: Invalid resource path received: ", value)
					return

				# It's a resource path
				var is_downloading = network and network.file_sync and value in network.file_sync.downloading_files
				if not is_downloading and ResourceLoader.exists(value):
					var res = load(value)
					if res:
						node.set(prop_name, res)
				else:
					# Push to pending queue waiting for file sync to complete
					_pending_resource_properties.append({"id": id, "prop_name": prop_name, "value": value, "scene_path": scene_path, "retries": 100}) # About 1-2 seconds at 60 FPS
			elif typeof(value) == TYPE_DICTIONARY and value.has("sub_resource_bytes"):
				var res = bytes_to_var_with_objects(value["sub_resource_bytes"])
				if res is Resource:
					var path = value.get("resource_path", "")
					if path != "":
						var existing_res = null
						if ResourceLoader.has_cached(path):
							existing_res = load(path)

						if existing_res and existing_res.get_class() == res.get_class():
							# Copy properties to the existing shared resource
							var props = res.get_property_list()
							for p in props:
								var p_name = p.name
								if p.usage & PROPERTY_USAGE_STORAGE or p.usage & PROPERTY_USAGE_EDITOR:
									if p_name != "resource_path" and p_name != "resource_local_to_scene" and p_name != "resource_name":
										existing_res.set(p_name, res.get(p_name))
							res = existing_res
						else:
							res.take_over_path(path)

					node.set(prop_name, res)
			else:
				node.set(prop_name, value)

			if not _last_tracked_properties.has(id):
				_last_tracked_properties[id] = {}
			_last_tracked_properties[id][prop_name] = value

@rpc("any_peer", "reliable")
func receive_scene(path: String, transfer_id: int, bytes: PackedByteArray, is_final: bool = true):
	# Validate path to prevent directory traversal
	if path.begins_with("res://addons/team_create") or path.begins_with("res://.godot") or path.begins_with("res://webrtc"):
		printerr("Team Create: Unauthorized scene access: ", path)
		return
	if not path.begins_with("res://") or ".." in path:
		printerr("Invalid scene path received: ", path)
		return

	var sender_id = multiplayer.get_remote_sender_id()
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
				var file = FileAccess.open(path, FileAccess.WRITE)
				if file:
					file.store_buffer(bytes)
					file.close()

			if _server_tracked_scenes.has(path):
				var s = _server_tracked_scenes[path]
				if is_instance_valid(s):
					s.queue_free()
				_server_tracked_scenes.erase(path)
			var packed = load(path)
			if packed and packed is PackedScene:
				var instance = packed.instantiate()
				if instance:
					instance.set_meta("scene_file_path", path)
					_server_tracked_scenes[path] = instance
					get_tree().root.add_child(instance)
			return
		else:
			var editor = network.plugin.get_editor_interface()
			var current_scene = editor.get_edited_scene_root()
			var open_scenes = editor.get_open_scenes()

			var is_active = false
			if current_scene and current_scene.scene_file_path == path:
				is_active = true

			if is_active:
				# 1. Write to disk and force reload
				if bytes.size() > 0:
					var file = FileAccess.open(path, FileAccess.WRITE)
					if file:
						file.store_buffer(bytes)
						file.close()
				_is_reloading_scene = true
				_force_full_sync_next_frame = true

				editor.reload_scene_from_path(path)
				print("Team Create: Applying received scene to active view.")

				get_tree().create_timer(0.5).timeout.connect(func():
					_is_reloading_scene = false
				)
				return
			elif path in open_scenes:
				# 2. Scene is open in tabs but not active ("closed" in the context of currently viewing)
				# Switch to the tab, close it, and switch back
				var prev_path = current_scene.scene_file_path if current_scene else ""
				editor.open_scene_from_path(path)
				editor.close_scene()

				if prev_path != "":
					editor.open_scene_from_path(prev_path)

				print("Team Create: Closed updated background scene tab: ", path)

	if bytes.size() > 0:
		var file = FileAccess.open(path, FileAccess.WRITE)
		if file:
			file.store_buffer(bytes)
			file.close()
			print("Received scene: ", path)

@rpc("any_peer", "reliable")
func request_scene_state(scene_path: String):
	if scene_path == "":
		return

	var current_scene = _get_target_scene(scene_path)

	if current_scene and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) == scene_path:
		var sender_id = multiplayer.get_remote_sender_id()

		# Temporarily remove selection outlines so they aren't packed
		var outlines = []
		var tree = current_scene.get_tree()
		if tree:
			for node in tree.get_nodes_in_group("TeamCreateSelectionOutlines"):
				if is_instance_valid(node):
					outlines.append({"node": node, "parent": node.get_parent()})
			for node in tree.get_nodes_in_group("TeamCreateCursors"):
				if is_instance_valid(node):
					outlines.append({"node": node, "parent": node.get_parent()})

		for data in outlines:
			data["parent"].remove_child(data["node"])

		var packed = PackedScene.new()
		var err = packed.pack(current_scene)

		# Restore outlines
		for data in outlines:
			if is_instance_valid(data["parent"]) and is_instance_valid(data["node"]):
				data["parent"].add_child(data["node"])

		if err == OK:
			var temp_path = "user://temp_scene_state_" + str(multiplayer.get_unique_id()) + ".tscn"
			if ResourceSaver.save(packed, temp_path) == OK:
				if FileAccess.file_exists(temp_path):
					var bytes = FileAccess.get_file_as_bytes(temp_path)
					var total_size = bytes.size()

					if total_size == 0:
						rpc_id(sender_id, "receive_scene_state", scene_path, randi(), bytes, true)
						DirAccess.remove_absolute(temp_path)
						return

					if network and network.is_webrtc:
						var chunk_size = 60000
						var offset = 0
						var transfer_id = randi()
						while offset < total_size:
							var end_idx = min(offset + chunk_size, total_size)
							var chunk = bytes.slice(offset, end_idx)
							var is_final = (end_idx == total_size)
							rpc_id(sender_id, "receive_scene_state", scene_path, transfer_id, chunk, is_final)
							offset += chunk_size
							if not is_final:
								await get_tree().process_frame
					else:
						rpc_id(sender_id, "receive_scene_state", scene_path, randi(), bytes, true)
				DirAccess.remove_absolute(temp_path)

@rpc("any_peer", "reliable")
func receive_scene_state(path: String, transfer_id: int, bytes: PackedByteArray, is_final: bool = true):
	if path.begins_with("res://addons/team_create") or path.begins_with("res://.godot") or path.begins_with("res://webrtc"):
		printerr("Team Create: Unauthorized scene state access: ", path)
		return
	if not path.begins_with("res://") or ".." in path:
		printerr("Invalid scene state path received: ", path)
		return

	var sender_id = multiplayer.get_remote_sender_id()
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
		var file = FileAccess.open(path, FileAccess.WRITE)
		if file:
			file.store_buffer(bytes)
			file.close()
			print("Team Create: Received up-to-date scene state for ", path)

		if network and network.plugin:
			if network.get("is_standalone_server"):
				# Headless server just reloads the scene into memory
				if _server_tracked_scenes.has(path):
					var s = _server_tracked_scenes[path]
					if is_instance_valid(s):
						s.queue_free()
					_server_tracked_scenes.erase(path)

				var packed = load(path)
				if packed and packed is PackedScene:
					var instance = packed.instantiate()
					if instance:
						instance.set_meta("scene_file_path", path)
						_server_tracked_scenes[path] = instance
						get_tree().root.add_child(instance)
			else:
				var editor = network.plugin.get_editor_interface()
				var current_scene = editor.get_edited_scene_root()
				if current_scene and current_scene.scene_file_path == path:
					_is_reloading_scene = true
					editor.reload_scene_from_path(path)
					get_tree().create_timer(0.5).timeout.connect(func():
						_is_reloading_scene = false
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
var _local_3d_cursor_pos: Transform3D = Transform3D()
var _local_2d_cursor_pos: Vector2 = Vector2.ZERO
var _has_3d_cursor = false
var _has_2d_cursor = false

var _peer_cursors_3d = {}
var _peer_cursors_2d = {}


func _sync_cursor_throttled(delta):
	_last_cursor_sync += delta
	if _last_cursor_sync >= CURSOR_SYNC_INTERVAL:
		_last_cursor_sync = 0.0
		if multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			var data = _get_local_cursor_data()
			if data.has_3d:
				if data.pos_3d != _local_3d_cursor_pos:
					_local_3d_cursor_pos = data.pos_3d
					rpc("update_peer_cursor_3d", multiplayer.get_unique_id(), _local_3d_cursor_pos, _last_scene_path)
			elif data.has_2d:
				if data.pos_2d != _local_2d_cursor_pos:
					_local_2d_cursor_pos = data.pos_2d
					rpc("update_peer_cursor_2d", multiplayer.get_unique_id(), _local_2d_cursor_pos, _last_scene_path)


@rpc("any_peer", "unreliable")
func update_peer_cursor_3d(peer_id: int, pos: Transform3D, scene_path: String = ""):
	var current_scene = _get_target_scene(scene_path)
	if not current_scene or (scene_path != "" and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) != scene_path):
		_clear_peer_cursor(peer_id)
		return

	var tree = current_scene.get_tree()
	if not tree: return

	_clear_peer_cursor_2d(peer_id, current_scene)

	var cursor = _get_or_create_peer_cursor_3d(peer_id, current_scene)
	if cursor:
		cursor.global_transform = pos

@rpc("any_peer", "unreliable")
func update_peer_cursor_2d(peer_id: int, pos: Vector2, scene_path: String = ""):
	var current_scene = _get_target_scene(scene_path)
	if not current_scene or (scene_path != "" and current_scene.get_meta("scene_file_path", current_scene.scene_file_path) != scene_path):
		_clear_peer_cursor(peer_id)
		return

	var tree = current_scene.get_tree()
	if not tree: return

	_clear_peer_cursor_3d(peer_id, current_scene)

	var cursor = _get_or_create_peer_cursor_2d(peer_id, current_scene)
	if cursor:
		# Assuming pos is local to the canvas. In Godot 4 Editor, `event.position` from `_forward_canvas_gui_input` is
		# actually in canvas coordinates? Wait, it's typically canvas coordinates if you handle it correctly.
		# Let's set it to global_position of a Node2D
		cursor.position = pos

# TODO: Implement cursor object pooling instead of repeatedly instantiating/freeing cursor meshes
func _get_or_create_peer_cursor_3d(peer_id: int, current_scene: Node) -> Node3D:
	var group_name = _get_cursor_3d_group_name(peer_id)
	var cursor_name = _get_cursor_3d_group_name(peer_id)
	var nodes = current_scene.get_tree().get_nodes_in_group(group_name)
	if nodes.size() > 0 and is_instance_valid(nodes[0]):
		_peer_cursors_3d[peer_id] = nodes[0]
		return nodes[0]

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
	sphere_mesh.position.z = 0.45
	cursor.add_child(sphere_mesh)

	# The line/cylinder connecting the ball to the cone
	var stick_mesh = MeshInstance3D.new()
	var stick = CylinderMesh.new()
	stick.top_radius = 0.02
	stick.bottom_radius = 0.02
	stick.height = 0.2
	stick_mesh.mesh = stick
	stick_mesh.material_override = mat
	stick_mesh.position.z = 0.25
	stick_mesh.rotation.x = -PI / 2.0
	cursor.add_child(stick_mesh)

	# The pointer arrow (cone)
	var arrow_mesh = MeshInstance3D.new()
	var arrow = CylinderMesh.new()
	arrow.top_radius = 0.0
	arrow.bottom_radius = 0.08
	arrow.height = 0.15
	arrow_mesh.mesh = arrow
	arrow_mesh.material_override = mat
	arrow_mesh.position.z = 0.075
	arrow_mesh.rotation.x = -PI / 2.0
	cursor.add_child(arrow_mesh)

	# The name tag
	var label = Label3D.new()
	label.text = network.peers[peer_id].username if network.peers.has(peer_id) else "Peer " + str(peer_id)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.position.y = 0.25
	label.position.z = 0.45
	label.modulate = color
	cursor.add_child(label)

	current_scene.add_child(cursor)
	_peer_cursors_3d[peer_id] = cursor
	return cursor

func _get_or_create_peer_cursor_2d(peer_id: int, current_scene: Node) -> Node2D:
	var group_name = _get_cursor_2d_group_name(peer_id)
	var cursor_name = _get_cursor_2d_group_name(peer_id)
	var nodes = current_scene.get_tree().get_nodes_in_group(group_name)
	if nodes.size() > 0 and is_instance_valid(nodes[0]):
		_peer_cursors_2d[peer_id] = nodes[0]
		return nodes[0]

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
	current_scene.add_child(cursor)
	_peer_cursors_2d[peer_id] = cursor
	return cursor

func _clear_peer_cursor(peer_id: int):
	var current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
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
	var editor = network.plugin.get_editor_interface()
	var current_scene = editor.get_edited_scene_root()
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
	var current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
	if not current_scene: return
	var tree = current_scene.get_tree()
	if not tree: return
	var group_name = _get_cursor_3d_group_name(peer_id)
	var nodes = tree.get_nodes_in_group(group_name)
	for node in nodes:
		if is_instance_valid(node):
			for child in node.get_children():
				if child is Label3D:
					child.text = username

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
	var main_screen = network.plugin.get_editor_interface().get_editor_main_screen()
	if not is_instance_valid(main_screen) or not main_screen.is_inside_tree(): return result

	if not is_instance_valid(_cached_3d_viewport):
		_cached_3d_viewport = _find_editor_viewport(main_screen, "Node3DEditorViewport")
	if not is_instance_valid(_cached_2d_viewport):
		_cached_2d_viewport = _find_editor_viewport(main_screen, "CanvasItemEditorViewport")

	# Try 3D
	if is_instance_valid(_cached_3d_viewport) and _cached_3d_viewport.is_visible_in_tree():
		if not is_instance_valid(_cached_3d_camera):
			_cached_3d_camera = _find_editor_camera_3d(_cached_3d_viewport)

		var cam = _cached_3d_camera
		if is_instance_valid(cam):
			var viewport = cam.get_viewport()
			if viewport:
				# Use the camera's global transform for the 3D cursor
				result.has_3d = true
				result.pos_3d = cam.global_transform

	# Try 2D
	if is_instance_valid(_cached_2d_viewport) and _cached_2d_viewport.is_visible_in_tree():
		var mouse_pos = _cached_2d_viewport.get_local_mouse_position()
		var rect = Rect2(Vector2.ZERO, _cached_2d_viewport.size)
		if rect.has_point(mouse_pos):
			result.has_2d = true
			var current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
			if current_scene and current_scene is Node2D:
				result.pos_2d = current_scene.get_global_transform_with_canvas().affine_inverse() * mouse_pos
			elif current_scene and current_scene is Control:
				result.pos_2d = current_scene.get_global_transform_with_canvas().affine_inverse() * mouse_pos
			else:
				result.pos_2d = _cached_2d_viewport.get_global_mouse_position()

	return result
