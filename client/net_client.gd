# Crypto Cage Combat — desktop client network core (no rendering).
#
# Flow (brief §5 / integration §2):
#   1. verify-match-seat (POST {seat_token}) — no app session needed. Returns the
#      authoritative context: match_id, seat, engine_version, server_url, fighters.
#   2. Connect to server_url (ENet) and relay ONLY that server-returned context.
#   3. Send ONLY per-tick inputs. Render the server's authoritative state.
#
# This node NEVER sends fighter stats / health / energy / scores — those are
# server outputs. It never holds a signing secret and never calls settlement.
extends Node
class_name NetClient

signal verified(context: Dictionary)
signal rejected(reason: String)      # server refused the seat (e.g. engine_version_drift)
signal verify_failed(code: int, msg: String) # verify-match-seat failed (401/transport)
signal server_connected()
signal state_received(snapshot: Dictionary)
signal match_ended(info: Dictionary)
signal disconnected()

enum { IDLE, VERIFYING, CONNECTING, READY, LIVE, ENDED }

var phase: int = IDLE
var context: Dictionary = {}
var last_state: Dictionary = {}

var _http: HTTPRequest
var _conn: ENetConnection
var _peer: ENetPacketPeer
var _use_ws := false
var _ws: WebSocketPeer
var _hello_sent := false
var _input := {"moveDir": 0, "jump": false, "crouch": false, "action": ""}
var _last_input_send := 0
var _input_interval_ms := 16 # ~60 Hz


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_verify_completed)


# seat_token: the JWT from the cryptocage:// launch URL. verify_url: the Base44
# verify-match-seat endpoint.
func start_from_token(seat_token: String, verify_url: String) -> void:
	phase = VERIFYING
	var headers := PackedStringArray(["Content-Type: application/json"])
	var body := JSON.stringify({"seat_token": seat_token})
	var err := _http.request(verify_url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		phase = IDLE
		verify_failed.emit(-1, "verify request() failed: %s" % error_string(err))


func _on_verify_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var text := body.get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS:
		phase = IDLE
		verify_failed.emit(code, "verify transport error (result=%d)" % result)
		return
	if code == 401:
		# Expired/forged/already-ended — bounce back to the web app to re-issue.
		phase = IDLE
		verify_failed.emit(401, "seat token rejected by verify-match-seat")
		return
	if code != 200:
		phase = IDLE
		verify_failed.emit(code, "verify-match-seat HTTP %d: %s" % [code, text])
		return
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		phase = IDLE
		verify_failed.emit(code, "verify-match-seat returned non-JSON")
		return
	# NOTE: field names mirror the documented verified context. If the live
	# verify-match-seat nests fighters differently, adjust _extract_context only.
	context = _extract_context(parsed)
	verified.emit(context)
	_connect_to_server()


func _extract_context(r: Dictionary) -> Dictionary:
	return {
		"match_id": String(r.get("match_id", "")),
		"seat": int(r.get("seat", 0)),
		"engine_version": String(r.get("engine_version", "")),
		"server_url": String(r.get("server_url", "")),
		"fighter_id": String(r.get("fighter_id", "")),
		"opponent_fighter_id": String(r.get("opponent_fighter_id", "")),
	}


func _connect_to_server() -> void:
	var url: String = context.get("server_url", "")
	# WebSocket fallback: a ws:// or wss:// server_url routes over TCP.
	if url.begins_with("ws://") or url.begins_with("wss://"):
		_use_ws = true
		_ws = WebSocketPeer.new()
		var werr := _ws.connect_to_url(url)
		if werr != OK:
			verify_failed.emit(-1, "WebSocket connect_to_url failed: %s" % error_string(werr))
			return
		phase = CONNECTING
		_hello_sent = false
		return
	# ENet (primary, UDP). Strip optional scheme and split host:port.
	var host := url.replace("enet://", "").replace("udp://", "")
	var port := 7777
	if host.contains(":"):
		var parts := host.rsplit(":", true, 1)
		host = parts[0]
		if parts[1].is_valid_int():
			port = int(parts[1])
	_conn = ENetConnection.new()
	var err := _conn.create_host(1, 2)
	if err != OK:
		verify_failed.emit(-1, "ENet create_host failed: %s" % error_string(err))
		return
	_peer = _conn.connect_to_host(host, port, 2)
	phase = CONNECTING
	_hello_sent = false


func set_input(input: Dictionary) -> void:
	_input = {
		"moveDir": int(input.get("moveDir", 0)),
		"jump": bool(input.get("jump", false)),
		"crouch": bool(input.get("crouch", false)),
		"action": String(input.get("action", "")) if input.get("action", null) != null else "",
	}


# Call once per frame from the owner (renderer or test harness).
func poll() -> void:
	if _use_ws:
		_poll_ws()
		return
	if _conn == null:
		return
	while true:
		var ev: Array = _conn.service(0)
		var type: int = ev[0]
		if type == ENetConnection.EVENT_NONE:
			break
		var peer = ev[1]
		match type:
			ENetConnection.EVENT_CONNECT:
				_send_hello()
				server_connected.emit()
			ENetConnection.EVENT_RECEIVE:
				while peer.get_available_packet_count() > 0:
					var m = JSON.parse_string(peer.get_packet().get_string_from_utf8())
					if typeof(m) == TYPE_DICTIONARY:
						_on_message(m)
			ENetConnection.EVENT_DISCONNECT:
				disconnected.emit()
	_maybe_send_input()


func _poll_ws() -> void:
	if _ws == null:
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _hello_sent:
			_send_hello()
			server_connected.emit()
		while _ws.get_available_packet_count() > 0:
			var m = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
			if typeof(m) == TYPE_DICTIONARY:
				_on_message(m)
		_maybe_send_input()
	elif st == WebSocketPeer.STATE_CLOSED:
		disconnected.emit()


func _maybe_send_input() -> void:
	# Stream inputs only while the bout is live.
	if phase == LIVE:
		var now := Time.get_ticks_msec()
		if now - _last_input_send >= _input_interval_ms:
			_last_input_send = now
			_send({"t": "input",
				"moveDir": _input["moveDir"], "jump": _input["jump"],
				"crouch": _input["crouch"], "action": _input["action"]})


func _send_hello() -> void:
	if _hello_sent:
		return
	_hello_sent = true
	# Relay ONLY the server-returned verified context (nothing sensitive).
	_send({
		"t": "hello",
		"match_id": context.get("match_id", ""),
		"seat": context.get("seat", 0),
		"engine_version": context.get("engine_version", ""),
		"fighter_id": context.get("fighter_id", ""),
		"opponent_fighter_id": context.get("opponent_fighter_id", ""),
	})


func _on_message(m: Dictionary) -> void:
	match String(m.get("t", "")):
		"welcome":
			phase = READY
		"start":
			phase = LIVE
		"state":
			last_state = m
			state_received.emit(m)
		"ended":
			phase = ENDED
			match_ended.emit(m)
		"reject":
			phase = ENDED
			rejected.emit(String(m.get("reason", "")))


func _send(msg: Dictionary) -> void:
	var txt := JSON.stringify(msg)
	if _use_ws:
		if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_ws.send_text(txt)
		return
	if _peer == null:
		return
	_peer.send(0, txt.to_utf8_buffer(), ENetPacketPeer.FLAG_RELIABLE)


func close() -> void:
	if _use_ws:
		if _ws != null:
			_ws.close()
		return
	if _peer != null:
		_peer.peer_disconnect_now(0)
	if _conn != null:
		_conn.destroy()
	_conn = null
	_peer = null
