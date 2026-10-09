# Exhaustive codec parity + round-trip test. Prints the encoding of all 48 input
# combinations in the same order as run_codec_js.mjs, for a byte-for-byte diff,
# and asserts decode(encode(x)) == x.
extends SceneTree

const RC = preload("res://net/replay_codec.gd")


func _initialize() -> void:
	var moves := [-1, 0, 1]
	var bools := [false, true]
	var actions := ["", "light", "heavy", "special"]
	var out := PackedStringArray()
	var roundtrip_ok := true
	for move_dir in moves:
		for jump in bools:
			for crouch in bools:
				for action in actions:
					var inp := {"moveDir": move_dir, "jump": jump, "crouch": crouch, "action": action}
					var enc := RC.encode_input(inp)
					out.append("%d %d %d %s %s" % [move_dir, (1 if jump else 0), (1 if crouch else 0), (action if action != "" else "-"), enc])
					var dec := RC.decode_char(enc)
					if dec["moveDir"] != move_dir or dec["jump"] != jump or dec["crouch"] != crouch or dec["action"] != action:
						roundtrip_ok = false
						push_error("roundtrip mismatch for %s -> %s -> %s" % [str(inp), enc, str(dec)])
	print("\n".join(out))
	print("ROUNDTRIP_OK=%s" % ("1" if roundtrip_ok else "0"))
	quit()
