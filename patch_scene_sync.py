import re

with open('addons/team_create/scene_sync.gd', 'r') as f:
    content = f.read()

# Fix 1: _track_changes_throttled()
#   var current_scene = _get_target_scene(scene_path)  ->  var current_scene = null
#                                                       if network and network.plugin:
#                                                           current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
content = content.replace(
    'func _track_changes_throttled():\n\tvar current_scene = _get_target_scene(scene_path)',
    'func _track_changes_throttled():\n\tvar current_scene = null\n\tif network and network.plugin:\n\t\tcurrent_scene = network.plugin.get_editor_interface().get_edited_scene_root()'
)

# Fix 2: selected = editor.get_selection().get_selected_nodes() -> selected = network.plugin.get_editor_interface().get_selection().get_selected_nodes()
content = content.replace(
    'var selected = editor.get_selection().get_selected_nodes()',
    'var selected = network.plugin.get_editor_interface().get_selection().get_selected_nodes()'
)

# Fix 3: clear_peer_selections(peer_id: int)
#   var current_scene = _get_target_scene(scene_path) -> var current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
content = content.replace(
    'func clear_peer_selections(peer_id: int):\n\tvar current_scene = _get_target_scene(scene_path)',
    'func clear_peer_selections(peer_id: int):\n\tvar current_scene = null\n\tif network and network.plugin:\n\t\tcurrent_scene = network.plugin.get_editor_interface().get_edited_scene_root()'
)

# Fix 4: _on_node_added(node: Node)
#   var current_scene = _get_target_scene(scene_path) -> var current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
content = content.replace(
    'func _on_node_added(node: Node):',
    'func _on_node_added(node: Node):'
)

# Need a careful replacement for _on_node_added
# It has:
#   var current_scene = _get_target_scene(scene_path)
#   if not current_scene:
#       return
import sys
content = content.replace(
"""	var current_scene = _get_target_scene(scene_path)
	if not current_scene:
		return

	# Never sync the root scene node itself""",
"""	var current_scene = null
	if network and network.plugin:
		current_scene = network.plugin.get_editor_interface().get_edited_scene_root()
	if not current_scene:
		return

	# Never sync the root scene node itself"""
)

with open('addons/team_create/scene_sync.gd', 'w') as f:
    f.write(content)
