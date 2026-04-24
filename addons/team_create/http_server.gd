extends Node

var tcp_server: TCPServer
var _running = false
var network: Node

# Map of connection -> StreamPeerTCP
var connections = []
# Map of connection -> { request_lines, body_expected, method, path }
var requests = {}

const HTTP_PORT = 12345

func _ready():
	name = "TeamCreateHTTPServer"

func start_server():
	tcp_server = TCPServer.new()
	var err = tcp_server.listen(HTTP_PORT)
	if err == OK:
		_running = true
		set_process(true)
		if network:
			network.tc_print("HTTP Server listening on port " + str(HTTP_PORT))
	else:
		if network:
			network.tc_print("Failed to start HTTP server. Error: " + str(err))

func stop_server():
	_running = false
	set_process(false)
	if tcp_server:
		tcp_server.stop()
		tcp_server = null
	for peer in connections:
		peer.disconnect_from_host()
	connections.clear()
	requests.clear()
	if network:
		network.tc_print("HTTP Server stopped.")

func _process(_delta):
	if not _running or not tcp_server:
		return

	if tcp_server.is_connection_available():
		var peer = tcp_server.take_connection()
		connections.append(peer)
		requests[peer] = {
			"buffer": PackedByteArray(),
			"state": "headers",
			"content_length": 0,
			"method": "",
			"path": ""
		}

	var i = connections.size() - 1
	while i >= 0:
		var peer = connections[i]
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.poll()
			var available = peer.get_available_bytes()
			if available > 0:
				var data = peer.get_data(available)
				if data[0] == OK:
					_handle_data(peer, data[1])
		else:
			requests.erase(peer)
			connections.remove_at(i)
		i -= 1

func _handle_data(peer: StreamPeerTCP, data: PackedByteArray):
	var req = requests[peer]
	req["buffer"].append_array(data)

	if req["state"] == "headers":
		# Look for \r\n\r\n
		var end_of_headers = -1
		for i in range(req["buffer"].size() - 3):
			if req["buffer"][i] == 13 and req["buffer"][i+1] == 10 and req["buffer"][i+2] == 13 and req["buffer"][i+3] == 10:
				end_of_headers = i
				break

		if end_of_headers != -1:
			var header_bytes = req["buffer"].slice(0, end_of_headers)
			var header_str = header_bytes.get_string_from_utf8()
			var lines = header_str.split("\r\n")
			if lines.size() > 0:
				var request_line = lines[0].split(" ")
				if request_line.size() >= 2:
					req["method"] = request_line[0]
					req["path"] = request_line[1]

				for j in range(1, lines.size()):
					var line = lines[j]
					if line.to_lower().begins_with("content-length:"):
						req["content_length"] = line.split(":")[1].strip_edges().to_int()

			var body_bytes = req["buffer"].slice(end_of_headers + 4, req["buffer"].size())
			req["buffer"] = body_bytes
			req["state"] = "body"

	if req["state"] == "body":
		if req["buffer"].size() >= req["content_length"]:
			# Request complete
			_process_request(peer, req)
			requests.erase(peer)
			connections.erase(peer)

func _process_request(peer: StreamPeerTCP, req: Dictionary):
	var method = req["method"]
	var path = req["path"].uri_decode()
	var body = req["buffer"]

	# We expect paths like /get_file?path=res://icon.png
	# and /upload_file?path=res://icon.png

	if method == "GET" and path.begins_with("/get_file"):
		var query_idx = path.find("?path=")
		if query_idx != -1:
			var file_path = path.substr(query_idx + 6)
			_handle_get_file(peer, file_path)
		else:
			_send_response(peer, 400, "Bad Request")

	elif method == "POST" and path.begins_with("/upload_file"):
		var query_idx = path.find("?path=")
		if query_idx != -1:
			var file_path = path.substr(query_idx + 6)
			_handle_upload_file(peer, file_path, body)
		else:
			_send_response(peer, 400, "Bad Request")

	else:
		_send_response(peer, 404, "Not Found")

func _handle_get_file(peer: StreamPeerTCP, file_path: String):
	if network and network.file_sync:
		if not network.file_sync._is_safe_path(file_path):
			_send_response(peer, 403, "Forbidden")
			return

	if FileAccess.file_exists(file_path):
		var bytes = FileAccess.get_file_as_bytes(file_path)
		_send_response(peer, 200, "OK", bytes)
	else:
		_send_response(peer, 404, "Not Found")

func _handle_upload_file(peer: StreamPeerTCP, file_path: String, body: PackedByteArray):
	if network and network.file_sync:
		if not network.file_sync._is_safe_path(file_path):
			_send_response(peer, 403, "Forbidden")
			return

		# Fake a file receive via the file sync logic
		# Usually transfer_id is randi() in RPC. We can just use 0 since HTTP transfers entire file.
		network.file_sync.receive_file(file_path, 0, body, true)
		_send_response(peer, 200, "OK")
	else:
		_send_response(peer, 500, "Internal Server Error")

func _send_response(peer: StreamPeerTCP, code: int, status_text: String, body: PackedByteArray = PackedByteArray()):
	var headers = "HTTP/1.1 " + str(code) + " " + status_text + "\r\n"
	headers += "Content-Length: " + str(body.size()) + "\r\n"
	headers += "Connection: close\r\n"
	headers += "\r\n"

	peer.put_data(headers.to_utf8_buffer())
	if body.size() > 0:
		peer.put_data(body)

	peer.disconnect_from_host()
