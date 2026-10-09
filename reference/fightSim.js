// © 2026 Ian W Thompson. Author & Owner: Ian W Thompson.
// Licensed under the MIT License — attribution must be preserved in all copies.
// Part of Crypto Cage Combat. Published verbatim on the /fight-engine page.
//
// Deterministic, tick-based fight simulation — the AUTHORITATIVE physics the
// MatchRoom referee actor runs for online matches. Mirrors the gameplay rules
// of the real-time fightEngine.js but is frame-locked:
//   • no wall-clock timestamps — a server-owned integer `tick` drives everything;
//   • no Math.random in the core — identical inputs ⇒ identical runs;
//   • fixed DT per step so physics never drifts with machine speed.
// Online clients never run this; they only render the snapshots the referee
// broadcasts. Local / AI play keeps using fightEngine.js.

export const TICK_HZ = 60;
const DT = 1 / TICK_HZ; // seconds per tick (fixed)

export const STAGE = { min: 8, max: 92 };
export const CONTACT = 14; // sized to on-screen sprite bodies; inside light-strike range
// Clean gap used when a jump lands on/near the opponent, so a close landing
// separates PAST rest-contact distance instead of instantly re-gluing. Bare
// CONTACT lets a just-landed fighter walk straight back into the foe the next
// frame (the close-landing "sticking" drag); the buffer gives breathing room.
export const LAND_GAP = 24;
export const WALK = 27;
export const WALK_BACK = 20;
export const JUMP_V = 88;
export const GRAVITY = 190;
export const JUMP_FORWARD = 30; // committed horizontal speed of a forward/back jump (cross-overs). Neutral jump = straight up.
export const ENERGY_REGEN = 14;
// Hard floor (in ticks, ~2s at 60Hz) on how soon a fighter may launch another
// special after one fires. The primary anti-spam gate is the energy gauge
// (specials cost 100, ~7s to recharge from empty), but this named lock
// guarantees a minimum gap even if energy is gained back unusually fast.
export const SPECIAL_COOLDOWN = 120;

// Durations in TICKS (ms / 16.67, rounded). impact: 1 light · 2 heavy · 3
// launcher — drives hitstun + post-strike lockout so strikes must be timed.
export const ATTACKS = {
  jab:      { startup: 4,  active: 5,  recovery: 8,  reach: 20, ideal: 12, window: 6, min: 12, dmg: 5,  knock: 3,  type: "high",     gain: 7, impact: 1, lockout: 4 },
  lowpoke:  { startup: 5,  active: 5,  recovery: 12, reach: 21, ideal: 14, window: 6, min: 12, dmg: 6,  knock: 3,  type: "low",      gain: 6, impact: 1, lockout: 6 },
  overhead: { startup: 14, active: 6,  recovery: 22, reach: 25, ideal: 19, window: 6, min: 15, dmg: 11, knock: 9,  type: "overhead", gain: 9, impact: 2, lockout: 14, launch: 16 },
  uppercut: { startup: 9,  active: 7,  recovery: 30, reach: 22, ideal: 16, window: 4, min: 15, dmg: 13, knock: 18, type: "launcher", gain: 0, impact: 3, lockout: 18, launch: 42 },
  jmpLight: { startup: 3,  active: 14, recovery: 0,  reach: 21, ideal: 15, window: 7, min: 12, dmg: 7,  knock: 4,  type: "overhead", impact: 1, lockout: 5 },
  jmpHeavy: { startup: 4,  active: 16, recovery: 0,  reach: 24, ideal: 18, window: 7, min: 13, dmg: 11, knock: 7,  type: "overhead", impact: 2, lockout: 8 },
  special:  { startup: 14, active: 0,  recovery: 29, cost: 100, impact: 3, lockout: 12, proj: { speed: 74, dmg: 18, knock: 11, impact: 3 } },
};

const HITSTUN = { 1: 6, 2: 14, 3: 28 };
const ATTACK_STATES = new Set(["jab", "overhead", "lowpoke", "uppercut", "jmpLight", "jmpHeavy"]);

// Limb-tip model (mirrors fightEngine.js): perfect when the tip finishes on the
// body at full extension, glancing when the opponent is inside the reach.
const BODY = 4.5;
// Put `lander` exactly CONTACT from `opp` on `side`; at a wall the opponent gives room.
function placeApart(lander, opp, side, gap = CONTACT) {
  let x = opp.x + side * gap;
  if (x > STAGE.max) { x = STAGE.max; opp.x = x - CONTACT; }
  else if (x < STAGE.min) { x = STAGE.min; opp.x = x + CONTACT; }
  lander.x = x;
  if (Math.sign(lander.vx) === -side) lander.vx = 0;
  if (Math.sign(opp.vx) === side) opp.vx = 0;
  lander.facing = -side;
  opp.facing = side;
}
function strikeTier(atk, dist) {
  const min = atk.min || 0;
  if (dist > atk.reach || dist < min) return "whiff";
  return dist >= atk.reach - BODY ? "perfect" : "glancing";
}

// Guaranteed separation per landed strike (stage-%).
function pushDistance(atk, tier, blocking) {
  if (blocking) return 2.7;
  if (tier === "perfect") return 6 + (atk.impact || 1) * 3;
  return 3.75;
}

// Push as velocity; when the defender is cornered the leftover recoils the attacker.
function pushApart(att, def, dist, dir) {
  const room = Math.max(0, dir > 0 ? STAGE.max - def.x : def.x - STAGE.min);
  const defMove = Math.min(dist, room);
  def.vx = dir * defMove * 9;
  att.vx = -dir * ((dist - defMove) + dist * 0.15) * 9;
}

export function createFighter(x, facing) {
  return {
    x, y: 0, vx: 0, vy: 0, facing,
    health: 100, energy: 0,
    state: "idle", stateTick: 0, hitstunUntil: 0, strikeLockUntil: 0, specialLockUntil: 0,
    blockHigh: false, blockLow: false, duck: false, crouch: false,
    onGround: true, flash: 0, attackHit: false, projSpawned: false, ko: false, jumpDir: 0, slideSide: 0, wallBounce: false,
  };
}

export function createGame() {
  return {
    tick: 0,
    p1: createFighter(32, 1),
    p2: createFighter(68, -1),
    projectiles: [],
    hitstopUntil: 0,
    shake: 0,
    sparks: [],
    combo: { attacker: null, count: 0, until: 0 },
    topSide: null,
    topUntil: 0,
  };
}

export function canAct(f, tick) {
  if (f.ko) return false;
  if (tick < f.hitstunUntil) return false;
  const a = ATTACKS[f.state];
  if (a) return tick >= f.stateTick + a.startup + (a.active || 0) + a.recovery;
  return true;
}

function resolveMove(f, action) {
  if (action === "special") return "special";
  if (!f.onGround) return action === "heavy" ? "jmpHeavy" : "jmpLight";
  if (f.crouch) return action === "heavy" ? "uppercut" : "lowpoke";
  return action === "heavy" ? "overhead" : "jab";
}

export function startAttack(f, action, tick) {
  if (!canAct(f, tick)) return false;
  const move = resolveMove(f, action);
  const a = ATTACKS[move];
  if (a.cost && f.energy < a.cost) return false;
  if (move === "special" && (!f.onGround || tick < (f.specialLockUntil || 0))) return false;
  if (a.cost) f.energy -= a.cost;
  f.state = move;
  f.stateTick = tick;
  f.attackHit = false;
  f.projSpawned = false;
  f.blockHigh = f.blockLow = f.duck = false;
  f.strikeLockUntil = tick + a.startup + (a.active || 0) + a.recovery + (a.lockout || 0);
  return true;
}

function registerImpact(g, att, def, big, blocking, tier = "perfect") {
  const tick = g.tick;
  g.hitstopUntil = tick + (blocking ? 3 : big ? 7 : 4);
  g.shake = blocking ? 4 : big ? 13 : 8;
  let color = "facc15";
  let sparkBig = !!big;
  if (blocking) { color = "60a5fa"; sparkBig = false; }
  else if (tier === "glancing") { color = "e5e7eb"; sparkBig = false; }
  else if (tier === "perfect") { sparkBig = true; }
  g.sparks.push({ x: def.x, y: (def.y || 0) + 11, life: 1, big: sparkBig, color });
  if (g.sparks.length > 8) g.sparks.shift();
  if (g.combo.attacker === att && tick < g.combo.until) g.combo.count += 1;
  else { g.combo.attacker = att; g.combo.count = 1; }
  g.combo.until = tick + 54;
  g.combo.x = def.x; g.combo.y = def.y || 0;
  g.topSide = att === g.p1 ? "p1" : "p2";
  g.topUntil = tick + 31;
}

function resolveDefense(def, atk) {
  const t = atk.type;
  if (t === "high") {
    if (def.crouch) return { whiff: true };
    if (def.blockHigh) return { blocked: true };
    return { hit: true };
  }
  if (t === "low") {
    if (def.blockLow) return { blocked: true };
    return { hit: true };
  }
  if (t === "overhead") {
    if (def.blockHigh && !def.crouch) return { blocked: true };
    return { hit: true };
  }
  if (def.blockHigh && !def.crouch) return { blocked: true };
  return { hit: true };
}

function applyHit(att, def, move, tick, g) {
  const atk = ATTACKS[move];
  const res = resolveDefense(def, atk);
  if (res.whiff) return;                           // ducked — no effect
  const blocking = res.blocked;
  const dist = Math.abs(def.x - att.x);
  const tier = strikeTier(atk, dist);
  if (tier === "whiff") return;                    // too close OR out of reach — clean whiff
  // Only a connecting strike (hit or block) consumes the hit window, so a
  // point-blank whiff can still land if spacing corrects mid-active.
  att.attackHit = true;
  const perfect = tier === "perfect";
  const scale = perfect ? 1 : 0.5;
  const dir = def.x >= att.x ? 1 : -1;
  const dmg = blocking ? atk.dmg * 0.12 : atk.dmg * scale;
  def.health = Math.max(0, def.health - dmg);
  att.energy = Math.min(100, att.energy + (atk.gain || 0));
  pushApart(att, def, pushDistance(atk, tier, blocking), dir);
  const stun = (HITSTUN[atk.impact] ?? 9) * (blocking ? 0.5 : perfect ? 1 : 0.5);
  def.hitstunUntil = tick + stun;
  def.state = "hit";
  def.flash = 1;
  def.blockHigh = def.blockLow = def.duck = false;
  const big = atk.impact >= 2;
  registerImpact(g, att, def, big, blocking, tier);
  if (atk.launch && !blocking) {
    def.vy = atk.launch * (perfect ? 1 : 0.55);
    def.onGround = false;
  }
  if (def.health <= 0) { def.ko = true; def.state = "ko"; def.vx = dir * 34; }
}

function applyProjectileHit(def, p, tick, g) {
  if (def.duck) return false;
  const sp = ATTACKS.special.proj;
  const dir = Math.sign(p.vx) || 1;
  const blocking = def.blockHigh || def.blockLow;
  const dmg = blocking ? sp.dmg * 0.12 : sp.dmg;
  def.health = Math.max(0, def.health - dmg);
  def.state = "hit";
  def.flash = 1;
  def.blockHigh = def.blockLow = def.duck = false;
  registerImpact(g, p.owner === "p1" ? g.p1 : g.p2, def, true, blocking, "perfect");
  g.sparks.push({ x: def.x, y: (def.y || 0) + 11, life: 1, ring: true, owner: p.owner });
  if (blocking) {
    // GUARD CRUSH: guard holds but the blast skids the defender back hard.
    def.vx = dir * 5 * 9;
    def.hitstunUntil = tick + 13;
  } else {
    // POWER BLAST: flash, blown across the cage, wall slam + rebound.
    def.vy = 40; def.onGround = false; def.jumpDir = 0;
    def.vx = dir * 16 * 9;
    def.wallBounce = true;
    def.hitstunUntil = tick + 45;
    g.hitstopUntil = tick + 10;
    g.shake = 18;
    g.superFlash = { until: tick + 19, owner: p.owner };
  }
  if (def.health <= 0) { def.ko = true; def.state = "ko"; }
  return true;
}

function updateFighter(f, opp, input, tick, g) {
  f.flash = Math.max(0, f.flash - DT * 4);
  if (f.ko) { f.state = "ko"; }

  if (f.state === "hit" && tick >= f.hitstunUntil) f.state = f.onGround ? "idle" : "jump";
  const ra = ATTACKS[f.state];
  if (ra && tick >= f.stateTick + ra.startup + (ra.active || 0) + ra.recovery) {
    f.state = f.onGround ? "idle" : "jump";
  }

  const free = canAct(f, tick);
  const toward = Math.sign(opp.x - f.x) || f.facing;
  const holdingBack = !!input.moveDir && Math.sign(input.moveDir) !== toward;
  f.blockHigh = false; f.blockLow = false; f.duck = false; f.crouch = false;

  // Always face the opponent — including mid-strike — so every strike resolves
  // toward the opponent even after a cross-up. Facing locks only during hitstun.
  if (!f.ko && tick >= f.hitstunUntil) f.facing = toward;

  if (free && !f.ko) {
    if (input.jump && f.onGround) {
      f.vy = JUMP_V; f.onGround = false; f.state = "jump"; f.slideSide = 0;
      f.jumpDir = input.moveDir || 0; // committed forward/back arc; neutral = straight up
    } else {
      if (input.action) {
        if (startAttack(f, input.action, tick)) {
          const a = ATTACKS[f.state];
          if (a) { g.topSide = f === g.p1 ? "p1" : "p2"; g.topUntil = tick + a.startup + (a.active || 0) + 15; }
        }
      }
      if (!ATTACKS[f.state]) {
        if (f.onGround) {
          if (input.crouch) {
            f.crouch = true;
            if (holdingBack) { f.blockLow = true; f.state = "blockLow"; }
            else { f.duck = true; f.state = "crouch"; }
          } else if (holdingBack) {
            f.blockHigh = true; f.state = "block";
            f.x += input.moveDir * WALK_BACK * DT;
          } else if (input.moveDir) {
            f.state = "walk"; f.x += input.moveDir * WALK * DT;
          } else {
            f.state = "idle";
          }
        } else {
          f.state = "jump";
        }
      }
    }
  }

  // Recovery steering: once a grounded strike's active window has passed, the
  // fighter can walk/back-off (reduced speed) through recovery instead of being
  // rooted. Striking itself stays gated by strikeLockUntil.
  const ca = ATTACKS[f.state];
  if (!free && ca && !f.ko && f.onGround && input.moveDir && tick >= f.hitstunUntil &&
      tick - f.stateTick >= ca.startup + (ca.active || 0)) {
    f.x += input.moveDir * (holdingBack ? WALK_BACK : WALK) * 0.65 * DT;
  }

  if (!f.onGround) {
    f.vy -= GRAVITY * DT;
    f.y += f.vy * DT;
    // Air steering (only on a voluntary jump — knockback/launch hitstun keeps
    // f.hitstunUntil ahead of tick, so launched/fireball-blasted fighters keep
    // their unsteerable trajectory). The committed arc carries; the player can
    // brake (hold back) or drift a neutral jump.
    if (tick >= f.hitstunUntil && !f.wallBounce) {
      if (f.jumpDir) {
        const steer = (input.moveDir || 0) * JUMP_FORWARD * 0.7;
        f.x += (f.jumpDir * JUMP_FORWARD + steer) * DT;
      } else if (input.moveDir) {
        f.x += input.moveDir * JUMP_FORWARD * 0.5 * DT; // neutral jump drift
      }
    } else if (f.jumpDir) {
      f.x += f.jumpDir * JUMP_FORWARD * DT; // committed arc continues through hitstun air attacks
    }
    if (f.y <= 0) {
      f.landSide = f.jumpDir ? Math.sign(f.jumpDir) : -(f.facing || 1);
      f.y = 0; f.vy = 0; f.vx = 0; f.onGround = true; f.jumpDir = 0; f.wallBounce = false;
      f.justLanded = true; // resolveCollision slides only the lander
      if (f.state === "jump" || ATTACKS[f.state]) f.state = "idle";
    }
  }
  f.x += f.vx * DT;
  f.vx *= Math.max(0, 1 - 9 * DT);
  f.x = Math.max(STAGE.min, Math.min(STAGE.max, f.x));
  if (f.wallBounce && (f.x <= STAGE.min || f.x >= STAGE.max)) {
    f.vx = -f.vx * 0.4;
    f.vy = Math.max(f.vy, 24);
    f.wallBounce = false;
    g.shake = 12;
    g.sparks.push({ x: f.x, y: f.y + 11, life: 1, big: true, color: "f97316" });
  }

  f.energy = Math.min(100, f.energy + ENERGY_REGEN * DT);

  const atk = ATTACKS[f.state];
  if (atk && ATTACK_STATES.has(f.state) && !f.attackHit) {
    const t = tick - f.stateTick;
    if (t >= atk.startup && t < atk.startup + atk.active) {
      const dx = opp.x - f.x;
      const air = !f.onGround;
      if (Math.abs(dx) <= atk.reach && Math.abs(opp.y - f.y) <= (air ? 24 : 13)) {
        applyHit(f, opp, f.state, tick, g);
      }
    }
  }

  if (f.state === "special" && !f.projSpawned && tick - f.stateTick >= ATTACKS.special.startup) {
    g.projectiles.push({
      x: f.x + f.facing * 9,
      y: f.y + 9,
      vx: f.facing * ATTACKS.special.proj.speed,
      owner: f === g.p1 ? "p1" : "p2",
      hit: false,
    });
    f.projSpawned = true;
    // Named special cooldown the instant the projectile launches — another
    // special can't begin until this floor elapses, on top of the energy gauge.
    f.specialLockUntil = tick + SPECIAL_COOLDOWN;
  }
}

function stepProjectiles(g, tick) {
  for (const p of g.projectiles) {
    p.x += p.vx * DT;
    const target = p.owner === "p1" ? g.p2 : g.p1;
    if (!p.hit && Math.abs(p.x - target.x) <= 7 && Math.abs(p.y - (target.y + 9)) <= 16) {
      if (applyProjectileHit(target, p, tick, g)) p.hit = true;
    }
  }
  g.projectiles = g.projectiles.filter((p) => !p.hit && p.x > STAGE.min - 3 && p.x < STAGE.max + 3);
}

function resolveCollision(g) {
  const a = g.p1, b = g.p2;
  if (!a.onGround || !b.onGround) { a.slideSide = b.slideSide = 0; return; }
  const dx = b.x - a.x;
  const dist = Math.abs(dx);
  if (dist >= CONTACT) { a.slideSide = b.slideSide = 0; return; }
  const sign = dx >= 0 ? 1 : -1;
  const overlap = CONTACT - dist;

  // Cross-up landing: place only the lander, on its real side (or the jump's side when on top).
  if (a.justLanded || b.justLanded) {
    const lander = a.justLanded ? a : b;
    const opp = a.justLanded ? b : a;
    const rel = lander.x - opp.x;
    const side = Math.abs(rel) > 0.5 ? Math.sign(rel) : (lander.landSide || 1);
    placeApart(lander, opp, side, LAND_GAP);
    return;
  }

  // The fighter who moved INTO the other absorbs the overlap — no shove/drag.
  const inA = Math.max(0, (a.x - (a.prevX ?? a.x)) * sign);
  const inB = Math.max(0, ((b.prevX ?? b.x) - b.x) * sign);
  const shareA = inA + inB > 0 ? inA / (inA + inB) : 0.5;
  const aTarget = a.x - sign * overlap * shareA;
  const bTarget = b.x + sign * overlap * (1 - shareA);
  if (aTarget < STAGE.min) {
    const extra = STAGE.min - aTarget;
    a.x = STAGE.min;
    b.x = Math.min(STAGE.max, bTarget + extra);
  } else if (bTarget > STAGE.max) {
    const extra = bTarget - STAGE.max;
    b.x = STAGE.max;
    a.x = Math.max(STAGE.min, aTarget - extra);
  } else {
    a.x = aTarget; b.x = bTarget;
  }
  if (Math.sign(a.vx) === sign) a.vx *= 0.2;
  if (Math.sign(b.vx) === -sign) b.vx *= 0.2;
}

function decayEffects(g) {
  g.shake = Math.max(0, (g.shake || 0) - 1);
  if (g.sparks) { for (const s of g.sparks) s.life -= (3.2 / TICK_HZ); g.sparks = g.sparks.filter((s) => s.life > 0); }
}

// inputs: { p1: {moveDir,jump,crouch,action}, p2: {...} }
export function step(g, tick, inputs) {
  g.tick = tick;
  if (tick < (g.hitstopUntil || 0)) { decayEffects(g); return; }
  g.p1.prevX = g.p1.x;
  g.p2.prevX = g.p2.x;
  updateFighter(g.p1, g.p2, inputs.p1, tick, g);
  updateFighter(g.p2, g.p1, inputs.p2, tick, g);
  resolveCollision(g);
  g.p1.justLanded = false;
  g.p2.justLanded = false;
  stepProjectiles(g, tick);
  decayEffects(g);
}

// Compact snapshot for broadcasting to clients (the renderer interpolates these).
export function serialize(g) {
  const f = (p) => ({
    x: +p.x.toFixed(3), y: +p.y.toFixed(3), vx: +p.vx.toFixed(3), vy: +p.vy.toFixed(3),
    facing: p.facing, health: +p.health.toFixed(2), energy: +p.energy.toFixed(1),
    state: p.state, stateTick: p.stateTick, flash: +p.flash.toFixed(2), ko: p.ko,
    crouch: p.crouch, blockHigh: p.blockHigh, blockLow: p.blockLow,
  });
  return {
    tick: g.tick,
    p1: f(g.p1), p2: f(g.p2),
    projectiles: g.projectiles.map((p) => ({ x: +p.x.toFixed(3), y: +p.y.toFixed(3), owner: p.owner })),
    shake: +g.shake.toFixed(2),
    sparks: g.sparks.map((s) => ({ x: +s.x.toFixed(3), y: +s.y.toFixed(3), life: +s.life.toFixed(2), big: s.big, color: s.color, ring: s.ring, owner: s.owner })),
    // Remaining power-blast flash as a 0..1 fraction (clients have no tick clock).
    flash: g.superFlash && g.tick < g.superFlash.until ? { t: +((g.superFlash.until - g.tick) / 19).toFixed(2), owner: g.superFlash.owner } : null,
    comboCount: g.combo.count > 1 && g.tick < g.combo.until ? g.combo.count : 0,
  };
}