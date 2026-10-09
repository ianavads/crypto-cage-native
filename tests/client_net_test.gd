# Client network integration test: drives TWO real NetClient instances through
# verify-match-seat (mock) -> ENet connect -> inputs-only -> authoritative state
# -> ENDED, against a running headless server. No rendering involved.
# Run as a scene (not a SceneTree script) so HTTPRequest gets normal node
# processing: godot --headless --path <proj> res://tests/client_net_test.tscn
extends Node

const NetClientScript = preload("res://client/net_client.gd")

var nc1: NetClientScript
var nc2: NetClientScript
var ended1 := false
var ended2 := false
var states1 := 0
var states2 := 0
var start_ms := 0
var verify_url := "http://127.0.0.1:8098/verify"


func _ready() -> void:
	start_ms = Time.get_ticks_msec()
	nc1 = NetClientScript.new()
	nc2 = NetClientScript.new()
	add_child(nc1)
	add_child(nc2)
	nc1.state_received.connect(func(_s): states1 += 1)
	nc2.state_received.connect(func(_s): states2 += 1)
	nc1.verified.connect(func(c): print("[t] seat1 verified ctx=%s" % c))
	nc2.verified.connect(func(c): print("[t] seat2 verified ctx=%s" % c))
	nc1.match_ended.connect(func(i): ended1 = true; print("[t] seat1 ENDED %s" % i))
	nc2.match_ended.connect(func(i): ended2 = true; print("[t] seat2 ENDED %s" % i))
	nc1.rejected.connect(func(r): ended1 = true; print("[t] seat1 REJECTED %s" % r))
	nc2.rejected.connect(func(r): ended2 = true; print("[t] seat2 REJECTED %s" % r))
	nc1.verify_failed.connect(func(code, m): ended1 = true; print("[t] seat1 verify_failed %s %s" % [code, m]))
	nc2.verify_failed.connect(func(code, m): ended2 = true; print("[t] seat2 verify_failed %s %s" % [code, m]))
	nc1.start_from_token("tok1", verify_url)
	nc2.start_from_token("tok2", verify_url)
	print("[t] started both seats via verify-match-seat")


func _process(_delta: float) -> void:
	nc1.set_input({"moveDir": 1, "jump": false, "crouch": false, "action": "heavy"})
	nc2.set_input({"moveDir": -1, "jump": false, "crouch": false, "action": "heavy"})
	nc1.poll()
	nc2.poll()
	var now := Time.get_ticks_msec()
	if (ended1 and ended2) or now - start_ms > 15000:
		print("[t] DONE ended1=%s ended2=%s states1=%d states2=%d (%.1fs)" % [
			ended1, ended2, states1, states2, (now - start_ms) / 1000.0])
		get_tree().quit()
