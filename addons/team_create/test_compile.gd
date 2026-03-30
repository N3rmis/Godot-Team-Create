extends SceneTree
func _init():
    var script = load("res://addons/team_create/file_sync.gd")
    if not script:
        print("compile error in file_sync")
    else:
        var obj = script.new()
        print("file_sync success")
    quit()
