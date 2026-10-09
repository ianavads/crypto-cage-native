# Parity harness: runs the GDScript port with a fixed deterministic input stream
# and prints raw IEEE-754 bytes of every fighter field per tick, so its output
# can be diffed byte-for-byte against the published fightSim.js (run_js.mjs).
# Run: godot --headless --path <project> --script res://tests/parity_harness.gd
extends SceneTree

const FS = preload("res://engine/fight_sim.gd")


func hx(v: float) -> String:
	var b := PackedFloat64Array([v]).to_byte_array()
	var s := ""
	for i in range(8):
		s += "%02x" % b[i]
	return s


# Must match gi() in run_js.mjs exactly (integer-only arithmetic).
# Variant B: grounded-heavy / crouch biased, long run.
func gi(tick: int, seat: int) -> Dictionary:
	var h: int = (tick * 1103515245 + seat * 12345 + 1013904223) % 2147483648
	var move_dir: int = (h % 3) - 1
	var jump: bool = (int(h / 3) % 23) == 0
	var crouch: bool = (int(h / 39) % 3) == 0
	var d: int = int(h / 273) % 7
	var action := "heavy" if d <= 1 else ("light" if d == 2 else ("special" if d == 3 else ""))
	return {"moveDir": move_dir, "jump": jump, "crouch": crouch, "action": action}


func _initialize() -> void:
	var g := FS.create_game()
	var n := 3000
	var out := PackedStringArray()
	for t in range(n):
		FS.step(g, t, {"p1": gi(t, 1), "p2": gi(t, 2)})
		var a: FS.Fighter = g["p1"]
		var b: FS.Fighter = g["p2"]
		out.append("%d P1 %s %s %s %s %s %s %s %d P2 %s %s %s %s %s %s %s %d" % [
			t,
			hx(a.x), hx(a.y), hx(a.vx), hx(a.vy), hx(a.health), hx(a.energy), a.state, (1 if a.ko else 0),
			hx(b.x), hx(b.y), hx(b.vx), hx(b.vy), hx(b.health), hx(b.energy), b.state, (1 if b.ko else 0),
		])
	print("\n".join(out))
	quit()
