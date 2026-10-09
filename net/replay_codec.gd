# © 2026 Ian W Thompson. Author & Owner: Ian W Thompson. All rights reserved.
# Proprietary — part of Crypto Cage Combat. No copying or derivative works.
#
# GDScript port of base44/shared/replayCodec.js — the per-tick input replay
# encoder. One char per fixed 1/60s tick, 6 bits, from a 64-char alphabet. The
# Base44 settle function decodes this exact stream (via gatekeeperSim.ts /
# decodeReplay) and re-runs it through the published fightSim.js, so the format
# MUST match byte-for-byte.
#
# Bit layout (must match decodeReplay exactly):
#   moveDir (0 none,1 left,2 right) | jump (bit 2) | crouch (bit 3)
#   | action (bits 4-5: 0 none,1 light,2 heavy,3 special)

extends RefCounted
class_name ReplayCodec

const ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const REPLAY_MAX := 6000


# i: { moveDir:int(-1/0/1), jump:bool, crouch:bool, action:String("light"/"heavy"/"special"/"") }
static func encode_input(i: Dictionary) -> String:
	var move_dir_raw: int = int(i.get("moveDir", 0))
	var move_dir: int = 1 if move_dir_raw < 0 else (2 if move_dir_raw > 0 else 0)
	var jump: int = 4 if i.get("jump", false) else 0
	var crouch: int = 8 if i.get("crouch", false) else 0
	var act = i.get("action", "")
	var action: int = 1 if act == "light" else (2 if act == "heavy" else (3 if act == "special" else 0))
	var v: int = move_dir | jump | crouch | (action << 4)
	if v >= 0 and v < ALPHABET.length():
		return ALPHABET[v]
	return "A"


# Decode one char back to an input dict (mirror of the Base44 decodeReplay bit
# layout). Used for round-trip tests; the server only needs encode for settling.
static func decode_char(c: String) -> Dictionary:
	var v: int = ALPHABET.find(c)
	if v < 0:
		v = 0
	var md_bits: int = v & 3
	var move_dir: int = -1 if md_bits == 1 else (1 if md_bits == 2 else 0)
	var jump: bool = (v & 4) != 0
	var crouch: bool = (v & 8) != 0
	var act_bits: int = (v >> 4) & 3
	var action := "light" if act_bits == 1 else ("heavy" if act_bits == 2 else ("special" if act_bits == 3 else ""))
	return {"moveDir": move_dir, "jump": jump, "crouch": crouch, "action": action}


# Encode a full per-tick input log (Array of input dicts) to a replay string.
static func encode_log(log: Array) -> String:
	var s := ""
	for i in log:
		s += encode_input(i)
	return s
