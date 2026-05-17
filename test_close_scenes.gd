@tool
extends EditorScript

func _run():
	var open_scenes = get_editor_interface().get_open_scenes()
	for path in open_scenes:
		get_editor_interface().open_scene_from_path(path)
		get_editor_interface().close_scene()
