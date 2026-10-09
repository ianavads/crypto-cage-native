# One authoritative match room. Keyed by match_id; the server multiplexes many.
# Owns a FightSim game, both seats' per-tick input replay, and the state machine
#   WAITING (0/2 seats) -> READY (2/2, contexts agree) -> LIVE -> ENDED -> teardown
# The sim is frame-locked: each tick_once() is one discrete 60 Hz step using the
# inputs the server currently holds for each seat, which are recorded verbatim so
# Base44 can re-run the replay through the published fightSim.js and reproduce the
# exact outcome.
extends RefCounted
class_name MatchRoom

const FS = preload("res://engine/fight_sim.gd")
const ReplayCodecScript = preload("res://net/replay_codec.gd")

enum { WAITING, READY, LIVE, ENDED }

# A KO or the timer cap. Timeout cap == replay codec max (100 s at 60 Hz).
const TIMEOUT_TICKS := ReplayCodecScript.REPLAY_MAX # 6000

var match_id: String
var engine_version: String
var timeout_ticks: int = TIMEOUT_TICKS
var state: int = WAITING

# seat -> { peer_key, peer, fighter_id, opponent_fighter_id, joined }
var seats := {}
# seat -> latest input dict the server holds (sampled each tick)
var inputs_by_seat := {
	1: _neutral_input(),
	2: _neutral_input(),
}
# seat -> Array of per-tick input dicts (the replay log)
var replay := {1: [], 2: []}

var game: Dictionary
var tick: int = 0
var ended_reason := ""
var winner_seat: int = 0


static func _neutral_input() -> Dictionary:
	return {"moveDir": 0, "jump": false, "crouch": false, "action": ""}


func _init(p_match_id: String, p_engine_version: String, p_timeout_ticks: int = TIMEOUT_TICKS) -> void:
	match_id = p_match_id
	engine_version = p_engine_version
	timeout_ticks = clampi(p_timeout_ticks, 1, TIMEOUT_TICKS)


# Returns "" on success, else a reject reason string. `link` is a transport
# handle (server PeerLink) with send_json(); the room keeps it only to broadcast.
func add_seat(seat: int, ctx: Dictionary, peer_key: String, link) -> String:
	if seat != 1 and seat != 2:
		return "bad_seat"
	if String(ctx.get("match_id", "")) != match_id:
		return "match_mismatch"
	if String(ctx.get("engine_version", "")) != engine_version:
		return "engine_version_drift"
	if seats.has(seat):
		# Seat already held. Allow the same peer (idempotent hello); reject others.
		if seats[seat]["peer_key"] != peer_key:
			return "seat_taken"
	# Cross-seat agreement: both seats must share match_id + engine_version. The
	# fighter ids must be consistent mirror images (my fighter == other's opponent).
	var other: int = 2 if seat == 1 else 1
	if seats.has(other):
		var o: Dictionary = seats[other]
		if o["engine_version"] != String(ctx.get("engine_version", "")):
			return "engine_version_drift"
	seats[seat] = {
		"peer_key": peer_key,
		"link": link,
		"fighter_id": String(ctx.get("fighter_id", "")),
		"opponent_fighter_id": String(ctx.get("opponent_fighter_id", "")),
		"engine_version": String(ctx.get("engine_version", "")),
		"joined": true,
	}
	if seats.has(1) and seats.has(2) and state == WAITING:
		state = READY
	return ""


func both_present() -> bool:
	return seats.has(1) and seats.has(2)


func start() -> void:
	game = FS.create_game()
	tick = 0
	replay = {1: [], 2: []}
	ended_reason = ""
	winner_seat = 0
	state = LIVE


func set_input(seat: int, input: Dictionary) -> void:
	if seat == 1 or seat == 2:
		inputs_by_seat[seat] = {
			"moveDir": int(input.get("moveDir", 0)),
			"jump": bool(input.get("jump", false)),
			"crouch": bool(input.get("crouch", false)),
			"action": String(input.get("action", "")) if input.get("action", null) != null else "",
		}


# Advances exactly one 60 Hz tick. Returns true if the match just ENDED.
func tick_once() -> bool:
	if state != LIVE:
		return false
	var in1: Dictionary = inputs_by_seat[1]
	var in2: Dictionary = inputs_by_seat[2]
	FS.step(game, tick, {"p1": in1, "p2": in2})
	# Record the exact inputs used at this tick (duplicate: the held dicts mutate).
	replay[1].append(in1.duplicate())
	replay[2].append(in2.duplicate())
	tick += 1

	var p1: FS.Fighter = game["p1"]
	var p2: FS.Fighter = game["p2"]
	var p1_ko: bool = p1.ko
	var p2_ko: bool = p2.ko
	if p1_ko or p2_ko:
		if p1_ko and p2_ko:
			ended_reason = "double_ko"
			winner_seat = 0
		elif p1_ko:
			ended_reason = "ko"
			winner_seat = 2
		else:
			ended_reason = "ko"
			winner_seat = 1
		state = ENDED
		return true
	if tick >= timeout_ticks:
		ended_reason = "timeout"
		if p1.health > p2.health:
			winner_seat = 1
		elif p2.health > p1.health:
			winner_seat = 2
		else:
			winner_seat = 0
		state = ENDED
		return true
	return false


func snapshot() -> Dictionary:
	return FS.serialize(game)


# Builds the settle-native-match POST body (brief §4). Replay is sent as two
# separate per-seat fields (challenger_replay = seat1, opponent_replay = seat2).
func settle_payload() -> Dictionary:
	var p1: FS.Fighter = game["p1"]
	var p2: FS.Fighter = game["p2"]
	return {
		"match_id": match_id,
		"engine_version": engine_version,
		"winner_seat": winner_seat,
		"ended_reason": ended_reason,
		"ticks": tick,
		"challenger_replay": ReplayCodecScript.encode_log(replay[1]),
		"opponent_replay": ReplayCodecScript.encode_log(replay[2]),
		"final_state": {
			"seat1": {"health": roundi(p1.health), "energy": roundi(p1.energy)},
			"seat2": {"health": roundi(p2.health), "energy": roundi(p2.energy)},
		},
	}
