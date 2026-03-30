import re

with open('addons/team_create/file_sync.gd', 'r') as f:
    text = f.read()

# Make sure all signals are properly typed if needed or not
# get_extension() is correct for Godot 4 String
# SceneTreeTimer was modified
# Make sure no other issues exist
