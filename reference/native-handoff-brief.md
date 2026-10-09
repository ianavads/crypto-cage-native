# Native Cage — Outside-AI Handoff Brief

**Audience:** an external coding-AI / GDScript developer who will build the Godot
native client + headless server for Crypto Cage Combat.
**Source of truth:** this document + the live `/fight-engine` transparency page
+ `docs/godot-base44-integration.md` (which already specifies the trust contract).
**Your scope:** port the canonical engine to GDScript, build the headless authority
server, and build the desktop client. **Stay out of:** Base44 internals — call the
Base44 functions as documented, never reimplement auth/wallet/settlement.

---

## 0. The division of labour (read this first)

Crypto Cage Combat is a two-system product:

| Layer            | Owner              | Tech                          |
|------------------|--------------------|-------------------------------|
| Front desk (auth, wallet, ledger, matchmaking, seat-token issue/verify, settlement, leaderboards, NFT/mint, payments) | **Base44 platform** | React web app + serverless backend functions |
| Native cage (deterministic fight physics, the referee that actually judges a bout) | **You (Godot)** | Godot 4 + a Hetzner headless server |

The two systems talk **only** through:
1. the seat JWT (`issue-seat-token` / `verify-match-seat`), and
2. a signed result + replay POST from your headless server to a Base44 settle endpoint.

You do **not** touch the Base44 database, secrets, or auth. You consume the contract.

---

## 1. Get the canonical engine source (the thing you port)

The fight engine is published verbatim and versioned. Fetch it programmatically:

```
GET https://cryptocage.base44.app/functions/get-engine-source
```

Returns the current `EngineRelease`: `{ version, source, path, license, author, owner, copyright_year, changelog, is_current }`.

- `source` is `base44/shared/fightSim.js` — a pure-JS, deterministic, tick-based
  1v1 fighter simulation. **This is the canonical logic. Port it literally.**
- `version` is the FNV-1a content hash (8 hex). Your GDScript port MUST report
  this exact version, because the seat JWT carries it and the headless server
  refuses a seat whose stated `engine_version` ≠ its bundled version. Drift =
  no match. Every time Base44 republishes the engine with a new hash, you re-port
  and re-export.
- `license` is MIT. The port preserves the author/owner attribution
  (`Ian W Thompson`). Do not strip provenance.

You can also read the same source rendered on the `/fight-engine` page for visual
reference, but the `get-engine-source` call is the machine-readable one to build
against.

---

## 2. The determinism contract (the single most important requirement)

Reproducibility is the entire point. A settled bout must be re-runnable by any
auditor against the published source and produce an identical outcome. So:

- **Tick rate:** fixed 60 Hz. The sim does NOT use wall-clock delta time. One
  tick = one discrete step. Pause/compensate for lag by holding ticks, never by
  scaling time.
- **No floats for game state that affects outcomes.** Use integer/fixed-point
  math for health, energy, positions, damage. GDScript `float` is double-precision
  but still non-deterministic across platforms/CPU rounding if you rely on it —
  round to integers at every state transition.
- **No RNG that isn't seeded and shared.** If the JS uses any randomness, it must
  be a seeded RNG with the seed part of the match context; the port uses the same
  algorithm. (Inspect `fightSim.js` — if it's already deterministic with no
  Math.random, your port simply mustn't add any.)
- **Identical on both sides of a match and on the headless server.** The server's
  sim is the authority; the clients run the same sim for prediction/render only.
- **Inputs, not state, cross the wire.** Clients send per-tick input only
  (move/strike/kick/block/charge directions). The server computes health/energy/KO
  from its own sim and broadcasts authoritative state. Clients never assert
  health/damage/scores.

If you find `fightSim.js` has any non-determinism, **do not paper over it** —
flag it back to the Base44 side so the canonical source is fixed and re-versioned
before you port, rather than the port silently diverging.

---

## 3. The headless server (Godot 4, Linux/x86_64, Hetzner)

Build per `docs/godot-headless-runbook.md` (provisioning, systemd, port 7777). The
server's responsibilities:

1. **Accept two seats.** Each client arrives already holding a seat JWT it
   verified via `verify-match-seat` (see `docs/godot-base44-integration.md` §1).
   The client relays the *server-returned* verified context (match_id, seat,
   engine_version, both fighter ids) to the headless server on connect. The
   server confirms both seats' context share the same `match_id` + `engine_version`
   before starting. Reject mismatches.

2. **Refuse engine-version drift.** The server is bundled with one
   `engine_version`. If a connecting seat reports a different version, refuse and
   bounce the client back to the web app (the web app always re-issues against the
   current `EngineRelease.is_current`).

3. **Run the authoritative sim** (your ported GDScript `fightSim`), ticking at 60
   Hz, consuming both seats' per-tick inputs.

4. **Record the full input replay** from both seats — the ordered per-tick input
   log. This replay is what makes the settlement auditable.

5. **On KO or timer expiry (ENDED):** sign the result and POST it home (§4). Then
   tear the room down. One match per room; the process multiplexes rooms by
   `match_id`.

6. **Crash-safe:** the web app's rehost path will detect a crashed server
   mid-match and re-issue to a fresh seat/room (`Challenge.rehosted_to`). Your
   server doesn't need to survive crashes — it just needs to not corrupt state
   on restart, which is automatic if it's stateless between matches.

**Transport:** ENet (UDP 7777) for low-latency fighters; optional WebSocket
(TCP 7777) fallback for UDP-hostile networks.

---

## 4. The settlement POST (server → Base44)

This is the only call your server makes back to Base44. POST a signed result +
replay to the Base44 settlement endpoint. The Base44 side re-runs your replay
through the published `fightSim.js` and only accepts the result if its
recomputation matches — so you literally cannot lie about who won.

```
POST https://cryptocage.base44.app/functions/settle-native-match
Authorization: Bearer <SERVER_SETTLE_TOKEN>   # shared secret, set by the Base44 owner
Content-Type: application/json

{
  "match_id": "<from verified context>",
  "engine_version": "<bundled version, must match seat JWT>",
  "winner_seat": 1 | 2 | 0,        // 0 = draw/timeout
  "ended_reason": "ko" | "timeout" | "double_ko",
  "ticks": <int>,                   // total ticks simulated
  "replay": "<encoded per-tick input log, both seats,
               in a format the Base44 shared replay codec can decode>",
  "final_state": {                  // server-computed authoritative end state
    "seat1": { "health": <int>, "energy": <int> },
    "seat2": { "health": <int>, "energy": <int> }
  }
}
```

- **Replay format must match the existing Base44 replay codec.** The web app
  already encodes replays for the in-browser referee (see the
  `challenger_replay`/`opponent_replay` fields on `Challenge` and the
  `replayCodec` module). Use the same encoding so Base44's settle function can
  decode and re-run without a special native path. If the existing codec won't
  fit, propose the minimal delta back to the Base44 side — don't invent a
  second codec.
- **`SERVER_SETTLE_TOKEN`** is a shared secret the Base44 owner sets on the app;
  you receive it out-of-band. The settle endpoint refuses any POST without it.
  (The Base44 owner will provision this endpoint to this exact contract; treat
  the schema above as the binding spec.)
- On success the endpoint returns `{ settled: true, challenge_id }`. On
  replay-mismatch it returns 409 — treat that as a fatal port bug: your
  simulation diverged from the canonical source. Do not retry; surface it.

---

## 5. The desktop client

A Godot 4 desktop export (Windows/macOS/Linux). Responsibilities:

1. **Register the `cryptocage://` protocol** on install, so the OS routes
   `cryptocage://launch?match=<id>&seat=<1|2>&token=<jwt>` to this binary.
2. On launch, parse the URL → call `verify-match-seat` (POST, no app session
   needed) with `{ seat_token }`. Receive authoritative context
   (`match_id`, `seat`, `engine_version`, `server_url`, resolved fighters).
3. Connect to `server_url`. Relay the verified context so the server can
   confirm both seats agree.
4. **Send only inputs.** Read local controls (keyboard/gamepad), send per-tick
   moves. Render the server's authoritative state for prediction/animation only.
5. On `ENDED`, show the result (the settlement is the server's job, not the
   client's) and exit to the web app.

Never send fighter stats, health, or scores to the server — those are outputs,
computed server-side. Never hold the signing secret or call settlement from the
client — settlement is server-only.

---

## 6. Acceptance criteria (how you know it's done)

A two-seat end-to-end test, fully reproducible:

1. From the Base44 web app, two players match (Overworld callout/accept).
2. The web app issues both seat tokens; each LAUNCH opens the desktop client
   with the verified context.
3. Both clients connect to the headless server; the server confirms context
   match and starts the bout.
4. Play a round to KO or timeout. The server POSTs the signed result + replay
   to `settle-native-match`.
5. Base44 settles the `Challenge`, updates leaderboards, and — if applicable —
   triggers the prize payout. The `Challenge` record carries
   `engine_version` + the replay + `score_source:"replay"`.
6. An auditor hits `/fight-engine`, copies the published source, re-runs the
   stored replay, and reproduces the exact winner + final state. **This is the
   bar.** If an independent re-run ever diverges, the port is broken.

The Base44 side already has an in-browser `SIMULATE CLIENT VERIFY` button
(`NativeLaunch`) that proves the verify half of this loop works today; your
work makes the connect → bout → settle half real.

---

## 7. Constraints & non-goals

- **Do not** touch the Base44 database, secrets, or auth flows. You consume the
  function contract.
- **Do not** add pay-to-win or money handling on the native side — money lives in
  Base44. The server reports *who won*; Base44 decides what that pays.
- **Preserve** the MIT attribution (`Ian W Thompson`). The published engine and
  the port both carry it.
- **Engine-version discipline:** every Base44 engine re-version requires a
  matching port + re-export. Track this; drift breaks matches silently.
- **Keep it honest at launch:** until the client ships, players must not see a
  "Launch Native" button that does nothing. The Base44 side is gating it.

---

## 8. Questions to raise back to the Base44 side (do not guess)

- If `fightSim.js` contains any non-determinism (Math.random, float-dependence,
  date/time, async) — report it; the canonical source gets fixed and re-versioned
  first.
- If the existing Base44 replay codec can't capture your tick/input shape —
  propose the minimal delta; don't fork a second codec.
- The real `server_url` (Hetzner host:port) — the Base44 owner sets it via an
  `AppSetting`; you read it from the verified context, never hardcode.
- `SERVER_SETTLE_TOKEN` value — delivered out-of-band by the Base44 owner.