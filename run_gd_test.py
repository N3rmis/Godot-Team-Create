import subprocess

with open('addons/team_create/test_compile.gd', 'w') as f:
    f.write('''extends SceneTree
func _init():
    var script = load("res://addons/team_create/file_sync.gd")
    if not script:
        print("compile error in file_sync")
    else:
        var obj = script.new()
        print("file_sync success")
    quit()
''')

import os
# Try to find a way to test GDScript compilation. Since godot is missing, what if it's named something else?
