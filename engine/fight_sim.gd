# © 2026 Ian W Thompson. Author & Owner: Ian W Thompson.
# Licensed under the MIT License — attribution must be preserved in all copies.
# Part of Crypto Cage Combat. Published verbatim on the /fight-engine page.
#
# Deterministic, tick-based fight simulation — the AUTHORITATIVE physics the
# MatchRoom referee actor runs for online matches. GDScript port of the canonical
# base44/shared/fightSim.js. Ported LITERALLY: same IEEE-754 double arithmetic,
# no RNG, no wall-clock time, no transcendental functions — so a run here
# reproduces the published JS engine bit-for-bit (the /fight-engine audit bar).
#   • no wall-clock timestamps — a server-owned integer `tick` drives everything;
#   • no randomness in the core — identical inputs => identical runs;
#   • fixed DT per step so physics never drifts with machine speed.
# Online clients never run this authoritatively; they only render the snapshots
# the referee broadcasts.
#
# NOTE ON DETERMINISM: GDScript `float` is the same IEEE-754 double as a JS
# `Number`. The engine uses only +, -, *, /, abs, min, max and a sign() helper —
# all deterministic and identical across JS and GDScript. State is NOT rounded to
# integers: rounding would diverge from the published JS source and fail the
# settlement re-run. Do not add rounding to the authoritative state.

extends RefCounted
class_name FightSim

# FNV-1a (8 hex) of the published base44/shared/fightSim.js from
# GET /functions/get-engine-source. MUST equal the seat JWT's engine_version.
# Left empty on purpose — do NOT guess the hash; the deployer/server sets it from
# the current EngineRelease. See get_engine_version().
const ENGINE_VERSION := ""

const TICK_HZ := 60
const DT := 1.0 / TICK_HZ # seconds per tick (fixed)

const STAGE := {"min": 8, "max": 92}
const CONTACT := 14 # sized to on-screen sprite bodies; inside light-strike range
# Clean gap used when a jump lands on/near the opponent (see JS comment).
const LAND_GAP := 24
const WALK := 27
const WALK_BACK := 20
const JUMP_V := 88
const GRAVITY := 190
const JUMP_FORWARD := 30 # committed horizontal speed of a forward/back jump
const ENERGY_REGEN := 14
const SPECIAL_COOLDOWN := 120

# Durations in TICKS. impact: 1 light · 2 heavy · 3 launcher.
const ATTACKS := {
	"jab":      {"startup": 4,  "active": 5,  "recovery": 8,  "reach": 20, "ideal": 12, "window": 6, "min": 12, "dmg": 5,  "knock": 3,  "type": "high",     "gain": 7, "impact": 1, "lockout": 4},
	"lowpoke":  {"startup": 5,  "active": 5,  "recovery": 12, "reach": 21, "ideal": 14, "window": 6, "min": 12, "dmg": 6,  "knock": 3,  "type": "low",      "gain": 6, "impact": 1, "lockout": 6},
	"overhead": {"startup": 14, "active": 6,  "recovery": 22, "reach": 25, "ideal": 19, "window": 6, "min": 15, "dmg": 11, "knock": 9,  "type": "overhead", "gain": 9, "impact": 2, "lockout": 14, "launch": 16},
	"uppercut": {"startup": 9,  "active": 7,  "recovery": 30, "reach": 22, "ideal": 16, "window": 4, "min": 15, "dmg": 13, "knock": 18, "type": "launcher", "gain": 0, "impact": 3, "lockout": 18, "launch": 42},
	"jmpLight": {"startup": 3,  "active": 14, "recovery": 0,  "reach": 21, "ideal": 15, "window": 7, "min": 12, "dmg": 7,  "knock": 4,  "type": "overhead", "impact": 1, "lockout": 5},
	"jmpHeavy": {"startup": 4,  "active": 16, "recovery": 0,  "reach": 24, "ideal": 18, "window": 7, "min": 13, "dmg": 11, "knock": 7,  "type": "overhead", "impact": 2, "lockout": 8},
	"special":  {"startup": 14, "active": 0,  "recovery": 29, "cost": 100, "impact": 3, "lockout": 12, "proj": {"speed": 74, "dmg": 18, "knock": 11, "impact": 3}},
}

const HITSTUN := {1: 6, 2: 14, 3: 28}
const ATTACK_STATES := {"jab": true, "overhead": true, "lowpoke": true, "uppercut": true, "jmpLight": true, "jmpHeavy": true}

# Limb-tip model: perfect when the tip finishes on the body at full extension.
const BODY := 4.5


# Fighter is an object (not a Dictionary) so identity comparisons (att === g.p1,
# g.combo.attacker === att) port correctly: GDScript compares Dictionaries by
# value but objects by reference, matching JS ===.
class Fighter:
	var x: float
	var y: float
	var vx: float
	var vy: float
	var facing: float
	var health: float
	var energy: float
	var state: String
	var stateTick: int
	var hitstunUntil: float
	var strikeLockUntil: float
	var specialLockUntil: float
	var blockHigh: bool
	var blockLow: bool
	var duck: bool
	var crouch: bool
	var onGround: bool
	var flash: float
	var attackHit: bool
	var projSpawned: bool
	var ko: bool
	var jumpDir: float
	var slideSide: float
	var wallBounce: bool
	# Dynamic properties the JS object grows at runtime:
	var prevX: float
	var justLanded: bool
	var landSide: float

	func _init(x_: float, facing_: float) -> void:
		x = x_
		y = 0.0
		vx = 0.0
		vy = 0.0
		facing = facing_
		health = 100.0
		energy = 0.0
		state = "idle"
		stateTick = 0
		hitstunUntil = 0.0
		strikeLockUntil = 0.0
		specialLockUntil = 0.0
		blockHigh = false
		blockLow = false
		duck = false
		crouch = false
		onGround = true
		flash = 0.0
		attackHit = false
		projSpawned = false
		ko = false
		jumpDir = 0.0
		slideSide = 0.0
		wallBounce = false
		prevX = x_
		justLanded = false
		landSide = 0.0


# Math.sign — returns -1, 0 or 1 for finite values (matches JS for our usage).
static func _sign(v: float) -> float:
	if v > 0.0:
		return 1.0
	elif v < 0.0:
		return -1.0
	return 0.0


static func create_fighter(x: float, facing: float) -> Fighter:
	return Fighter.new(x, facing)


static func create_game() -> Dictionary:
	return {
		"tick": 0,
		"p1": create_fighter(32, 1),
		"p2": create_fighter(68, -1),
		"projectiles": [],
		"hitstopUntil": 0,
		"shake": 0,
		"sparks": [],
		"combo": {"attacker": null, "count": 0, "until": 0},
		"topSide": null,
		"topUntil": 0,
	}


static func can_act(f: Fighter, tick: int) -> bool:
	if f.ko:
		return false
	if tick < f.hitstunUntil:
		return false
	var a = ATTACKS.get(f.state, null)
	if a:
		return tick >= f.stateTick + a["startup"] + a.get("active", 0) + a["recovery"]
	return true


static func _resolve_move(f: Fighter, action: String) -> String:
	if action == "special":
		return "special"
	if not f.onGround:
		return "jmpHeavy" if action == "heavy" else "jmpLight"
	if f.crouch:
		return "uppercut" if action == "heavy" else "lowpoke"
	return "overhead" if action == "heavy" else "jab"


static func start_attack(f: Fighter, action: String, tick: int) -> bool:
	if not can_act(f, tick):
		return false
	var move := _resolve_move(f, action)
	var a = ATTACKS[move]
	if a.has("cost") and f.energy < a["cost"]:
		return false
	if move == "special" and (not f.onGround or tick < f.specialLockUntil):
		return false
	if a.has("cost"):
		f.energy -= a["cost"]
	f.state = move
	f.stateTick = tick
	f.attackHit = false
	f.projSpawned = false
	f.blockHigh = false
	f.blockLow = false
	f.duck = false
	f.strikeLockUntil = tick + a["startup"] + a.get("active", 0) + a["recovery"] + a.get("lockout", 0)
	return true


static func _register_impact(g: Dictionary, att: Fighter, def: Fighter, big: bool, blocking: bool, tier: String = "perfect") -> void:
	var tick: int = g["tick"]
	g["hitstopUntil"] = tick + (3 if blocking else (7 if big else 4))
	g["shake"] = 4 if blocking else (13 if big else 8)
	var color := "facc15"
	var sparkBig := big
	if blocking:
		color = "60a5fa"
		sparkBig = false
	elif tier == "glancing":
		color = "e5e7eb"
		sparkBig = false
	elif tier == "perfect":
		sparkBig = true
	g["sparks"].append({"x": def.x, "y": def.y + 11, "life": 1, "big": sparkBig, "color": color})
	if g["sparks"].size() > 8:
		g["sparks"].pop_front()
	var combo: Dictionary = g["combo"]
	if is_same(combo["attacker"], att) and tick < combo["until"]:
		combo["count"] += 1
	else:
		combo["attacker"] = att
		combo["count"] = 1
	combo["until"] = tick + 54
	combo["x"] = def.x
	combo["y"] = def.y
	g["topSide"] = "p1" if is_same(att, g["p1"]) else "p2"
	g["topUntil"] = tick + 31


static func _resolve_defense(def: Fighter, atk: Dictionary) -> Dictionary:
	var t = atk["type"]
	if t == "high":
		if def.crouch:
			return {"whiff": true}
		if def.blockHigh:
			return {"blocked": true}
		return {"hit": true}
	if t == "low":
		if def.blockLow:
			return {"blocked": true}
		return {"hit": true}
	if t == "overhead":
		if def.blockHigh and not def.crouch:
			return {"blocked": true}
		return {"hit": true}
	if def.blockHigh and not def.crouch:
		return {"blocked": true}
	return {"hit": true}


static func _strike_tier(atk: Dictionary, dist: float) -> String:
	var mn = atk.get("min", 0)
	if dist > atk["reach"] or dist < mn:
		return "whiff"
	return "perfect" if dist >= atk["reach"] - BODY else "glancing"


static func _push_distance(atk: Dictionary, tier: String, blocking: bool) -> float:
	if blocking:
		return 2.7
	if tier == "perfect":
		return 6 + atk.get("impact", 1) * 3
	return 3.75


static func _push_apart(att: Fighter, def: Fighter, dist: float, dir: float) -> void:
	var room: float = max(0.0, (STAGE["max"] - def.x) if dir > 0 else (def.x - STAGE["min"]))
	var defMove: float = min(dist, room)
	def.vx = dir * defMove * 9
	att.vx = -dir * ((dist - defMove) + dist * 0.15) * 9


# Put `lander` exactly `gap` from `opp` on `side`; at a wall the opponent gives room.
static func _place_apart(lander: Fighter, opp: Fighter, side: float, gap: float = CONTACT) -> void:
	var x: float = opp.x + side * gap
	if x > STAGE["max"]:
		x = STAGE["max"]
		opp.x = x - CONTACT
	elif x < STAGE["min"]:
		x = STAGE["min"]
		opp.x = x + CONTACT
	lander.x = x
	if _sign(lander.vx) == -side:
		lander.vx = 0
	if _sign(opp.vx) == side:
		opp.vx = 0
	lander.facing = -side
	opp.facing = side


static func _apply_hit(att: Fighter, def: Fighter, move: String, tick: int, g: Dictionary) -> void:
	var atk: Dictionary = ATTACKS[move]
	var res := _resolve_defense(def, atk)
	if res.get("whiff", false):
		return # ducked — no effect
	var blocking: bool = res.get("blocked", false)
	var dist: float = abs(def.x - att.x)
	var tier := _strike_tier(atk, dist)
	if tier == "whiff":
		return # too close OR out of reach — clean whiff
	att.attackHit = true
	var perfect := tier == "perfect"
	var scale: float = 1 if perfect else 0.5
	var dir: float = 1 if def.x >= att.x else -1
	var dmg: float = atk["dmg"] * 0.12 if blocking else atk["dmg"] * scale
	def.health = max(0.0, def.health - dmg)
	att.energy = min(100.0, att.energy + atk.get("gain", 0))
	_push_apart(att, def, _push_distance(atk, tier, blocking), dir)
	var stun: float = HITSTUN.get(atk["impact"], 9) * (0.5 if blocking else (1 if perfect else 0.5))
	def.hitstunUntil = tick + stun
	def.state = "hit"
	def.flash = 1
	def.blockHigh = false
	def.blockLow = false
	def.duck = false
	var big: bool = atk["impact"] >= 2
	_register_impact(g, att, def, big, blocking, tier)
	if atk.has("launch") and not blocking:
		def.vy = atk["launch"] * (1 if perfect else 0.55)
		def.onGround = false
	if def.health <= 0:
		def.ko = true
		def.state = "ko"
		def.vx = dir * 34


static func _apply_projectile_hit(def: Fighter, p: Dictionary, tick: int, g: Dictionary) -> bool:
	if def.duck:
		return false
	var sp: Dictionary = ATTACKS["special"]["proj"]
	var dir := _sign(p["vx"])
	if dir == 0:
		dir = 1
	var blocking: bool = def.blockHigh or def.blockLow
	var dmg: float = sp["dmg"] * 0.12 if blocking else sp["dmg"]
	def.health = max(0.0, def.health - dmg)
	def.state = "hit"
	def.flash = 1
	def.blockHigh = false
	def.blockLow = false
	def.duck = false
	_register_impact(g, (g["p1"] if p["owner"] == "p1" else g["p2"]), def, true, blocking, "perfect")
	g["sparks"].append({"x": def.x, "y": def.y + 11, "life": 1, "ring": true, "owner": p["owner"]})
	if blocking:
		# GUARD CRUSH: guard holds but the blast skids the defender back hard.
		def.vx = dir * 5 * 9
		def.hitstunUntil = tick + 13
	else:
		# POWER BLAST: blown across the cage, wall slam + rebound.
		def.vy = 40
		def.onGround = false
		def.jumpDir = 0
		def.vx = dir * 16 * 9
		def.wallBounce = true
		def.hitstunUntil = tick + 45
		g["hitstopUntil"] = tick + 10
		g["shake"] = 18
		g["superFlash"] = {"until": tick + 19, "owner": p["owner"]}
	if def.health <= 0:
		def.ko = true
		def.state = "ko"
	return true


static func _update_fighter(f: Fighter, opp: Fighter, input: Dictionary, tick: int, g: Dictionary) -> void:
	var moveDir: int = int(input.get("moveDir", 0))
	var jump: bool = bool(input.get("jump", false))
	var crouch: bool = bool(input.get("crouch", false))
	var action: String = str(input.get("action", "")) if input.get("action", null) != null else ""

	f.flash = max(0.0, f.flash - DT * 4)
	if f.ko:
		f.state = "ko"

	if f.state == "hit" and tick >= f.hitstunUntil:
		f.state = "idle" if f.onGround else "jump"
	var ra = ATTACKS.get(f.state, null)
	if ra and tick >= f.stateTick + ra["startup"] + ra.get("active", 0) + ra["recovery"]:
		f.state = "idle" if f.onGround else "jump"

	var free := can_act(f, tick)
	var toward: float = _sign(opp.x - f.x)
	if toward == 0:
		toward = f.facing
	var holdingBack: bool = moveDir != 0 and _sign(moveDir) != toward
	f.blockHigh = false
	f.blockLow = false
	f.duck = false
	f.crouch = false

	# Always face the opponent — facing locks only during hitstun.
	if not f.ko and tick >= f.hitstunUntil:
		f.facing = toward

	if free and not f.ko:
		if jump and f.onGround:
			f.vy = JUMP_V
			f.onGround = false
			f.state = "jump"
			f.slideSide = 0
			f.jumpDir = moveDir # committed forward/back arc; neutral = straight up
		else:
			if action:
				if start_attack(f, action, tick):
					var a = ATTACKS.get(f.state, null)
					if a:
						g["topSide"] = "p1" if is_same(f, g["p1"]) else "p2"
						g["topUntil"] = tick + a["startup"] + a.get("active", 0) + 15
			if not ATTACKS.has(f.state):
				if f.onGround:
					if crouch:
						f.crouch = true
						if holdingBack:
							f.blockLow = true
							f.state = "blockLow"
						else:
							f.duck = true
							f.state = "crouch"
					elif holdingBack:
						f.blockHigh = true
						f.state = "block"
						f.x += moveDir * WALK_BACK * DT
					elif moveDir != 0:
						f.state = "walk"
						f.x += moveDir * WALK * DT
					else:
						f.state = "idle"
				else:
					f.state = "jump"

	# Recovery steering: once a grounded strike's active window passes, the
	# fighter can walk/back-off (reduced speed) through recovery.
	var ca = ATTACKS.get(f.state, null)
	if not free and ca and not f.ko and f.onGround and moveDir != 0 and tick >= f.hitstunUntil \
			and tick - f.stateTick >= ca["startup"] + ca.get("active", 0):
		f.x += moveDir * (WALK_BACK if holdingBack else WALK) * 0.65 * DT

	if not f.onGround:
		f.vy -= GRAVITY * DT
		f.y += f.vy * DT
		# Air steering only on a voluntary jump (hitstun keeps a launched fighter
		# unsteerable). The committed arc carries; the player can brake/drift.
		if tick >= f.hitstunUntil and not f.wallBounce:
			if f.jumpDir:
				var steer: float = moveDir * JUMP_FORWARD * 0.7
				f.x += (f.jumpDir * JUMP_FORWARD + steer) * DT
			elif moveDir != 0:
				f.x += moveDir * JUMP_FORWARD * 0.5 * DT # neutral jump drift
		elif f.jumpDir:
			f.x += f.jumpDir * JUMP_FORWARD * DT # committed arc continues through hitstun air attacks
		if f.y <= 0:
			f.landSide = _sign(f.jumpDir) if f.jumpDir else -(f.facing if f.facing != 0 else 1)
			f.y = 0
			f.vy = 0
			f.vx = 0
			f.onGround = true
			f.jumpDir = 0
			f.wallBounce = false
			f.justLanded = true # resolveCollision slides only the lander
			if f.state == "jump" or ATTACKS.has(f.state):
				f.state = "idle"

	f.x += f.vx * DT
	f.vx *= max(0.0, 1 - 9 * DT)
	f.x = max(float(STAGE["min"]), min(float(STAGE["max"]), f.x))
	if f.wallBounce and (f.x <= STAGE["min"] or f.x >= STAGE["max"]):
		f.vx = -f.vx * 0.4
		f.vy = max(f.vy, 24.0)
		f.wallBounce = false
		g["shake"] = 12
		g["sparks"].append({"x": f.x, "y": f.y + 11, "life": 1, "big": true, "color": "f97316"})

	f.energy = min(100.0, f.energy + ENERGY_REGEN * DT)

	var atk = ATTACKS.get(f.state, null)
	if atk and ATTACK_STATES.has(f.state) and not f.attackHit:
		var t: int = tick - f.stateTick
		if t >= atk["startup"] and t < atk["startup"] + atk["active"]:
			var dx: float = opp.x - f.x
			var air := not f.onGround
			if abs(dx) <= atk["reach"] and abs(opp.y - f.y) <= (24 if air else 13):
				_apply_hit(f, opp, f.state, tick, g)

	if f.state == "special" and not f.projSpawned and tick - f.stateTick >= ATTACKS["special"]["startup"]:
		g["projectiles"].append({
			"x": f.x + f.facing * 9,
			"y": f.y + 9,
			"vx": f.facing * ATTACKS["special"]["proj"]["speed"],
			"owner": "p1" if is_same(f, g["p1"]) else "p2",
			"hit": false,
		})
		f.projSpawned = true
		# Named special cooldown the instant the projectile launches.
		f.specialLockUntil = tick + SPECIAL_COOLDOWN


static func _step_projectiles(g: Dictionary, tick: int) -> void:
	for p in g["projectiles"]:
		p["x"] += p["vx"] * DT
		var target: Fighter = g["p2"] if p["owner"] == "p1" else g["p1"]
		if not p["hit"] and abs(p["x"] - target.x) <= 7 and abs(p["y"] - (target.y + 9)) <= 16:
			if _apply_projectile_hit(target, p, tick, g):
				p["hit"] = true
	var kept := []
	for p in g["projectiles"]:
		if not p["hit"] and p["x"] > STAGE["min"] - 3 and p["x"] < STAGE["max"] + 3:
			kept.append(p)
	g["projectiles"] = kept


static func _resolve_collision(g: Dictionary) -> void:
	var a: Fighter = g["p1"]
	var b: Fighter = g["p2"]
	if not a.onGround or not b.onGround:
		a.slideSide = 0
		b.slideSide = 0
		return
	var dx: float = b.x - a.x
	var dist: float = abs(dx)
	if dist >= CONTACT:
		a.slideSide = 0
		b.slideSide = 0
		return
	var sign_: float = 1 if dx >= 0 else -1
	var overlap: float = CONTACT - dist

	# Cross-up landing: place only the lander, on its real side.
	if a.justLanded or b.justLanded:
		var lander: Fighter = a if a.justLanded else b
		var opp: Fighter = b if a.justLanded else a
		var rel: float = lander.x - opp.x
		var side: float = _sign(rel) if abs(rel) > 0.5 else (lander.landSide if lander.landSide else 1)
		_place_apart(lander, opp, side, LAND_GAP)
		return

	# The fighter who moved INTO the other absorbs the overlap — no shove/drag.
	var inA: float = max(0.0, (a.x - a.prevX) * sign_)
	var inB: float = max(0.0, (b.prevX - b.x) * sign_)
	var shareA: float = inA / (inA + inB) if inA + inB > 0 else 0.5
	var aTarget: float = a.x - sign_ * overlap * shareA
	var bTarget: float = b.x + sign_ * overlap * (1 - shareA)
	if aTarget < STAGE["min"]:
		var extra: float = STAGE["min"] - aTarget
		a.x = STAGE["min"]
		b.x = min(float(STAGE["max"]), bTarget + extra)
	elif bTarget > STAGE["max"]:
		var extra: float = bTarget - STAGE["max"]
		b.x = STAGE["max"]
		a.x = max(float(STAGE["min"]), aTarget - extra)
	else:
		a.x = aTarget
		b.x = bTarget
	if _sign(a.vx) == sign_:
		a.vx *= 0.2
	if _sign(b.vx) == -sign_:
		b.vx *= 0.2


static func _decay_effects(g: Dictionary) -> void:
	g["shake"] = max(0.0, float(g.get("shake", 0)) - 1)
	if g.has("sparks") and g["sparks"]:
		for s in g["sparks"]:
			s["life"] -= (3.2 / TICK_HZ)
		var kept := []
		for s in g["sparks"]:
			if s["life"] > 0:
				kept.append(s)
		g["sparks"] = kept


# inputs: { p1: {moveDir,jump,crouch,action}, p2: {...} }
static func step(g: Dictionary, tick: int, inputs: Dictionary) -> void:
	g["tick"] = tick
	if tick < g.get("hitstopUntil", 0):
		_decay_effects(g)
		return
	var p1: Fighter = g["p1"]
	var p2: Fighter = g["p2"]
	p1.prevX = p1.x
	p2.prevX = p2.x
	_update_fighter(p1, p2, inputs["p1"], tick, g)
	_update_fighter(p2, p1, inputs["p2"], tick, g)
	_resolve_collision(g)
	p1.justLanded = false
	p2.justLanded = false
	_step_projectiles(g, tick)
	_decay_effects(g)


# JS Number.toFixed(n) then +parse — render-snapshot rounding only (NOT part of
# the determinism boundary; the auditor re-runs inputs, not snapshots).
static func _fx(v: float, n: int) -> float:
	return snappedf(v, pow(0.1, n))


# Compact snapshot for broadcasting to clients (the renderer interpolates these).
static func serialize(g: Dictionary) -> Dictionary:
	var f := func(p: Fighter) -> Dictionary:
		return {
			"x": _fx(p.x, 3), "y": _fx(p.y, 3), "vx": _fx(p.vx, 3), "vy": _fx(p.vy, 3),
			"facing": p.facing, "health": _fx(p.health, 2), "energy": _fx(p.energy, 1),
			"state": p.state, "stateTick": p.stateTick, "flash": _fx(p.flash, 2), "ko": p.ko,
			"crouch": p.crouch, "blockHigh": p.blockHigh, "blockLow": p.blockLow,
		}
	var projs := []
	for p in g["projectiles"]:
		projs.append({"x": _fx(p["x"], 3), "y": _fx(p["y"], 3), "owner": p["owner"]})
	var sparks := []
	for s in g["sparks"]:
		sparks.append({
			"x": _fx(s["x"], 3), "y": _fx(s["y"], 3), "life": _fx(s["life"], 2),
			"big": s.get("big", null), "color": s.get("color", null),
			"ring": s.get("ring", null), "owner": s.get("owner", null),
		})
	var tick: int = g["tick"]
	var flash = null
	var superFlash = g.get("superFlash", null)
	if superFlash != null and tick < superFlash["until"]:
		flash = {"t": _fx(float(superFlash["until"] - tick) / 19.0, 2), "owner": superFlash["owner"]}
	var combo: Dictionary = g["combo"]
	return {
		"tick": tick,
		"p1": f.call(g["p1"]), "p2": f.call(g["p2"]),
		"projectiles": projs,
		"shake": _fx(float(g["shake"]), 2),
		"sparks": sparks,
		"flash": flash,
		"comboCount": combo["count"] if combo["count"] > 1 and tick < combo["until"] else 0,
	}


# The bundled engine version (FNV-1a of the published JS). Empty until the
# deployer pins it from the current EngineRelease; the server also accepts an
# override via env/arg so a re-version doesn't require editing this file.
static func get_engine_version() -> String:
	return ENGINE_VERSION
