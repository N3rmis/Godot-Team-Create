@tool
extends Node

## Team Create - Scene Check
## Edits travel one at a time, so one that goes missing leaves an editor different for good. Once a scene
## has gone quiet, each editor compares its copy with the server's. A difference has to last through two
## checks to count, since the other one could just be an edit on its way.
##
## The server's copy wins for properties, child order and nodes the editor is missing. A node only the
## editor has is removed only if the server knows it once had that node. Otherwise it's sent out, because
## it may be the only copy of someone's work. The same goes for a resource in a slot the server has empty.
##
## Only properties that sync live are compared. The rest travel when a scene is saved, so a difference
## there can be an unsaved edit that overwriting would lose.

const QUIET_TIME: float = 3.0
const CONFIRM_TIME: float = 2.0
const PERIODIC_TIME: float = 30.0
const REPLY_TIMEOUT: float = 15.0
const POLL_INTERVAL: float = 0.5
const MAX_REPAIRS: int = 2 # Something like a tool script can keep changing a value back, so stop trying
const ORDER_KEY = "_tc_child_order"

var network: Node

# Editor
var _path: String = ""
var _map: Dictionary = {}
var _nonce: int = 0
var _waiting: bool = false
var _sent_at: float = 0.0
var _changed_at: float = 0.0
var _checked_at: float = 0.0
var _due: bool = false
var _last_difference: int = 0
var _repairs: Dictionary = {} # "id|property" -> times repaired
var _poll_timer: float = 0.0

var repairs_made: int = 0

# Server
var _known_ids: Dictionary = {} # scene path -> every node id its copy has been seen to have

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _process(delta):
	_poll_timer -= delta
	if _poll_timer > 0.0:
		return
	_poll_timer = POLL_INTERVAL
	if not network or network.is_server or not network.is_connected_to_session() or not network.scene_sync:
		return
	var scene_sync = network.scene_sync
	var root = scene_sync._get_edited_scene_root()
	if not root or root.scene_file_path == "":
		_path = ""
		return
	var now = _now()
	if root.scene_file_path != _path:
		_path = root.scene_file_path
		_repairs.clear()
		note_change(_path)
	if _waiting and now - _sent_at < REPLY_TIMEOUT:
		return
	_waiting = false
	if scene_sync._is_reloading_scene or not scene_sync._remote_moves.is_empty():
		_changed_at = now
		return
	if now - _changed_at < QUIET_TIME:
		return
	if _due or now - _checked_at >= PERIODIC_TIME:
		_send_check(root)

# Any reply on its way is out of date now too
func note_change(path: String):
	if path != _path:
		return
	_changed_at = _now()
	_due = true
	_waiting = false
	_nonce += 1
	_last_difference = 0

func reset():
	_path = ""
	_map.clear()
	_waiting = false
	_repairs.clear()
	_known_ids.clear()

func _send_check(root: Node):
	_nonce += 1
	_waiting = true
	_due = false
	_sent_at = _now()
	_checked_at = _sent_at
	_map = _node_hashes(root)
	rpc_id(1, "check_scene", _path, _nonce, _hash_of_map(_map))

# ==============================================================================
# What gets compared
# ==============================================================================

func _owned_nodes(node: Node, root: Node, out: Array = []) -> Array:
	if node == root or node.owner == root:
		out.append(node)
	for child in node.get_children():
		_owned_nodes(child, root, out)
	return out

func _owned_child_names(node: Node, root: Node) -> Array:
	var names = []
	for child in node.get_children():
		if child.owner == root:
			names.append(str(child.name))
	return names

func _is_compared(node: Node, p: Dictionary) -> bool:
	if not p.usage & PROPERTY_USAGE_STORAGE or p.name == "name" or p.name == "script" or p.name.begins_with("metadata/"):
		return false
	if not network.scene_sync._is_synced_node_property(node, p):
		return false
	# Layout only settles in the tree, and the server's copy isn't in one
	if node is Control and (p.name.begins_with("anchor") or p.name.begins_with("offset_")):
		return false
	# Editors keep these as paths, while a server that has loaded the script has nothing to point them at
	if p.hint == PROPERTY_HINT_NODE_TYPE or (p.type == TYPE_ARRAY and ":Node" in str(p.hint_string)):
		return false
	return true

func _text_of(value: Variant) -> String:
	match typeof(value):
		TYPE_OBJECT:
			if value is Resource:
				var path = value.resource_path
				if network.get("_dummy_path_to_original") and network._dummy_path_to_original.has(path):
					path = network._dummy_path_to_original[path]
				# Built-in resources sync separately, and the server can't always rebuild them exactly
				return path if path != "" and not "::" in path else value.get_class()
			return ""
		TYPE_ARRAY:
			return "[" + ",".join(value.map(_text_of)) + "]"
		TYPE_DICTIONARY:
			var parts = []
			for key in value:
				parts.append(_text_of(key) + ":" + _text_of(value[key]))
			parts.sort()
			return "{" + ",".join(parts) + "}"
	return str(value)

func _node_state(node: Node, root: Node) -> Dictionary:
	var state = {}
	for p in node.get_property_list():
		if _is_compared(node, p):
			state[p.name] = _text_of(node.get(p.name)).hash()
	state[ORDER_KEY] = hash(_owned_child_names(node, root))
	if node is AnimationMixer:
		state.merge(network.scene_sync.animation_prints(node, root.get_meta("scene_file_path", root.scene_file_path)))
	return state

func _hash_of_state(state: Dictionary) -> int:
	var keys = state.keys()
	keys.sort()
	var values = []
	for key in keys:
		values.append(key)
		values.append(state[key])
	return hash(values)

func _node_hashes(root: Node) -> Dictionary:
	var map = {}
	for node in _owned_nodes(root, root):
		map[network.assign_unique_id(node)] = _hash_of_state(_node_state(node, root))
	return map

func _hash_of_map(map: Dictionary) -> int:
	var keys = map.keys()
	keys.sort()
	var values = []
	for key in keys:
		values.append(key)
		values.append(map[key])
	return hash(values)

# ==============================================================================
# Server
# ==============================================================================

# The server only loads a scene once someone edits it, and until then there's nothing to have gone wrong.
# A copy that couldn't load everything can't say what's right.
func _server_copy(path: String, sender_id: int) -> Node:
	if not network or not network.get("is_standalone_server") or not network.peers.has(sender_id) or not network.scene_sync:
		return null
	if network.scene_sync._incomplete_server_scenes.has(path):
		return null
	var root = network.scene_sync._server_tracked_scenes.get(path)
	return root if is_instance_valid(root) else null

func _server_hashes(path: String, root: Node) -> Dictionary:
	var map = _node_hashes(root)
	if not _known_ids.has(path):
		_known_ids[path] = {}
	_known_ids[path].merge(map)
	return map

@rpc("any_peer", "reliable")
func check_scene(path: String, nonce: int, scene_hash: int):
	var sender_id = multiplayer.get_remote_sender_id()
	var root = _server_copy(path, sender_id)
	if not root:
		rpc_id(sender_id, "scene_matches", path, nonce)
		return
	if _hash_of_map(_server_hashes(path, root)) == scene_hash:
		rpc_id(sender_id, "scene_matches", path, nonce)
	else:
		rpc_id(sender_id, "scene_differs", path, nonce)

@rpc("any_peer", "reliable")
func compare_scene(path: String, nonce: int, their_map: Dictionary):
	var sender_id = multiplayer.get_remote_sender_id()
	var root = _server_copy(path, sender_id)
	if not root:
		rpc_id(sender_id, "scene_matches", path, nonce)
		return
	var map = _server_hashes(path, root)
	var missing = []
	var states = {}
	var orders = {}
	for id in map:
		if not their_map.has(id):
			missing.append(id)
		elif their_map[id] != map[id]:
			var node = network.get_node_by_unique_id(root, id)
			states[id] = _node_state(node, root)
			orders[id] = _owned_child_names(node, root)
	var gone = []
	var unknown = []
	for id in their_map:
		if id is String and not map.has(id):
			if _known_ids[path].has(id):
				gone.append(id)
			else:
				unknown.append(id)
	rpc_id(sender_id, "scene_differences", path, nonce, missing, gone, unknown, states, orders)

@rpc("any_peer", "reliable")
func request_scene_copy(path: String, nonce: int):
	var sender_id = multiplayer.get_remote_sender_id()
	if not _server_copy(path, sender_id):
		return
	network.scene_sync._save_server_tracked_scenes()
	rpc_id(sender_id, "receive_scene_copy", path, nonce, FileAccess.get_file_as_bytes(path))

# ==============================================================================
# Editor: acting on the answer
# ==============================================================================

var _pending_missing: Array = []
var _pending_changes: Array = []
var _pending_orders: Dictionary = {}

func _from_server_about_current(path: String, nonce: int) -> bool:
	return multiplayer.get_remote_sender_id() == 1 and path == _path and nonce == _nonce

@rpc("authority", "reliable")
func scene_matches(path: String, nonce: int):
	if _from_server_about_current(path, nonce):
		_waiting = false
		_last_difference = 0
		_repairs.clear()

@rpc("authority", "reliable")
func scene_differs(path: String, nonce: int):
	if _from_server_about_current(path, nonce):
		_sent_at = _now()
		rpc_id(1, "compare_scene", path, nonce, _map)

func _may_repair(key: String) -> bool:
	return _repairs.get(key, 0) < MAX_REPAIRS

@rpc("authority", "reliable")
func scene_differences(path: String, nonce: int, missing: Array, gone: Array, unknown: Array, states: Dictionary, orders: Dictionary):
	if not _from_server_about_current(path, nonce):
		return
	_waiting = false
	var root = network.scene_sync._get_edited_scene_root()
	if not root or root.scene_file_path != path:
		return

	var changes = []
	var only_here = []
	var new_orders = {}
	for id in states:
		var node = network.get_node_by_unique_id(root, id)
		if not node or not states[id] is Dictionary:
			continue
		var mine = _node_state(node, root)
		for key in states[id]:
			if key is String and mine.has(key) and mine[key] != states[id][key] and _may_repair(id + "|" + key):
				if key == ORDER_KEY:
					new_orders[id] = orders.get(id, [])
				elif states[id][key] in [_text_of(null).hash(), "".hash()] and node.get(key) is Resource:
					only_here.append([id, key])
				else:
					changes.append([id, key])
			elif key is String and key.begins_with(network.scene_sync.ANIMATION_KEY) and not mine.has(key) and _may_repair(id + "|" + key):
				changes.append([id, key])
		for key in mine:
			if key.begins_with(network.scene_sync.ANIMATION_KEY) and not states[id].has(key) and _may_repair(id + "|" + key):
				only_here.append([id, key])
	missing = missing.filter(func(id): return id is String and _may_repair(id + "|"))
	gone = gone.filter(func(id): return id is String and _may_repair(id + "|"))
	unknown = unknown.filter(func(id): return id is String and _may_repair(id + "|"))

	if missing.is_empty() and gone.is_empty() and unknown.is_empty() and changes.is_empty() and only_here.is_empty() and new_orders.is_empty():
		_last_difference = 0
		return
	var difference = hash([missing, gone, unknown, changes, only_here, new_orders])
	if difference != _last_difference:
		# Could just be an edit on its way, so look again shortly
		_last_difference = difference
		_due = true
		_changed_at = _now() - QUIET_TIME + CONFIRM_TIME
		return

	_last_difference = 0
	var count = _send_unknown_nodes(root, path, unknown) + _remove_gone_nodes(path, gone) + _send_only_here(root, path, only_here)
	if not missing.is_empty() or not changes.is_empty() or not new_orders.is_empty():
		_pending_missing = missing
		_pending_changes = changes
		_pending_orders = new_orders
		_waiting = true
		_sent_at = _now()
		rpc_id(1, "request_scene_copy", path, _nonce)
	if count > 0:
		_report(path, count)

func _report(path: String, count: int):
	repairs_made += count
	var noun = "difference" if count == 1 else "differences"
	network.tc_print("Team Create: Found and fixed %d %s from the server in %s" % [count, noun, path.get_file()])

func _send_unknown_nodes(root: Node, path: String, ids: Array) -> int:
	# Parents first, and a child of one already going out still needs its own message
	ids.sort_custom(func(a, b): return a.count("/") < b.count("/"))
	var count = 0
	for id in ids:
		_repairs[id + "|"] = _repairs.get(id + "|", 0) + 1
		var node = network.get_node_by_unique_id(root, id)
		if node and node != root:
			network.scene_sync.send_node_again(node, path)
			count += 1
	return count

func _send_only_here(root: Node, path: String, properties: Array) -> int:
	for property in properties:
		_repairs[property[0] + "|" + property[1]] = _repairs.get(property[0] + "|" + property[1], 0) + 1
		network.scene_sync.send_resource_again(network.get_node_by_unique_id(root, property[0]), property[0], property[1], path)
	return properties.size()

func _remove_gone_nodes(path: String, ids: Array) -> int:
	# Deepest first, so a parent going doesn't take a child it would then look for
	ids.sort_custom(func(a, b): return a.count("/") > b.count("/"))
	for id in ids:
		_repairs[id + "|"] = _repairs.get(id + "|", 0) + 1
		network.scene_sync.remote_node_removed(id, path)
	return ids.size()

@rpc("authority", "reliable")
func receive_scene_copy(path: String, nonce: int, bytes: PackedByteArray):
	if not _from_server_about_current(path, nonce):
		return
	_waiting = false
	var scene_sync = network.scene_sync
	var root = scene_sync._get_edited_scene_root()
	if not root or root.scene_file_path != path:
		return
	var source_root = scene_sync._instantiate_scene_bytes(path, bytes)
	if not source_root:
		return

	var count = 0
	var was_applying = scene_sync._is_applying_remote_update
	scene_sync._is_applying_remote_update = true

	_pending_missing.sort_custom(func(a, b): return a.count("/") < b.count("/"))
	for id in _pending_missing:
		_repairs[id + "|"] = _repairs.get(id + "|", 0) + 1
		if _add_node_from_copy(id, root, source_root):
			count += 1

	for change in _pending_changes:
		_repairs[change[0] + "|" + change[1]] = _repairs.get(change[0] + "|" + change[1], 0) + 1
		var node = network.get_node_by_unique_id(root, change[0])
		var source = network.get_node_by_unique_id(source_root, change[0])
		if node and source:
			if change[1].begins_with(scene_sync.ANIMATION_KEY):
				scene_sync.copy_animation(node, source, change[1], path)
			else:
				node.set(change[1], source.get(change[1]))
			scene_sync._last_tracked_properties.erase(change[0])
			count += 1

	for id in _pending_orders:
		_repairs[id + "|" + ORDER_KEY] = _repairs.get(id + "|" + ORDER_KEY, 0) + 1
		var node = network.get_node_by_unique_id(root, id)
		if node and _pending_orders[id] is Array:
			_apply_child_order(node, _pending_orders[id])
			count += 1

	scene_sync._is_applying_remote_update = was_applying
	source_root.free()
	_pending_missing = []
	_pending_changes = []
	_pending_orders = {}
	if count > 0:
		_report(path, count)
		scene_sync.mark_scene_dirty(path)

func _add_node_from_copy(id: String, root: Node, source_root: Node) -> bool:
	if network.get_node_by_unique_id(root, id):
		return false # Arrived along with its parent
	var source = network.get_node_by_unique_id(source_root, id)
	var parent = network.get_node_by_unique_id(root, id.get_base_dir() if "/" in id else ".")
	if not source or not parent or source == source_root:
		return false
	var owned = _owned_nodes(source, source_root)
	for node in owned:
		node.owner = null
	source.get_parent().remove_child(source)
	parent.add_child(source)
	for node in owned:
		node.owner = root
	return true

func _apply_child_order(parent: Node, names: Array):
	var children = []
	var slots = []
	for child in parent.get_children():
		if str(child.name) in names:
			children.append(child)
			slots.append(child.get_index())
	var i = 0
	for child_name in names:
		var child = parent.get_node_or_null(NodePath(str(child_name)))
		if child and child in children and i < slots.size():
			parent.move_child(child, slots[i])
			i += 1
