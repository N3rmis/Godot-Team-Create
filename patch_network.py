import re

with open('addons/team_create/network.gd', 'r') as f:
    content = f.read()

content = content.replace("""	var scene_sync_script = load("res://addons/team_create/scene_sync.gd")
	if scene_sync_script:""", """	var scene_sync_script = load("res://addons/team_create/scene_sync.gd")
	if scene_sync_script:""")

with open('addons/team_create/network.gd', 'w') as f:
    f.write(content)
