@tool
extends Node

## Team Create - Deploy to Website
## Anyone in a session can ask a dedicated server to publish the project. The plugin only passes
## that request to a script the server's owner runs outside the container, and can't choose what
## it does. See tools/site_deploy.sh. Without TEAM_CREATE_DEPLOY_DIR set, there's no button.

const DIR_ENV_VAR = "TEAM_CREATE_DEPLOY_DIR"
const POLL_INTERVAL: float = 1.0
const PICKUP_TIMEOUT: float = 15.0 # How long the script gets to notice a request
const RUN_TIMEOUT: float = 1800.0  # Longer than its own export and import limits combined

var network: Node

# Server
var _dir: String = ""
var _request_id: String = ""
var _picked_up: bool = false
var _poll_timer: float = 0.0
var _elapsed: float = 0.0

var available: bool = false
var running: bool = false
var message: String = ""

func _ready():
	if network and network.get("is_standalone_server"):
		_dir = OS.get_environment(DIR_ENV_VAR)
		available = _dir != ""

func _process(delta):
	if not running or _dir == "":
		return
	_poll_timer -= delta
	_elapsed += delta
	if _poll_timer > 0.0:
		return
	_poll_timer = POLL_INTERVAL
	_check_status()

func send_state_to_peer(id: int) -> void:
	if available:
		rpc_id(id, "receive_deploy_status", running, message)

@rpc("any_peer", "reliable")
func request_deploy() -> void:
	if _dir == "" or not network or not network.is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	if not network.peers.has(sender_id) or running:
		return

	# What people see in their editors is only on the server's disk once it's saved
	if network.scene_sync:
		network.scene_sync._save_server_tracked_scenes()
	if network.script_sync:
		network.script_sync._save_dirty_server_scripts()

	_request_id = str(int(Time.get_unix_time_from_system()))
	var request_path = _dir.path_join("request/current")
	var file = FileAccess.open(request_path + ".tmp", FileAccess.WRITE)
	if file:
		file.store_string(_request_id)
		file.close()
	if not file or DirAccess.rename_absolute(request_path + ".tmp", request_path) != OK:
		_broadcast(false, "Couldn't start the deploy: the server can't write to its deploy folder")
		return

	_picked_up = false
	_elapsed = 0.0
	_poll_timer = POLL_INTERVAL
	_broadcast(true, network.peers[sender_id].get("username", "Someone") + " started a deploy")

func _check_status() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(_dir.path_join("status/current")))
	if data is Dictionary and str(data.get("id", "")) == _request_id:
		_picked_up = true
		var state = str(data.get("state", ""))
		var text = str(data.get("message", ""))
		if state == "done" or state == "failed":
			_broadcast(false, text)
		elif text != message:
			_broadcast(true, text)
		return
	if not _picked_up and _elapsed >= PICKUP_TIMEOUT:
		_broadcast(false, "Nothing happened: the deploy script doesn't seem to be running on the server")
	elif _elapsed >= RUN_TIMEOUT:
		_broadcast(false, "The deploy script stopped responding")

func _broadcast(is_running: bool, text: String) -> void:
	running = is_running
	message = text
	network.tc_print("Deploy: ", text)
	for pid in multiplayer.get_peers():
		rpc_id(pid, "receive_deploy_status", is_running, text)

@rpc("authority", "reliable")
func receive_deploy_status(is_running: bool, text: String) -> void:
	available = true
	running = is_running
	message = text
	network.tc_print("Deploy: ", text)
	if network.ui and network.ui.has_method("update_deploy_state"):
		network.ui.update_deploy_state()

func press_deploy() -> void:
	if available and not running and network and network.is_connected_to_session():
		rpc_id(1, "request_deploy")

func reset() -> void:
	if not network or not network.get("is_standalone_server"):
		available = false
		running = false
		message = ""
