extends SceneTree

# Test script for addons/team_create/network.gd user info generation logic
# Run with: godot -s addons/team_create/test_network.gd

func _init():
	var Network = load("res://addons/team_create/network.gd")
	if not Network:
		printerr("FAILED: Could not load network.gd")
		quit(1)
		return

	var network = Network.new()
	# Mock dependencies
	network.plugin = Node.new()

	print("--- Testing _generate_peer_info ---")

	# Test determinism: same seed, same initial state
	network._assigned_colors = []
	network._color_assignment_counter = 0
	var info1 = network._generate_peer_info(12345)

	network._assigned_colors = []
	network._color_assignment_counter = 0
	var info2 = network._generate_peer_info(12345)

	if info1.username == info2.username and info1.color == info2.color:
		print("SUCCESS: Deterministic for same ID and state")
	else:
		printerr("FAILED: Non-deterministic for same ID and state")
		printerr("  info1: ", info1)
		printerr("  info2: ", info2)
		quit(1)
		return

	# Test color assignment logic (first 4)
	network._assigned_colors = []
	network._color_assignment_counter = 0

	var colors = []
	var expected_colors = [Color.BLUE, Color.GREEN, Color.RED, Color.PURPLE]
	for i in range(4):
		var info = network._generate_peer_info(i + 100)
		colors.append(info.color)

	var all_match = true
	for c in colors:
		if not c in expected_colors:
			all_match = false
			break

	if all_match and colors.size() == 4:
		# Verify they are unique
		var unique_colors = []
		for c in colors:
			if not c in unique_colors:
				unique_colors.append(c)
		if unique_colors.size() == 4:
			print("SUCCESS: First 4 peers got unique initial colors")
		else:
			printerr("FAILED: Initial colors not unique: ", colors)
			quit(1)
			return
	else:
		printerr("FAILED: Initial colors not assigned correctly")
		printerr("  Got: ", colors)
		quit(1)
		return

	# Test after 4 peers (should generate a random color from HSV)
	# For peer 5, it should be random but deterministic if seed is the same.
	network._color_assignment_counter = 4
	var info5_a = network._generate_peer_info(500)

	network._color_assignment_counter = 4
	var info5_b = network._generate_peer_info(500)

	if info5_a.color == info5_b.color and info5_a.color != null:
		print("SUCCESS: 5th peer got a deterministic random color")
	else:
		printerr("FAILED: 5th peer random color issue")
		printerr("  info5_a: ", info5_a)
		printerr("  info5_b: ", info5_b)
		quit(1)
		return

	# Test standalone server case
	network.is_standalone_server = true
	var server_info = network._generate_peer_info(1)
	if server_info.username == "Server" and server_info.get("is_standalone") == true:
		print("SUCCESS: Standalone server info generated correctly")
	else:
		printerr("FAILED: Standalone server info mismatch")
		printerr("  Got: ", server_info)
		quit(1)
		return

	print("--- Testing _get_default_peer_info ---")
	var default_info1 = network._get_default_peer_info(999)
	var default_info2 = network._get_default_peer_info(999)

	if default_info1.username == default_info2.username and default_info1.color == default_info2.color:
		print("SUCCESS: Default peer info is deterministic")
	else:
		printerr("FAILED: Default peer info non-deterministic")
		quit(1)
		return

	print("--- All tests passed! ---")
	quit(0)
