extends SceneTree

func _init():
	var file_sync_script = load("res://addons/team_create/file_sync.gd")
	if not file_sync_script:
		print("Failed to load file_sync.gd")
	else:
		var fs = file_sync_script.new()
		print("Successfully instantiated file_sync.gd")
	quit()
