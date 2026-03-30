import re

with open('addons/team_create/file_sync.gd', 'r') as f:
    content = f.read()

# I see `var _scan_timer: SceneTreeTimer` which in Godot 4 might cause issues if SceneTreeTimer is not accessible or if it needs to be initialized. Actually, SceneTreeTimer is a valid class but you cannot construct it, only get it from get_tree().create_timer(). Let's change the type to `var _scan_timer` or `var _scan_timer = null`

content = content.replace('var _scan_timer: SceneTreeTimer', 'var _scan_timer = null')

with open('addons/team_create/file_sync.gd', 'w') as f:
    f.write(content)
