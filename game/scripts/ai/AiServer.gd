# AiServer.gd (Godot 4.x) - Clean Production Version
extends Node

const PORT: int = 5555
const BIND_ADDR: String = "127.0.0.1"

var _server: TCPServer = TCPServer.new()
var _peers: Array[StreamPeerTCP] = []
var _buffers: Dictionary = {}
var _pending_actions: Array[Dictionary] = []

func _ready() -> void:
	var err: int = _server.listen(PORT, BIND_ADDR)
	if err != OK:
		push_error("AiServer listen FAILED on %s:%d (err=%s)" % [BIND_ADDR, PORT, str(err)])
	else:
		print("AiServer listening on %s:%d" % [BIND_ADDR, PORT])

func _process(_delta: float) -> void:
	# Accept all pending connections
	while _server.is_connection_available():
		var p: StreamPeerTCP = _server.take_connection()
		p.set_no_delay(true)
		_peers.append(p)
		_buffers[p] = "" as String
		print("AiServer: client CONNECTED. peers=", _peers.size())

	# Read incoming lines from all peers
	for p: StreamPeerTCP in _peers.duplicate():
		if not _is_connected(p):
			_drop_peer(p)
			continue

		var avail: int = p.get_available_bytes()
		if avail <= 0:
			continue

		var chunk: String = p.get_utf8_string(avail)
		var buf: String = str(_buffers.get(p, ""))
		buf += chunk

		# Process complete lines (NDJSON)
		while true:
			var nl: int = buf.find("\n")
			if nl == -1:
				break
			var line: String = buf.substr(0, nl).strip_edges()
			buf = buf.substr(nl + 1)
			if line.is_empty():
				continue

			var pkt_any: Variant = JSON.parse_string(line)
			if pkt_any == null or typeof(pkt_any) != TYPE_DICTIONARY:
				push_warning("AiServer: bad JSON (ignored): %s" % line)
				continue

			var pkt: Dictionary = pkt_any as Dictionary
			_handle_message(p, pkt)

		_buffers[p] = buf

func _handle_message(_peer: StreamPeerTCP, msg: Dictionary) -> void:
	var t: String = str(msg.get("type", ""))
	match t:
		"_ai_request_reset":
			print("AiServer: got RESET")
			var game_nodes = get_tree().get_nodes_in_group("game")
			if game_nodes.size() > 0:
				var game = game_nodes[0]
				if game.has_method("_ai_request_reset"):
					game._ai_request_reset()
		"_ai_request_observation":
			# Soft reset: send current state without resetting game
			print("AiServer: got OBSERVATION REQUEST (soft reset)")
			var game_nodes = get_tree().get_nodes_in_group("game")
			if game_nodes.size() > 0:
				var game = game_nodes[0]
				if game.has_method("_ai_send_current_observation"):
					game._ai_send_current_observation()
		"act":
			var actions_any: Variant = msg.get("actions", {})
			var actions: Dictionary = actions_any as Dictionary
			_pending_actions.append(actions)

# ---- API for the game ----

func pop_actions() -> Array[Dictionary]:
	var out: Array[Dictionary] = _pending_actions.duplicate()
	_pending_actions.clear()
	return out

func send_observation(obs: Dictionary) -> void:
	_broadcast({"type":"obs","data":obs})

func send_reward(global_reward: float, done: bool, payload: Dictionary) -> void:
	var out: Dictionary = {"type":"reward", "reward": global_reward, "done": done}
	out.merge(payload, true)
	#print("AiServer: Sending reward message: ", JSON.stringify(out))
	_broadcast(out)
	#print("AiServer: Reward message broadcast complete")

# ---- internals ----

func _broadcast(obj: Dictionary) -> void:
	var line: String = JSON.stringify(obj) + "\n"
	var bytes: PackedByteArray = line.to_utf8_buffer()
	var alive: int = 0
	for p: StreamPeerTCP in _peers:
		if _is_connected(p):
			var err: int = p.put_data(bytes)
			if err == OK:
				alive += 1
	
	# Lightweight debug for obs traffic
	#if str(obj.get("type","")) == "obs":
		#var data: Dictionary = obj.get("data", {}) as Dictionary
		#var units_arr: Array = data.get("units", []) as Array
		#print("AiServer: broadcast OBS -> peers=", alive, " units=", units_arr.size())

func _is_connected(p: StreamPeerTCP) -> bool:
	return p.get_status() == StreamPeerTCP.STATUS_CONNECTED

func _drop_peer(p: StreamPeerTCP) -> void:
	_buffers.erase(p)
	_peers.erase(p)
	if _is_connected(p):
		p.disconnect_from_host()
	print("AiServer: client DISCONNECTED. peers=", _peers.size())
