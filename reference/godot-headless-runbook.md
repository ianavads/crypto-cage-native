# Godot Headless Server Runbook (Hetzner)

Crypto Cage Combat — native-client authoritative settle server.

**Engine:** Godot 4.x (stable), headless build, Linux/x86_64.
**Host:** Hetzner Cloud CPX21 (3 vCPU / 4 GB RAM) minimum; CX22 for staging.
**OS:** Ubuntu 24.04 LTS.
**Royalty model:** Godot is MIT — zero per-seat royalty, no revenue share. This is the reason Unreal was abandoned.

The web app (Base44) is the **front desk**: auth, wallet, ledger, matchmaking, seat-token issuance.
Godot headless is the **authority**: deterministically runs the published fight engine for a matched pair of seats.

---

## 1. Provision the host

```bash
# From your workstation, after creating the server in the Hetzner Cloud console.
ssh root@<server-ip>

apt update && apt upgrade -y
apt install -y ufw fail2ban tmux unzip curl ca-certificates
# Godot headless needs no GPU. X/audio libs are unnecessary in --headless mode.

# Firewall: only the match port + SSH.
ufw default deny incoming
ufw allow 22/tcp
ufw allow 7777/udp   # Godot ENet multiplayer port (see §4)
ufw allow 7777/tcp   # if using WebSocket peer instead of ENet
ufw enable
```

Create a non-root service user:
```bash
useradd -m -s /bin/bash cage
install -d -o cage -g cage /opt/cage
```

---

## 2. Install the Godot headless binary

Download the **official** `Godot_v4.x-stable_linux_headless.x86_64` from
`https://godotengine.org/download/linux/` (NOT a self-compiled engine — the
registered EngineRelease hashes must resolve against a publicly verifiable
build so auditors can reproduce settled bouts).

```bash
sudo -u cage bash -lc '
  cd /opt/cage
  curl -fsSLO <godot-headless-url>.zip
  unzip -o Godot_v*-linux_headless.zip
  chmod +x Godot_v*_linux_headless.x86_64
  ln -sf Godot_v*_linux_headless.x86_64 godot-headless
'
```

Verify the binary prints its version with no project loaded:
```bash
sudo -u cage /opt/cage/godot-headless --version
```

---

## 3. Export the server project

In the Godot editor (your workstation), export the server scene as a **PCK** or
standalone Linux binary using the `Linux/X11` preset with `headless` rendering.
The exported artifact (`cage_server.pck` or a single executable) is copied to
`/opt/cage/cage_server.pck`.

The server scene reads two pieces of context at startup (env vars or CLI args):

| Context           | Source                                            |
|-------------------|---------------------------------------------------|
| `BASE44_VERIFY_URL` | `https://cryptocage.base44.app/functions/verify-match-seat` |
| `MATCH_ID`        | from the seat JWT the client carries              |

The server itself does **not** hold the seat JWT; each connecting client
presents its own JWT to `/verify-match-seat`, and the **client** relays the
authoritative context to the server on connect. The server enforces that both
seats' relayed context share the same `match_id` and `engine_version` before
starting the bout, then rejects any further geometry/stat assertions from the
clients — it simulates from its own copy of the canonical engine.

---

## 4. Network + match lifecycle

- **Transport:** Godot `ENetMultiplayerPeer` over UDP 7777 (low latency, the
  default for real-time fighters). WebSocket fallback on TCP 7777 for networks
  that block UDP — configurable per-match, set `server_url` accordingly in
  `issue-seat-token` (`cryptocage.hetzner:7777` is the current placeholder).
- **Match lifecycle** (state machine on the server):

  ```
  WAITING (0/2 seats verified) → READY (2/2) → LIVE → ENDED → teardown
  ```

  - `WAITING`: accept the first two `verify-match-seat`-blessed clients.
  - `READY`: both seats present and context-matching; broadcast a 3-2-1-FIGHT.
  - `LIVE`: authoritative tick at a fixed sim rate (60 Hz from
    `base44/shared/fightSim.js`, ported to GDScript). Record per-tick inputs
    from both seats (the replay log).
  - `ENDED`: a KO or timer expiry; the server signs the result + replay and
    POSTs to the Base44 settle function, then tears the room down.

- **Determinism:** the server pins to a single `engine_version` (the
  FNV-1a hash carried in the seat JWT's `engine_version` claim). If a client
  reports a mismatched version, the server refuses the seat and the player is
  bounced back to the web app to retry (the web app always issues against the
  current `EngineRelease.is_current`).

---

## 5. Run as a managed service (systemd)

`/etc/systemd/system/cage-server.service`:
```ini
[Unit]
Description=Crypto Cage Combat — Godot headless authority
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cage
WorkingDirectory=/opt/cage
Environment=BASE44_VERIFY_URL=https://cryptocage.base44.app/functions/verify-match-seat
Environment=SEAT_JWT_AUD=cryptocage
ExecStart=/opt/cage/godot-headless --headless --main-pack /opt/cage/cage_server.pck
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now cage-server
journalctl -u cage-server -f
```

> A single headless process multiplexes many match rooms in-process (each match
> is a Godot `SceneTree` instance keyed by `match_id`). Horizontal scaling =
> spin a second server and point new matches at its `server_url` via the
> `AppSetting` used by `issue-seat-token`.

---

## 6. Engine-version pinning & reproducibility

1. Every canonical engine change is republished as a new `EngineRelease` (the
   `/fight-engine` transparency page shows `is_current` verbatim).
2. The Godot server's bundled `fightSim` port must move in lockstep: when you
   cut a new `EngineRelease`, export and ship a matching `cage_server.pck`
   whose reported version equals the new hash. A drift breaks settlement
   because the settled `engine_version` won't match what auditors re-run.
3. Settlement writes the `engine_version` + replay onto the `Challenge`
   record; any auditor re-runs the published source against the replay and
   reproduces the outcome. See `docs/godot-base44-integration.md`.

---

## 7. Observability & ops

- **Logs:** Godot prints to stdout; systemd captures to journald. Mirror
  match-start / match-end lines to the Base44 `AuditLog` for admin visibility.
- **Crash recovery:** systemd `Restart=on-failure` revives the process; an
  in-flight match whose server crashes is detected by the web app's
  rehost-griefing path (the `rehosted_from`/`rehosted_to` fields on
  `Challenge`) and re-issued to a fresh seat/room.
- **Backups:** none required — the server is stateless between matches. All
  durable state lives in Base44 entities.

---

## 8. Cost envelope (launch)

- Hetzner CPX21 ≈ €9.49/mo. One instance comfortably runs dozens of concurrent
  1v1 matches in-process; scale by adding instances, not by resizing.
- No engine royalty, no per-seat license. The only platform cost on top of
  Hetzner is the Base44 plan the web app already runs on.

---

## 9. Pre-flight checklist

- [ ] Headless binary version matches the current `EngineRelease`.
- [ ] UFW allows only 22 and 7777.
- [ ] `BASE44_VERIFY_URL` env var set on the service.
- [ ] systemd unit enabled and `journalctl` shows a clean boot.
- [ ] A real two-seat test: issue from the web app → both clients connect →
      bout runs → settle function receives the signed result + replay.