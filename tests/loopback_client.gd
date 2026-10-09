# Loopback integration client: opens two independent ENet connections (seat 1 &
# seat 2) to the headless server, performs the hello handshake, then streams
# per-tick inputs until both seats receive ENDED. Proves the full
# handshake -> context-match -> LIVE tick -> settle loop against a running server.
extends SceneTree

var EV := "testv1"
var MATCH := "match_loopback_1"

var conn1: ENetConnection
var peer1: ENetPacketPeer
var conn2: ENetConnection
var peer2: ENetPacketPeer

var seat1_state := "connecting"
var seat2_state := "connecting"
var ended1 := false
var ended2 := false
var last_state := {}
var state_count := 0
var start_ms := 0
var last_send := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ev="):
			EV = arg.split("=", true, 1)[1]
		elif arg.begins_with("--match="):
			MATCH = arg.split("=", true, 1)[1]
	start_ms = Time.get_ticks_msec()
	conn1 = ENetConnection.new()
	conn1.create_host(1, 2)
	peer1 = conn1.connect_to_host("127.0.0.1", 7777, 2)
	conn2 = ENetConnection.new()
	conn2.create_host(1, 2)
	peer2 = conn2.connect_to_host("127.0.0.1", 7777, 2)
	print("[client] connecting two seats to 127.0.0.1:7777 ...")


func _hello(seat: int) -> Dictionary:
	return {
		"t": "hello", "match_id": MATCH, "seat": seat, "engine_version": EV,
		"fighter_id": "fighter_%d" % seat, "opponent_fighter_id": "fighter_%d" % (3 - seat),
	}


func _send(peer: ENetPacketPeer, msg: Dictionary) -> void:
	peer.send(0, JSON.stringify(msg).to_utf8_buffer(), ENetPacketPeer.FLAG_RELIABLE)


func _service(conn: ENetConnection, seat: int) -> void:
	while true:
		var ev: Array = conn.service(0)
		var type: int = ev[0]
		if type == ENetConnection.EVENT_NONE:
			break
		var peer = ev[1]
		match type:
			ENetConnection.EVENT_CONNECT:
				_send(peer, _hello(seat))
			ENetConnection.EVENT_RECEIVE:
				while peer.get_available_packet_count() > 0:
					var m = JSON.parse_string(peer.get_packet().get_string_from_utf8())
					if typeof(m) == TYPE_DICTIONARY:
						_on_msg(seat, m)
			ENetConnection.EVENT_DISCONNECT:
				print("[client] seat %d DISCONNECTED" % seat)


func _on_msg(seat: int, m: Dictionary) -> void:
	var t := String(m.get("t", ""))
	match t:
		"welcome":
			if seat == 1: seat1_state = "welcomed"
			else: seat2_state = "welcomed"
			print("[client] seat %d welcomed" % seat)
		"start":
			print("[client] seat %d START (countdown=%s)" % [seat, m.get("countdown", "?")])
		"state":
			last_state = m
			state_count += 1
		"ended":
			if seat == 1: ended1 = true
			else: ended2 = true
			print("[client] seat %d ENDED winner_seat=%s reason=%s ticks=%s final=%s" % [
				seat, m.get("winner_seat"), m.get("reason"), m.get("ticks"), str(m.get("final_state"))])
		"reject":
			print("[client] seat %d REJECTED reason=%s" % [seat, m.get("reason")])
			if seat == 1: ended1 = true
			else: ended2 = true


func _process(_delta: float) -> bool:
	_service(conn1, 1)
	_service(conn2, 2)
	var now := Time.get_ticks_msec()
	if now - last_send >= 10:
		last_send = now
		# Both seats march toward center and spam heavy (overhead) to trade damage.
		_send(peer1, {"t": "input", "moveDir": 1, "jump": false, "crouch": false, "action": "heavy"})
		_send(peer2, {"t": "input", "moveDir": -1, "jump": false, "crouch": false, "action": "heavy"})
	if (ended1 and ended2) or now - start_ms > 15000:
		var hp1 = last_state.get("p1", {}).get("health", "?") if last_state.has("p1") else "?"
		var hp2 = last_state.get("p2", {}).get("health", "?") if last_state.has("p2") else "?"
		print("[client] DONE ended1=%s ended2=%s states_recv=%d lastHealth p1=%s p2=%s (%.1fs)" % [
			ended1, ended2, state_count, str(hp1), str(hp2), (now - start_ms) / 1000.0])
		return true
	return false
