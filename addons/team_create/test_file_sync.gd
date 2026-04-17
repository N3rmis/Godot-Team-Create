extends SceneTree

# Test script for addons/team_create/file_sync.gd get_all_files logic
# Run with: godot -s addons/team_create/test_file_sync.gd

func _init():
	var FileSync = load("res://addons/team_create/file_sync.gd")
	if not FileSync:
		printerr("FAILED: Could not load file_sync.gd")
		quit(1)
		return

	var file_sync = FileSync.new()
	# Mock dependencies
	file_sync.plugin = Node.new()

	print("--- Testing get_all_files ---")

	# Create a mock directory structure in user:// to avoid modifying project files
	var test_base_dir = "user://test_file_sync"

	if DirAccess.dir_exists_absolute(test_base_dir):
		# Clean up any previous test state
		_cleanup_dir(test_base_dir)

	DirAccess.make_dir_absolute(test_base_dir)

	# Create standard files and directories
	var file = FileAccess.open(test_base_dir + "/file1.txt", FileAccess.WRITE)
	file.store_string("test")
	file.close()

	DirAccess.make_dir_absolute(test_base_dir + "/dir1")
	file = FileAccess.open(test_base_dir + "/dir1/file2.txt", FileAccess.WRITE)
	file.store_string("test")
	file.close()

	# Create an excluded directory structure
	DirAccess.make_dir_absolute(test_base_dir + "/excluded_dir")
	file = FileAccess.open(test_base_dir + "/excluded_dir/file3.txt", FileAccess.WRITE)
	file.store_string("test")
	file.close()

	DirAccess.make_dir_absolute(test_base_dir + "/excluded_dir/sub_excluded")
	file = FileAccess.open(test_base_dir + "/excluded_dir/sub_excluded/file4.txt", FileAccess.WRITE)
	file.store_string("test")
	file.close()

	# Create a hidden directory structure
	DirAccess.make_dir_absolute(test_base_dir + "/.hidden_dir")
	file = FileAccess.open(test_base_dir + "/.hidden_dir/file5.txt", FileAccess.WRITE)
	file.store_string("test")
	file.close()

	# Create a hidden file
	file = FileAccess.open(test_base_dir + "/.hidden_file.txt", FileAccess.WRITE)
	file.store_string("test")
	file.close()

	# --- Test standard and exclusion logic ---
	# Here, exclude "user://test_file_sync/excluded_dir"
	var result = file_sync.get_all_files(test_base_dir, [test_base_dir + "/excluded_dir"])

	var expected_files = [
		test_base_dir + "/file1.txt",
		test_base_dir + "/dir1/file2.txt"
	]

	var all_expected_found = true
	for expected in expected_files:
		if not expected in result:
			all_expected_found = false
			printerr("FAILED: Expected file missing: ", expected)
			break

	var unexpected_files_found = false
	var unexpected_files = [
		test_base_dir + "/excluded_dir/file3.txt",
		test_base_dir + "/excluded_dir/sub_excluded/file4.txt",
		test_base_dir + "/.hidden_dir/file5.txt",
		test_base_dir + "/.hidden_file.txt"
	]

	for unexpected in unexpected_files:
		if unexpected in result:
			unexpected_files_found = true
			printerr("FAILED: Found unexpected file: ", unexpected)
			break

	if all_expected_found and not unexpected_files_found and result.size() == expected_files.size():
		print("SUCCESS: get_all_files correctly includes/excludes files")
	else:
		printerr("FAILED: get_all_files did not return expected results")
		printerr("Expected: ", expected_files)
		printerr("Got: ", result)
		_cleanup_dir(test_base_dir)
		quit(1)
		return

	# Test edge case: excluded dir is deeply nested
	DirAccess.make_dir_absolute(test_base_dir + "/dir1/nested_excluded")
	file = FileAccess.open(test_base_dir + "/dir1/nested_excluded/file6.txt", FileAccess.WRITE)
	file.store_string("test")
	file.close()

	result = file_sync.get_all_files(test_base_dir, [test_base_dir + "/excluded_dir", test_base_dir + "/dir1/nested_excluded"])
	if test_base_dir + "/dir1/nested_excluded/file6.txt" in result:
		printerr("FAILED: Failed to exclude deeply nested dir")
		_cleanup_dir(test_base_dir)
		quit(1)
		return
	else:
		print("SUCCESS: Deeply nested excluded dir was correctly skipped")

	# Test edge case: default exclusion list contains res://.godot and res://webrtc
	# Create these manually to see if they are skipped when default parameters are used
	var res_test_dir = "user://res_test_file_sync"
	if DirAccess.dir_exists_absolute(res_test_dir):
		_cleanup_dir(res_test_dir)
	DirAccess.make_dir_absolute(res_test_dir)

	DirAccess.make_dir_absolute(res_test_dir + "/.godot")
	file = FileAccess.open(res_test_dir + "/.godot/file.txt", FileAccess.WRITE)
	file.store_string("test")
	file.close()

	DirAccess.make_dir_absolute(res_test_dir + "/webrtc")
	file = FileAccess.open(res_test_dir + "/webrtc/file.txt", FileAccess.WRITE)
	file.store_string("test")
	file.close()

	DirAccess.make_dir_absolute(res_test_dir + "/normal_dir")
	file = FileAccess.open(res_test_dir + "/normal_dir/file.txt", FileAccess.WRITE)
	file.store_string("test")
	file.close()

	result = file_sync.get_all_files(res_test_dir, [res_test_dir + "/.godot", res_test_dir + "/webrtc"])

	if res_test_dir + "/.godot/file.txt" in result or res_test_dir + "/webrtc/file.txt" in result:
		printerr("FAILED: Default exclusion behavior did not work correctly")
		_cleanup_dir(test_base_dir)
		_cleanup_dir(res_test_dir)
		quit(1)
		return
	elif res_test_dir + "/normal_dir/file.txt" not in result:
		printerr("FAILED: Normal directory was not included")
		_cleanup_dir(test_base_dir)
		_cleanup_dir(res_test_dir)
		quit(1)
		return
	else:
		print("SUCCESS: Exclusion of default-like paths was correctly executed")

	# Cleanup
	_cleanup_dir(test_base_dir)
	_cleanup_dir(res_test_dir)
	print("--- All tests passed! ---")
	quit(0)

func _cleanup_dir(dir_path: String):
	var dir = DirAccess.open(dir_path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name != "." and file_name != "..":
				var full_path = dir_path + "/" + file_name
				if dir.current_is_dir():
					_cleanup_dir(full_path)
				else:
					DirAccess.remove_absolute(full_path)
			file_name = dir.get_next()
		DirAccess.remove_absolute(dir_path)
