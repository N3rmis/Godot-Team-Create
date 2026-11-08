@tool
extends Node

var network: Node
var _is_running_test: bool = false

func handle_test_command(args: PackedStringArray):
	if not network or not network.is_server:
		network.tc_print_rich("[color=red]The /test command can only be executed on the server/host.[/color]")
		return

	if args.size() < 2:
		network.tc_print_rich("[color=cyan]================================================================[/color]")
		network.tc_print_rich("[color=cyan]=== Server Automated Test Harness (/test) ===[/color]")
		network.tc_print_rich("[color=orange]Usage: /test <username> [suite_number: 1-6 or all][/color]")
		network.tc_print_rich("[color=white]Available Test Suites:[/color]")
		network.tc_print_rich("  [color=yellow]1[/color] - Node Spawning & Sub-Resource Sync (Spawns Red Box & Blue Sphere)")
		network.tc_print_rich("  [color=yellow]2[/color] - Real-time Transform & Property Animation (Smooth 3D orbit trajectory)")
		network.tc_print_rich("  [color=yellow]3[/color] - Hierarchy Mutation, Reparenting & Renaming (Parent-child hierarchy mutation)")
		network.tc_print_rich("  [color=yellow]4[/color] - Distributed Node Locking (Request lock, animate, release lock)")
		network.tc_print_rich("  [color=yellow]5[/color] - Virtual Collaborator Bot Simulation (Avatar cursor, selection outline, bot spawn)")
		network.tc_print_rich("  [color=yellow]6[/color] - Cleanup Test Objects (Removes all TeamCreate_Tests nodes)")
		network.tc_print_rich("  [color=yellow]all[/color] - Runs suites 1 through 5 sequentially")
		network.tc_print_rich("[color=cyan]================================================================[/color]")
		return

	if _is_running_test:
		network.tc_print_rich("[color=yellow]A test is already running. Please wait for it to finish.[/color]")
		return

	var target_str = args[1]
	var suite_arg = args[2] if args.size() > 2 else "1"

	var target_id = -1
	if target_str.is_valid_int():
		var pid = target_str.to_int()
		if network.peers.has(pid):
			target_id = pid
	if target_id == -1:
		for pid in network.peers.keys():
			if network.peers[pid].get("username", "") == target_str:
				target_id = pid
				break

	if target_id == -1:
		network.tc_print_rich("[color=red]Target user '" + target_str + "' not found. Type /list to see active users.[/color]")
		return

	var target_username = network.peers[target_id].get("username", "Peer " + str(target_id))
	var target_scene = network.peers[target_id].get("current_scene", "")

	if target_scene == "":
		if network.scene_sync and network.scene_sync._server_tracked_scenes.size() > 0:
			target_scene = network.scene_sync._server_tracked_scenes.keys()[0]
		else:
			target_scene = ProjectSettings.get_setting("application/run/main_scene", "")

	if target_scene == "":
		network.tc_print_rich("[color=red]Could not determine active scene for user '" + target_username + "'. Make sure the client has an active scene open.[/color]")
		return

	_is_running_test = true
	_run_server_test(target_id, target_username, target_scene, suite_arg)

func _run_server_test(target_id: int, target_username: String, target_scene: String, suite_arg: String):
	if not network or not network.scene_sync:
		network.tc_print_rich("[color=red]SceneSync module is not available.[/color]")
		_is_running_test = false
		return

	var scene_root = network.scene_sync._get_target_scene(target_scene)
	if not scene_root:
		network.tc_print_rich("[color=red]Failed to access or instantiate target scene: " + target_scene + "[/color]")
		_is_running_test = false
		return

	suite_arg = suite_arg.to_lower()
	if suite_arg == "all":
		await _test_suite_1_spawns(target_id, target_username, target_scene, scene_root)
		await get_tree().create_timer(1.0).timeout
		await _test_suite_2_animation(target_id, target_username, target_scene, scene_root)
		await get_tree().create_timer(1.0).timeout
		await _test_suite_3_hierarchy(target_id, target_username, target_scene, scene_root)
		await get_tree().create_timer(1.0).timeout
		await _test_suite_4_locking(target_id, target_username, target_scene, scene_root)
		await get_tree().create_timer(1.0).timeout
		await _test_suite_5_collaborator(target_id, target_username, target_scene, scene_root)
		network.tc_print_rich("[color=green]=== All Test Suites (1-5) Completed Successfully ===[/color]")
	elif suite_arg == "1":
		await _test_suite_1_spawns(target_id, target_username, target_scene, scene_root)
	elif suite_arg == "2":
		await _test_suite_2_animation(target_id, target_username, target_scene, scene_root)
	elif suite_arg == "3":
		await _test_suite_3_hierarchy(target_id, target_username, target_scene, scene_root)
	elif suite_arg == "4":
		await _test_suite_4_locking(target_id, target_username, target_scene, scene_root)
	elif suite_arg == "5":
		await _test_suite_5_collaborator(target_id, target_username, target_scene, scene_root)
	elif suite_arg == "6":
		await _test_suite_6_cleanup(target_id, target_username, target_scene, scene_root)
	else:
		network.tc_print_rich("[color=red]Invalid test suite '" + suite_arg + "'. Valid options: 1, 2, 3, 4, 5, 6, all[/color]")

	_is_running_test = false

func _get_or_create_test_container(target_scene: String, scene_root: Node) -> Node:
	var container = scene_root.get_node_or_null("TeamCreate_Tests")
	if not container:
		var parent_id = "."
		var new_name = "TeamCreate_Tests"
		var new_id = "TeamCreate_Tests"
		var type = "Node3D" if scene_root is Node3D else "Node"
		network.scene_sync.remote_node_added(parent_id, type, new_name, new_id, target_scene, "")
		network.scene_sync.rpc("remote_node_added", parent_id, type, new_name, new_id, target_scene, "")
		container = scene_root.get_node_or_null("TeamCreate_Tests")
	return container

func _test_suite_1_spawns(target_id: int, target_username: String, target_scene: String, scene_root: Node):
	network.tc_print_rich("[color=cyan]================================================================[/color]")
	network.tc_print_rich("[color=cyan]=== Running Test Suite 1: Node Spawning & Sub-Resource Sync ===[/color]")
	network.tc_print_rich("[color=white]Target User:[/color] " + target_username + " (ID: " + str(target_id) + ")")
	network.tc_print_rich("[color=white]Target Scene:[/color] " + target_scene)
	network.tc_print_rich("[color=white]Actions Executed:[/color]")

	var container = _get_or_create_test_container(target_scene, scene_root)
	if not container:
		network.tc_print_rich("[color=red]  Failed to create 'TeamCreate_Tests' container node.[/color]")
		return
	network.tc_print_rich("  [color=yellow]1.[/color] Created/verified 'TeamCreate_Tests' container node")

	var box_id = "TeamCreate_Tests/TestBox_Red"
	if not scene_root.get_node_or_null(box_id):
		network.scene_sync.remote_node_added("TeamCreate_Tests", "MeshInstance3D", "TestBox_Red", box_id, target_scene, "")
		network.scene_sync.rpc("remote_node_added", "TeamCreate_Tests", "MeshInstance3D", "TestBox_Red", box_id, target_scene, "")

		var box_xf = Transform3D(Basis(), Vector3(-2, 1, 0))
		network.scene_sync.update_node_property(box_id, "transform", box_xf, target_scene)
		network.scene_sync._send_update_node_property(box_id, "transform", box_xf, target_scene)

		var bmesh = BoxMesh.new()
		var mesh_dict = network.scene_sync.export_sub_resource_dict(bmesh)
		network.scene_sync.update_node_property(box_id, "mesh", mesh_dict, target_scene)
		network.scene_sync._send_update_node_property(box_id, "mesh", mesh_dict, target_scene)

		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.9, 0.2, 0.2)
		var mat_dict = network.scene_sync.export_sub_resource_dict(mat)
		network.scene_sync.update_node_property(box_id, "material_override", mat_dict, target_scene)
		network.scene_sync._send_update_node_property(box_id, "material_override", mat_dict, target_scene)

		network.tc_print_rich("  [color=yellow]2.[/color] Spawned MeshInstance3D 'TestBox_Red' with BoxMesh and Red StandardMaterial3D at (-2, 1, 0)")
	else:
		network.tc_print_rich("  [color=yellow]2.[/color] 'TestBox_Red' already exists in scene")

	var sphere_id = "TeamCreate_Tests/TestSphere_Blue"
	if not scene_root.get_node_or_null(sphere_id):
		network.scene_sync.remote_node_added("TeamCreate_Tests", "MeshInstance3D", "TestSphere_Blue", sphere_id, target_scene, "")
		network.scene_sync.rpc("remote_node_added", "TeamCreate_Tests", "MeshInstance3D", "TestSphere_Blue", sphere_id, target_scene, "")

		var sphere_xf = Transform3D(Basis(), Vector3(2, 1, 0))
		network.scene_sync.update_node_property(sphere_id, "transform", sphere_xf, target_scene)
		network.scene_sync._send_update_node_property(sphere_id, "transform", sphere_xf, target_scene)

		var smesh = SphereMesh.new()
		smesh.radius = 0.6
		smesh.height = 1.2
		var smesh_dict = network.scene_sync.export_sub_resource_dict(smesh)
		network.scene_sync.update_node_property(sphere_id, "mesh", smesh_dict, target_scene)
		network.scene_sync._send_update_node_property(sphere_id, "mesh", smesh_dict, target_scene)

		var mat_blue = StandardMaterial3D.new()
		mat_blue.albedo_color = Color(0.2, 0.4, 0.9)
		var mat_blue_dict = network.scene_sync.export_sub_resource_dict(mat_blue)
		network.scene_sync.update_node_property(sphere_id, "material_override", mat_blue_dict, target_scene)
		network.scene_sync._send_update_node_property(sphere_id, "material_override", mat_blue_dict, target_scene)

		network.tc_print_rich("  [color=yellow]3.[/color] Spawned MeshInstance3D 'TestSphere_Blue' with SphereMesh and Blue StandardMaterial3D at (2, 1, 0)")
	else:
		network.tc_print_rich("  [color=yellow]3.[/color] 'TestSphere_Blue' already exists in scene")

	network.tc_print_rich("[color=yellow]Expected Client Behavior:[/color]")
	network.tc_print_rich("  -> Client 3D editor viewport immediately renders Red Cube on left and Blue Sphere on right.")
	network.tc_print_rich("  -> Client Scene Tree dock shows 'TeamCreate_Tests' with 'TestBox_Red' and 'TestSphere_Blue'.")
	network.tc_print_rich("  -> No scene reload or tab close occurred.")
	network.tc_print_rich("[color=green]Test Suite 1 Completed Successfully.[/color]")
	network.tc_print_rich("[color=cyan]================================================================[/color]")

func _test_suite_2_animation(target_id: int, target_username: String, target_scene: String, scene_root: Node):
	network.tc_print_rich("[color=cyan]================================================================[/color]")
	network.tc_print_rich("[color=cyan]=== Running Test Suite 2: Real-time Property & Transform Animation ===[/color]")
	network.tc_print_rich("[color=white]Target User:[/color] " + target_username + " (ID: " + str(target_id) + ")")
	network.tc_print_rich("[color=white]Target Scene:[/color] " + target_scene)

	_get_or_create_test_container(target_scene, scene_root)
	var box_id = "TeamCreate_Tests/TestBox_Red"
	var sphere_id = "TeamCreate_Tests/TestSphere_Blue"
	if not scene_root.get_node_or_null(box_id) or not scene_root.get_node_or_null(sphere_id):
		network.tc_print_rich("  Prerequisite test objects missing. Spawning them first...")
		await _test_suite_1_spawns(target_id, target_username, target_scene, scene_root)

	network.tc_print_rich("[color=white]Actions Executed:[/color]")
	network.tc_print_rich("  [color=yellow]1.[/color] Starting 3.0-second orbit animation for 'TestBox_Red' and 'TestSphere_Blue' (30 frames at 10 Hz)")

	var total_frames = 30
	var interval = 0.1
	for frame in range(total_frames):
		var t = float(frame) / float(total_frames) * TAU
		var radius = 2.5

		var box_pos = Vector3(cos(t) * radius, 1.0 + sin(t * 2.0) * 0.5, sin(t) * radius)
		var box_rot = Basis().rotated(Vector3.UP, t).rotated(Vector3.RIGHT, t * 0.5)
		var box_xf = Transform3D(box_rot, box_pos)
		network.scene_sync.update_node_property(box_id, "transform", box_xf, target_scene)
		network.scene_sync._send_update_node_property(box_id, "transform", box_xf, target_scene)

		var sphere_pos = Vector3(cos(t + PI) * radius, 1.0 - sin(t * 2.0) * 0.5, sin(t + PI) * radius)
		var sphere_xf = Transform3D(Basis(), sphere_pos)
		network.scene_sync.update_node_property(sphere_id, "transform", sphere_xf, target_scene)
		network.scene_sync._send_update_node_property(sphere_id, "transform", sphere_xf, target_scene)

		await get_tree().create_timer(interval).timeout

	var rest_box = Transform3D(Basis(), Vector3(-2, 1, 0))
	var rest_sphere = Transform3D(Basis(), Vector3(2, 1, 0))
	network.scene_sync.update_node_property(box_id, "transform", rest_box, target_scene)
	network.scene_sync._send_update_node_property(box_id, "transform", rest_box, target_scene)
	network.scene_sync.update_node_property(sphere_id, "transform", rest_sphere, target_scene)
	network.scene_sync._send_update_node_property(sphere_id, "transform", rest_sphere, target_scene)

	network.tc_print_rich("  [color=yellow]2.[/color] Broadcast 30 continuous Transform3D property updates")
	network.tc_print_rich("  [color=yellow]3.[/color] Reset nodes to resting positions (-2, 1, 0) and (2, 1, 0)")
	network.tc_print_rich("[color=yellow]Expected Client Behavior:[/color]")
	network.tc_print_rich("  -> In client 3D editor viewport, the Red Box and Blue Sphere smoothly revolve around each other.")
	network.tc_print_rich("  -> Client Node Inspector transform values update live in real-time.")
	network.tc_print_rich("[color=green]Test Suite 2 Completed Successfully.[/color]")
	network.tc_print_rich("[color=cyan]================================================================[/color]")

func _test_suite_3_hierarchy(target_id: int, target_username: String, target_scene: String, scene_root: Node):
	network.tc_print_rich("[color=cyan]================================================================[/color]")
	network.tc_print_rich("[color=cyan]=== Running Test Suite 3: Hierarchy Mutation, Reparenting & Renaming ===[/color]")
	network.tc_print_rich("[color=white]Target User:[/color] " + target_username + " (ID: " + str(target_id) + ")")
	network.tc_print_rich("[color=white]Target Scene:[/color] " + target_scene)

	_get_or_create_test_container(target_scene, scene_root)
	var box_id = "TeamCreate_Tests/TestBox_Red"
	var sphere_id = "TeamCreate_Tests/TestSphere_Blue"
	if not scene_root.get_node_or_null(box_id) or not scene_root.get_node_or_null(sphere_id):
		await _test_suite_1_spawns(target_id, target_username, target_scene, scene_root)

	network.tc_print_rich("[color=white]Actions Executed:[/color]")

	var child_name = "TestMarker"
	var child_id = "TeamCreate_Tests/TestBox_Red/" + child_name
	if not scene_root.get_node_or_null(child_id):
		network.scene_sync.remote_node_added(box_id, "Node3D", child_name, child_id, target_scene, "")
		network.scene_sync.rpc("remote_node_added", box_id, "Node3D", child_name, child_id, target_scene, "")
		network.tc_print_rich("  [color=yellow]1.[/color] Spawned child node 'TestMarker' under 'TestBox_Red'")

	await get_tree().create_timer(1.0).timeout

	var renamed_name = "TestSatellite"
	network.scene_sync.remote_node_renamed_exact(box_id, child_name, renamed_name, target_scene)
	network.scene_sync.rpc("remote_node_renamed_exact", box_id, child_name, renamed_name, target_scene)
	network.tc_print_rich("  [color=yellow]2.[/color] Renamed node 'TestMarker' -> 'TestSatellite' via remote_node_renamed_exact")

	await get_tree().create_timer(1.0).timeout

	var old_full_id = "TeamCreate_Tests/TestBox_Red/" + renamed_name
	network.scene_sync.remote_node_reparented(old_full_id, sphere_id, 0, target_scene)
	network.scene_sync.rpc("remote_node_reparented", old_full_id, sphere_id, 0, target_scene)
	network.tc_print_rich("  [color=yellow]3.[/color] Reparented 'TestSatellite' from 'TestBox_Red' to 'TestSphere_Blue' via remote_node_reparented")

	network.tc_print_rich("[color=yellow]Expected Client Behavior:[/color]")
	network.tc_print_rich("  -> Client Scene Tree shows 'TestMarker' created under 'TestBox_Red'.")
	network.tc_print_rich("  -> 'TestMarker' dynamically renames to 'TestSatellite'.")
	network.tc_print_rich("  -> 'TestSatellite' moves seamlessly under 'TestSphere_Blue' without reloading or losing state.")
	network.tc_print_rich("[color=green]Test Suite 3 Completed Successfully.[/color]")
	network.tc_print_rich("[color=cyan]================================================================[/color]")

func _test_suite_4_locking(target_id: int, target_username: String, target_scene: String, scene_root: Node):
	network.tc_print_rich("[color=cyan]================================================================[/color]")
	network.tc_print_rich("[color=cyan]=== Running Test Suite 4: Distributed Node Locking ===[/color]")
	network.tc_print_rich("[color=white]Target User:[/color] " + target_username + " (ID: " + str(target_id) + ")")
	network.tc_print_rich("[color=white]Target Scene:[/color] " + target_scene)

	_get_or_create_test_container(target_scene, scene_root)
	var box_id = "TeamCreate_Tests/TestBox_Red"
	if not scene_root.get_node_or_null(box_id):
		await _test_suite_1_spawns(target_id, target_username, target_scene, scene_root)

	network.tc_print_rich("[color=white]Actions Executed:[/color]")

	network.node_locks[box_id] = 1
	network.rpc("sync_node_lock", box_id, 1, target_scene)
	network.sync_node_lock(box_id, 1, target_scene)
	network.tc_print_rich("  [color=yellow]1.[/color] Server acquired lock on '" + box_id + "' and broadcast sync_node_lock")

	network.tc_print_rich("  [color=yellow]2.[/color] Holding lock for 2.0 seconds while modifying position (elevating to Y=2.5)")
	var elevated_xf = Transform3D(Basis(), Vector3(-2, 2.5, 0))
	network.scene_sync.update_node_property(box_id, "transform", elevated_xf, target_scene)
	network.scene_sync._send_update_node_property(box_id, "transform", elevated_xf, target_scene)

	await get_tree().create_timer(2.0).timeout

	var rest_xf = Transform3D(Basis(), Vector3(-2, 1, 0))
	network.scene_sync.update_node_property(box_id, "transform", rest_xf, target_scene)
	network.scene_sync._send_update_node_property(box_id, "transform", rest_xf, target_scene)

	if network.node_locks.has(box_id):
		network.node_locks.erase(box_id)
	network.rpc("sync_node_unlock", box_id, target_scene)
	network.sync_node_unlock(box_id, target_scene)
	network.tc_print_rich("  [color=yellow]3.[/color] Released lock and broadcast sync_node_unlock")

	network.tc_print_rich("[color=yellow]Expected Client Behavior:[/color]")
	network.tc_print_rich("  -> Client was prevented from transforming 'TestBox_Red' while server held the lock.")
	network.tc_print_rich("  -> Lock released cleanly; client can now freely select and transform 'TestBox_Red'.")
	network.tc_print_rich("[color=green]Test Suite 4 Completed Successfully.[/color]")
	network.tc_print_rich("[color=cyan]================================================================[/color]")

func _test_suite_5_collaborator(target_id: int, target_username: String, target_scene: String, scene_root: Node):
	network.tc_print_rich("[color=cyan]================================================================[/color]")
	network.tc_print_rich("[color=cyan]=== Running Test Suite 5: Virtual Collaborator Bot Simulation ===[/color]")
	network.tc_print_rich("[color=white]Target User:[/color] " + target_username + " (ID: " + str(target_id) + ")")
	network.tc_print_rich("[color=white]Target Scene:[/color] " + target_scene)

	_get_or_create_test_container(target_scene, scene_root)
	var box_id = "TeamCreate_Tests/TestBox_Red"
	if not scene_root.get_node_or_null(box_id):
		await _test_suite_1_spawns(target_id, target_username, target_scene, scene_root)

	network.tc_print_rich("[color=white]Actions Executed:[/color]")

	var bot_id = 99999
	var bot_info = {
		"username": "TC_Bot_Sim",
		"color": Color(1.0, 0.2, 0.8)
	}
	network.peers[bot_id] = bot_info
	network.rpc("sync_peer_info", bot_id, bot_info)
	network.tc_print_rich("  [color=yellow]1.[/color] Registered virtual collaborator 'TC_Bot_Sim' (ID: 99999, Color: Magenta)")

	network.tc_print_rich("  [color=yellow]2.[/color] Moving 3D collaborator avatar cursor towards 'TestBox_Red'")
	var steps = 10
	for i in range(steps):
		var frac = float(i) / float(steps)
		var cam_pos = Vector3(lerp(6.0, -1.0, frac), lerp(4.0, 1.8, frac), lerp(6.0, 1.5, frac))
		var cam_xf = Transform3D(Basis(), cam_pos).looking_at(Vector3(-2, 1, 0), Vector3.UP)
		network.scene_sync.rpc("update_peer_cursor_3d", bot_id, cam_xf, target_scene)
		await get_tree().create_timer(0.15).timeout

	network.tc_print_rich("  [color=yellow]3.[/color] Bot selected 'TestBox_Red' (Selection outline triggered)")
	network.scene_sync.rpc("update_peer_selection", bot_id, [box_id], target_scene)

	await get_tree().create_timer(1.2).timeout

	var bot_prism_id = "TeamCreate_Tests/TestBot_Prism"
	if not scene_root.get_node_or_null(bot_prism_id):
		network.scene_sync.remote_node_added("TeamCreate_Tests", "MeshInstance3D", "TestBot_Prism", bot_prism_id, target_scene, "")
		network.scene_sync.rpc("remote_node_added", "TeamCreate_Tests", "MeshInstance3D", "TestBot_Prism", bot_prism_id, target_scene, "")

		var prism_xf = Transform3D(Basis(), Vector3(0, 1.5, 0))
		network.scene_sync.update_node_property(bot_prism_id, "transform", prism_xf, target_scene)
		network.scene_sync._send_update_node_property(bot_prism_id, "transform", prism_xf, target_scene)

		var cmesh = CylinderMesh.new()
		cmesh.top_radius = 0.0
		cmesh.bottom_radius = 0.5
		cmesh.height = 1.0
		var cmesh_dict = network.scene_sync.export_sub_resource_dict(cmesh)
		network.scene_sync.update_node_property(bot_prism_id, "mesh", cmesh_dict, target_scene)
		network.scene_sync._send_update_node_property(bot_prism_id, "mesh", cmesh_dict, target_scene)

		var pmat = StandardMaterial3D.new()
		pmat.albedo_color = Color(1.0, 0.84, 0.0)
		var pmat_dict = network.scene_sync.export_sub_resource_dict(pmat)
		network.scene_sync.update_node_property(bot_prism_id, "material_override", pmat_dict, target_scene)
		network.scene_sync._send_update_node_property(bot_prism_id, "material_override", pmat_dict, target_scene)
		network.tc_print_rich("  [color=yellow]4.[/color] Bot spawned MeshInstance3D 'TestBot_Prism' (Golden Cone) at (0, 1.5, 0)")

	await get_tree().create_timer(1.0).timeout

	network.tc_print_rich("  [color=yellow]5.[/color] Bot cleared selection and flew away")
	network.scene_sync.rpc("update_peer_selection", bot_id, [], target_scene)

	for i in range(5):
		var frac = float(i) / 5.0
		var cam_pos = Vector3(lerp(-1.0, -8.0, frac), lerp(1.8, 6.0, frac), lerp(1.5, -8.0, frac))
		var cam_xf = Transform3D(Basis(), cam_pos)
		network.scene_sync.rpc("update_peer_cursor_3d", bot_id, cam_xf, target_scene)
		await get_tree().create_timer(0.1).timeout

	network.scene_sync.rpc("update_peer_cursor_3d", bot_id, Transform3D(), "")
	network.peers.erase(bot_id)

	network.tc_print_rich("[color=yellow]Expected Client Behavior:[/color]")
	network.tc_print_rich("  -> Client sees 'TC_Bot_Sim' 3D cursor avatar (magenta sphere + pointer cone) fly into scene.")
	network.tc_print_rich("  -> Client sees selection outline appear around 'TestBox_Red'.")
	network.tc_print_rich("  -> 'TestBot_Prism' (golden cone) is spawned into the scene at (0, 1.5, 0).")
	network.tc_print_rich("  -> Bot releases selection, flies away, and leaves session.")
	network.tc_print_rich("[color=green]Test Suite 5 Completed Successfully.[/color]")
	network.tc_print_rich("[color=cyan]================================================================[/color]")

func _test_suite_6_cleanup(target_id: int, target_username: String, target_scene: String, scene_root: Node):
	network.tc_print_rich("[color=cyan]================================================================[/color]")
	network.tc_print_rich("[color=cyan]=== Running Test Suite 6: Cleanup Test Objects ===[/color]")
	network.tc_print_rich("[color=white]Target User:[/color] " + target_username + " (ID: " + str(target_id) + ")")
	network.tc_print_rich("[color=white]Target Scene:[/color] " + target_scene)

	var container_id = "TeamCreate_Tests"
	var container = scene_root.get_node_or_null(container_id)
	if container:
		network.scene_sync.remote_node_removed(container_id, target_scene)
		network.scene_sync.rpc("remote_node_removed", container_id, target_scene)
		network.tc_print_rich("  [color=yellow]1.[/color] Broadcast remote_node_removed for 'TeamCreate_Tests'")
	else:
		network.tc_print_rich("  [color=yellow]1.[/color] 'TeamCreate_Tests' container not found (already clean)")

	network.scene_sync.rpc("update_peer_selection", 99999, [], target_scene)
	network.scene_sync.rpc("update_peer_cursor_3d", 99999, Transform3D(), "")
	if network.peers.has(99999):
		network.peers.erase(99999)

	network.tc_print_rich("[color=yellow]Expected Client Behavior:[/color]")
	network.tc_print_rich("  -> All test objects ('TeamCreate_Tests', box, sphere, prism) removed from scene tree and viewport.")
	network.tc_print_rich("  -> Client scene restored to its clean pre-test state.")
	network.tc_print_rich("[color=green]Test Suite 6 Completed Successfully.[/color]")
	network.tc_print_rich("[color=cyan]================================================================[/color]")
