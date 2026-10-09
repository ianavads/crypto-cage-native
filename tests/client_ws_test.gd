# WebSocket-transport integration test: two NetClients connect to the server's
# WebSocket fallback (ws://127.0.0.1:7777), relay context, stream inputs-only,
# receive authoritative state, and end. Bypasses verify (sets context directly)
# to isolate the transport. Run as a scene so node processing is available.
extends Node

const NetClientScript = preload("res://client/net_client.gd")

var nc1: NetClientScript
var nc2: NetClientScript
var ended1 := false
var ended2 := false
var states1 := 0
var states2 := 0
var start_ms := 0


func _make(seat: int) -> NetClientScript:
	var nc: NetClientScript = NetClientScript.new()
	add_child(nc)
	nc.context = {
		"match_id": "match_ws_test", "seat": seat, "engine_version": "testv1",
		"server_url": "ws://127.0.0.1:7777",
		"fighter_id": "fighter_%d" % seat, "opponent_fighter_id": "fighter_%d" % (3 - seat),
	}
	return nc


func _ready() -> void:
	start_ms = Time.get_ticks_msec()
	nc1 = _make(1)
	nc2 = _make(2)
	nc1.state_received.connect(func(_s): states1 += 1)
	nc2.state_received.connect(func(_s): states2 += 1)
	nc1.server_connected.connect(func(): print("[ws] seat1 WS connected"))
	nc2.server_connected.connect(func(): print("[ws] seat2 WS connected"))
	nc1.match_ended.connect(func(i): ended1 = true; print("[ws] seat1 ENDED %s" % i))
	nc2.match_ended.connect(func(i): ended2 = true; print("[ws] seat2 ENDED %s" % i))
	nc1.rejected.connect(func(r): ended1 = true; print("[ws] seat1 REJECTED %s" % r))
	nc2.rejected.connect(func(r): ended2 = true; print("[ws] seat2 REJECTED %s" % r))
	nc1._connect_to_server()
	nc2._connect_to_server()
	print("[ws] connecting both seats over WebSocket")


func _process(_delta: float) -> void:
	nc1.set_input({"moveDir": 1, "jump": false, "crouch": false, "action": "heavy"})
	nc2.set_input({"moveDir": -1, "jump": false, "crouch": false, "action": "heavy"})
	nc1.poll()
	nc2.poll()
	var now := Time.get_ticks_msec()
	if (ended1 and ended2) or now - start_ms > 15000:
		print("[ws] DONE ended1=%s ended2=%s states1=%d states2=%d (%.1fs)" % [
			ended1, ended2, states1, states2, (now - start_ms) / 1000.0])
		get_tree().quit()
