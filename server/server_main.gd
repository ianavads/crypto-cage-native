# Crypto Cage Combat — Godot headless authority server.
#
# Listens on UDP 7777 (ENet, primary) AND TCP 7777 (WebSocket fallback for
# UDP-hostile networks), accepts two seats per match_id, confirms both seats'
# relayed verified context share the same match_id + engine_version, runs the
# authoritative 60 Hz sim, records both seats' per-tick input replay, and on
# KO/timeout POSTs the signed result + replay to the Base44 settle-native-match
# endpoint. One match per room; many rooms multiplexed.
#
# The server NEVER trusts stat/health/score assertions from clients — it
# simulates from its own copy of the canonical engine and only consumes per-tick
# inputs.
extends Node

const FS = preload("res://engine/fight_sim.gd")
const MatchRoomScript = preload("res://server/match_room.gd")


# Unifies an ENet packet peer and a WebSocket peer behind one send_json().
class PeerLink:
	var kind: String # "enet" | "ws"
	var key: String
	var enet: ENetPacketPeer
	var ws: WebSocketPeer

	func _init(p_kind: String, p_key: String, p_enet: ENetPacketPeer = null, p_ws: WebSocketPeer = null) -> void:
		kind = p_kind
		key = p_key
		enet = p_enet
		ws = p_ws

	func send_json(obj: Dictionary) -> void:
		var txt := JSON.stringify(obj)
		if kind == "enet" and enet != null:
			enet.send(0, txt.to_utf8_buffer(), ENetPacketPeer.FLAG_RELIABLE)
		elif kind == "ws" and ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(txt)


# --- Config (env/CLI; never hardcode secrets or the Hetzner host) -------------
var engine_version := ""
var port := 7777
var settle_url := "https://cryptocage.base44.app/functions/settle-native-match"
var settle_token := ""
var max_peers := 64
var countdown_ticks := 180
var match_ticks := MatchRoomScript.TIMEOUT_TICKS
var ws_enabled := true

var _host: ENetConnection
var _tcp: TCPServer
var _ws_links := {} # key -> PeerLink (WebSocket connections)
var _ws_counter := 0
# key -> { link: PeerLink, match_id: String, seat: int }
var _conns := {}
var _rooms := {} # match_id -> MatchRoom
var _countdown := {} # match_id -> remaining ticks while READY


func _ready() -> void:
	# All tunables come from the Config autoload (exported defaults + env/CLI).
	engine_version = Config.engine_version
	port = Config.port
	settle_url = Config.settle_url
	settle_token = Config.settle_token
	countdown_ticks = Config.countdown_ticks
	match_ticks = Config.match_ticks
	ws_enabled = Config.ws_enabled
	if engine_version == "":
		push_warning("CAGE_ENGINE_VERSION not set and FightSim.ENGINE_VERSION empty — refusing all seats until pinned.")
	_host = ENetConnection.new()
	var err := _host.create_host_bound("0.0.0.0", port, max_peers, 2)
	if err != OK:
		push_error("Failed to bind ENet host on UDP %d: %s" % [port, error_string(err)])
		get_tree().quit(1)
		return
	if ws_enabled:
		_tcp = TCPServer.new()
		var terr := _tcp.listen(port, "0.0.0.0")
		if terr != OK:
			push_warning("WebSocket fallback disabled — TCP %d listen failed: %s" % [port, error_string(terr)])
			_tcp = null
	Engine.physics_ticks_per_second = FS.TICK_HZ
	print("[cage] authority server | ENet UDP %d%s | engine_version=%s | settle_url=%s" % [
		port, (" + WebSocket TCP %d" % port) if _tcp != null else "", engine_version, settle_url])


func _physics_process(_delta: float) -> void:
	if _host == null:
		return
	_service_enet()
	_service_ws()
	_advance_rooms()


# --- ENet transport -----------------------------------------------------------
func _service_enet() -> void:
	while true:
		var ev: Array = _host.service(0)
		var type: int = ev[0]
		if type == ENetConnection.EVENT_NONE:
			break
		var peer = ev[1]
		match type:
			ENetConnection.EVENT_CONNECT:
				var key := _pkey(peer)
				_conns[key] = {"link": PeerLink.new("enet", key, peer, null), "match_id": "", "seat": 0}
			ENetConnection.EVENT_DISCONNECT:
				_on_disconnect(_pkey(peer))
			ENetConnection.EVENT_RECEIVE:
				var key := _pkey(peer)
				var c = _conns.get(key, null)
				var link: PeerLink = c["link"] if c != null else PeerLink.new("enet", key, peer, null)
				while peer.get_available_packet_count() > 0:
					var m = JSON.parse_string(peer.get_packet().get_string_from_utf8())
					if typeof(m) == TYPE_DICTIONARY:
						_handle_message(key, link, m)
			ENetConnection.EVENT_ERROR:
				push_error("[cage] ENet host error; shutting down")
				_host.destroy()
				_host = null
				return


static func _pkey(peer: ENetPacketPeer) -> String:
	return "%s:%d" % [peer.get_remote_address(), peer.get_remote_port()]


# --- WebSocket transport (fallback) ------------------------------------------
func _service_ws() -> void:
	if _tcp == null:
		return
	while _tcp.is_connection_available():
		var tcp := _tcp.take_connection()
		var ws := WebSocketPeer.new()
		if ws.accept_stream(tcp) != OK:
			continue
		_ws_counter += 1
		var key := "ws:%d" % _ws_counter
		var link := PeerLink.new("ws", key, null, ws)
		_conns[key] = {"link": link, "match_id": "", "seat": 0}
		_ws_links[key] = link
	for key in _ws_links.keys():
		var link: PeerLink = _ws_links[key]
		var ws: WebSocketPeer = link.ws
		ws.poll()
		var st := ws.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var m = JSON.parse_string(ws.get_packet().get_string_from_utf8())
				if typeof(m) == TYPE_DICTIONARY:
					_handle_message(key, link, m)
		elif st == WebSocketPeer.STATE_CLOSED:
			_on_disconnect(key)
			_ws_links.erase(key)


# --- Shared message handling --------------------------------------------------
func _handle_message(key: String, link: PeerLink, msg: Dictionary) -> void:
	match String(msg.get("t", "")):
		"hello":
			_handle_hello(key, link, msg)
		"input":
			_handle_input(key, msg)
		_:
			pass


func _handle_hello(key: String, link: PeerLink, msg: Dictionary) -> void:
	if not _conns.has(key):
		_conns[key] = {"link": link, "match_id": "", "seat": 0}
	if engine_version == "":
		link.send_json({"t": "reject", "reason": "server_engine_unpinned"})
		return
	var match_id := String(msg.get("match_id", ""))
	var seat := int(msg.get("seat", 0))
	if match_id == "" or (seat != 1 and seat != 2):
		link.send_json({"t": "reject", "reason": "bad_context"})
		return
	var room: MatchRoomScript = _rooms.get(match_id, null)
	if room == null:
		room = MatchRoomScript.new(match_id, engine_version, match_ticks)
		_rooms[match_id] = room
	var reason := room.add_seat(seat, msg, key, link)
	if reason != "":
		link.send_json({"t": "reject", "reason": reason})
		if not room.both_present() and room.seats.is_empty():
			_rooms.erase(match_id)
		return
	_conns[key]["match_id"] = match_id
	_conns[key]["seat"] = seat
	link.send_json({"t": "welcome", "seat": seat, "match_id": match_id})
	if room.both_present() and room.state == MatchRoomScript.READY and not _countdown.has(match_id):
		_countdown[match_id] = countdown_ticks
		_broadcast(room, {"t": "start", "match_id": match_id, "tick_hz": FS.TICK_HZ, "countdown": countdown_ticks})


func _handle_input(key: String, msg: Dictionary) -> void:
	if not _conns.has(key):
		return
	var c: Dictionary = _conns[key]
	var room: MatchRoomScript = _rooms.get(c["match_id"], null)
	if room == null or c["seat"] == 0:
		return
	room.set_input(c["seat"], msg)


func _on_disconnect(key: String) -> void:
	_conns.erase(key)


# --- Room tick + lifecycle ----------------------------------------------------
func _advance_rooms() -> void:
	for match_id in _rooms.keys():
		var room: MatchRoomScript = _rooms[match_id]
		if room.state == MatchRoomScript.READY:
			if _countdown.has(match_id):
				_countdown[match_id] -= 1
				if _countdown[match_id] <= 0:
					_countdown.erase(match_id)
					room.start()
		elif room.state == MatchRoomScript.LIVE:
			var ended := room.tick_once()
			_broadcast(room, _state_msg(room))
			if ended:
				_on_room_ended(match_id, room)


func _state_msg(room: MatchRoomScript) -> Dictionary:
	var snap := room.snapshot()
	snap["t"] = "state"
	return snap


func _on_room_ended(match_id: String, room: MatchRoomScript) -> void:
	var payload := room.settle_payload()
	print("[cage] match %s ENDED reason=%s winner_seat=%d ticks=%d" % [match_id, room.ended_reason, room.winner_seat, room.tick])
	_broadcast(room, {
		"t": "ended",
		"winner_seat": room.winner_seat,
		"reason": room.ended_reason,
		"ticks": room.tick,
		"final_state": payload["final_state"],
	})
	_submit_settle(payload)
	_rooms.erase(match_id)
	_countdown.erase(match_id)


# --- Settlement POST ----------------------------------------------------------
func _submit_settle(payload: Dictionary) -> void:
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray):
			_on_settle_response(payload["match_id"], result, code, body, http)
	)
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % settle_token,
	])
	var err := http.request(settle_url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		push_error("[cage] settle request() failed for match %s: %s" % [payload["match_id"], error_string(err)])
		http.queue_free()


func _on_settle_response(match_id: String, result: int, code: int, body: PackedByteArray, http: HTTPRequest) -> void:
	var text := body.get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS:
		push_error("[cage] settle transport error for match %s (result=%d). Not retrying in-process." % [match_id, result])
	elif code == 200:
		print("[cage] settled match %s: %s" % [match_id, text])
	elif code == 409:
		push_error("[cage] SETTLE 409 for match %s — replay mismatch; the sim diverged from the published engine. %s" % [match_id, text])
	else:
		push_error("[cage] settle failed for match %s: HTTP %d %s" % [match_id, code, text])
	http.queue_free()


# --- Broadcast ----------------------------------------------------------------
func _broadcast(room: MatchRoomScript, msg: Dictionary) -> void:
	for seat in room.seats:
		var link = room.seats[seat].get("link", null)
		if link != null:
			link.send_json(msg)
