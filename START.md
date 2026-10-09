he native Godot client + headless server for Crypto Cage Combat.
Everything you need is in this folder's ./reference/ directory — read those
files first, especially native-handoff-brief.md (the binding spec) and
fightSim.js (the canonical MIT-licensed deterministic fight engine you must
port to GDScript literally).

Your job, in order:
1. Read reference/native-handoff-brief.md and reference/fightSim.js fully.
2. Create a Godot 4 project here (project.godot) if none exists.
3. Port fightSim.js to GDScript as a single deterministic module
   (e.g. res://engine/fight_sim.gd). Hard requirements:
     - 60 Hz fixed tick; NO wall-clock delta. One tick = one discrete step.
     - Integer/fixed-point math for ALL game state that affects outcomes
       (health, energy, x, vx). Round to integers at every state transition.
       GDScript float is non-deterministic across platforms — do not rely on it.
     - NO randomness unless present in fightSim.js (it has none). Do not add any.
     - Expose create_game(), step(game, tick, inputs), serialize(game) mirroring
       the JS exports, plus the same constants (TICK_HZ, STAGE, CONTACT, ATTACKS).
     - Preserve the MIT attribution header (Author/Owner: Ian W Thompson).
4. After writing the module, run a syntax check every time:
     godot --headless --check-only --script res://engine/fight_sim.gd
   Read any stderr, fix, repeat until clean.
5. Then implement the headless server: a Main scene that listens on UDP 7777,
   accepts two seats, confirms both seats' verified context share the same
   match_id + engine_version, runs the authoritative sim at 60 Hz, records the
   per-tick input replay for BOTH seats, and on KO/timeout POSTs the result to
   the Base44 settle-native-match endpoint (see brief §4).
6. Use the SAME replay encoding as reference/replayCodec.js (6 bits/tick,
   the 64-char alphabet, bit layout moveDir|jump|crouch|action) so Base44 can
   decode it without a second codec.
7. Build the desktop client export that registers the cryptocage:// protocol,
   calls verify-match-seat, connects to server_url, and sends ONLY per-tick
   inputs (never health/scores).
8. Tell me what you've created and what's left after each major step. Do not
   touch anything outside this folder. Ask me before guessing Base44 behavior
   — flag questions back rather than inventing contract details.