# Godot ↔ Base44 Seat-Token Integration Spec

How the native Godot client and the Base44 web app authenticate, launch, and
settle a match. This is the contract the headless server and the Godot client
both implement; the web app already implements its half.

**Principle:** the web app owns identity, money, and matchmaking. The native
binary owns physics/geometry fairness. The only thing that crosses the
boundary is a short-lived, signed **seat JWT** + the verified match context.

---

## 1. The three functions

| Function              | Caller            | Purpose                                              |
|-----------------------|-------------------|------------------------------------------------------|
| `issue-seat-token`    | Web app (logged-in player) | Binds the player to a seat on a `MatchSeat`, returns a signed seat JWT + a `cryptocage://` launch URL. |
| `verify-match-seat`   | Godot client (no app session) | Verifies the JWT signature/expiry, cross-checks the registry, resolves both fighters server-side, returns authoritative match context. |
| `settle-fight` / `settle-prize-fight` | Godot headless server (service role) | Accepts the signed result + replay ledger, re-runs it through the published engine, writes the `Challenge` settlement. |

`issue-seat-token` and `verify-match-seat` are deployed and tested
end-to-end. `settle-*` already exists for the in-browser fight path; the
native server calls the same functions with `score_source:"replay"`.

---

## 2. Sequence: from "FIGHT" on the web to a settled native bout

```
 Player A (web)                Base44                Player B (web)        Godot headless
      |                          |                        |                     |
   accept callout ───────────▶ Overworld actor mints matchId + seats
      |                          |                        |                     |
   issue-seat-token ───────▶ MatchSeat(seat1=A) ──▶ seat JWT A + cryptocage://A
                              seat2 reserved for B
      |                          |   B opens the match too ─▶  issue-seat-token
      |                          | ◀────────────────────── MatchSeat(seat2=B)
      |                          | ─▶ seat JWT B + cryptocage://B
      |                          |                        |                     |
   OS opens cryptocage://A ─────────────────────────────────────────────▶ Godot client A
      |                          |                        |                     |
   Godot client A: POST verify-match-seat { seat_token: A } ─▶ Base44
      |                          | ◀ verified context (fighters, engine_version, server_url)
      |                          |   Godot client A connects to server_url, relays context
      |                          |                        |                     |
   (B symmetric) ──────────────────────────────────────────▶ Godot client B
      |                          |                        |                     |
      |                          |                        |   server: both contexts match → LIVE
      |                          |                        |   server: authoritative tick, records replay
      |                          |                        |   KO / timer → ENDED
      |                          |                        |                     |
      |                          | ◀── server POSTs settle(-prize)-fight {result, replay, engine_version}
      |                          | ─▶ Challenge settled, leaderboards/payout updated
```

### Why two verifications
- `issue-seat-token` **authenticates the player** (requires a valid app
  session) and **binds** them to a seat on the registry — so a stolen JWT
  alone can't steal a seat, because the binding is already recorded.
- `verify-match-seat` is called by the **native binary**, which has no app
  session. It proves the token is genuine (HS256 signature), fresh (expiry),
  and unaltered (registry cross-check: the `seat`/`user_id`/`fighter_id` on
  the JWT must match what `issue-seat-token` wrote). Only then does it hand
  over the fighters' real data.

---

## 3. The seat JWT

Header: `{ "alg": "HS256", "typ": "JWT" }`
Claims:

| Claim                  | Meaning                                                        |
|------------------------|----------------------------------------------------------------|
| `sub`                  | App user id of the seat holder.                                |
| `match_id`             | Overworld-minted match id (also the `MatchSeat` key).          |
| `seat`                 | 1 or 2.                                                        |
| `fighter_id`           | The fighter this player is fielding (already access-checked at issue time). |
| `opponent_fighter_id`  | The other seat's fighter (so the client can render the opponent pre-verify). |
| `engine_version`       | FNV-1a hash of the current `EngineRelease` the server must run. |
| `server_url`           | Godot headless endpoint the client connects to.                |
| `match_type`           | `points` / `wager` / `prize`.                                  |
| `iat`, `exp`           | Issued / 10-minute expiry.                                      |

- Signed with `SEAT_JWT_SECRET` (HS256, 32 random bytes, stored as an app
  secret — NOT `ACTOR_TOKEN_SECRET`, which is actor-scoped and unreadable
  in the function runtime).
- The `MatchSeat.status` moves `forming → ready → live → ended` as seats
  bind and the match progresses; `verify-match-seat` refuses a token whose
  seat is already bound to a different user (anti-theft) and refuses an
  expired/already-ended match.

---

## 4. What the Godot client must send / trust

**Send on connect to `server_url`:**
- Nothing sensitive. The client already proved its seat via
  `verify-match-seat`; it relays only the **server-returned** context
  (match_id, engine_version, seat, resolved fighter ids) to the headless
  server so the server can confirm both seats agree.

**Never trust from the client:**
- Fighter stats, health, energy, KO decisions, scores. All of these are
  **outputs** of the server's deterministic sim, not inputs. The client sends
  only per-tick inputs (move/strike/block/charge). The server computes the
  resulting health/energy/KO and broadcasts the authoritative state.

**Never send to the client:**
- The signing secret, any `secrets.get(...)` value, the opponent's wallet,
  or any DB credentials. `verify-match-seat` returns only the resolved fight
  context (fighter display fields + engine_version + server_url + status).

---

## 5. Determinism contract (the whole point)

1. Both clients and the server must run the **same** `engine_version`.
   `issue-seat-token` stamps the current `EngineRelease` hash; the Godot
   server refuses a seat whose stated `engine_version` ≠ its bundled version.
2. The server records the full per-tick **input replay** from both seats.
3. At `ENDED`, the server signs `{ result, replay, engine_version }` and POSTs
   to `settle(-prize)-fight`. The settle function re-runs the replay through
   `base44/shared/fightSim.js` (the exact published source, identified by
   `engine_version`) and only accepts the result if its recomputation
   matches. This is the `/fight-engine` transparency guarantee:
   any auditor can replay the bout against the published source and reproduce
   the outcome — the native binary cannot lie about who won.

---

## 6. Failure / grief paths (already handled on the web side)

| Scenario                          | Web-app behaviour                                          |
|-----------------------------------|------------------------------------------------------------|
| Client never connects (crash/AFK) | Rehost-griefing cap → walkover settlement (`walkover:true`, `ranked:false`). |
| Seat JWT expired                  | `verify-match-seat` returns 401 → client bounces to web app → re-issue. |
| Engine version drift              | Server refuses seat → player sees a "update required" prompt → re-export. |
| Server crash mid-match            | systemd revives; web app re-hosts (`rehosted_to`) with a fresh seat/room. |
| Both seats same user (self-play)  | `issue-seat-token` 409 on the second seat → no match.      |

---

## 7. URLs & endpoints

- `cryptocage://launch?match=<match_id>&seat=<1|2>&token=<seat_jwt>` — the
  custom-protocol URL the OS routes to the installed Godot client.
- `https://cryptocage.base44.app/functions/issue-seat-token` (POST, auth)
- `https://cryptocage.base44.app/functions/verify-match-seat` (POST, public to the native client)
- `https://cryptocage.base44.app/functions/settle-fight` /
  `settle-prize-fight` (POST, service-role signature — server-only)

> `cryptocage.com` / `cryptocage.hetzner:7777` are placeholders:
  `cryptocage://` is the registered custom protocol; the Hetzner host:port is
  set in the `server_url` env/env-var chain and can be rotated per-instance
  without code changes.

---

## 8. Open items before a native beta

- [ ] Final `server_url` (real Hetzner host:port) wired into `issue-seat-token`.
- [ ] Godot client build with `cryptocage://` protocol registration (per-OS).
- [ ] Settle function signature schema for the server POST (result + replay
      shape) — align with the existing `challenger_replay`/`opponent_replay`
      fields on `Challenge`.
- [ ] Crash/telemetry mirroring from the server into `AuditLog`.