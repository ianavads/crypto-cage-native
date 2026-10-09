# Build & Deploy — Crypto Cage Combat (native)

One Godot 4 project produces two artifacts; `main.gd` picks the role at runtime
(headless/`--server` → authority server; GUI/`cryptocage://`/`--client` → client).

## Prerequisites
- Godot 4.7.x **stable, official** build (the same public build auditors can
  reproduce — do not self-compile; see the headless runbook).
- Export templates for 4.7.x installed (`Editor → Manage Export Templates`),
  required to produce binaries/PCKs. Open the project in the editor once so it
  finalizes `export_presets.cfg` defaults and validates them against templates.

## Export (from the project root)
```bash
# Linux headless authority server — PCK (copied to /opt/cage/cage_server.pck)
godot --headless --path . --export-pack "Linux Server"  build/linux_server/cage_server.pck

# Desktop clients
godot --headless --path . --export-release "Windows Client" build/windows_client/CryptoCageCombat.exe
godot --headless --path . --export-release "Linux Client"   build/linux_client/CryptoCageCombat.x86_64
godot --headless --path . --export-release "macOS Client"   build/macos_client/CryptoCageCombat.zip
```
The server preset sets `dedicated_server=true` (strips rendering) and excludes
`client/*` and `tests/*`; client presets exclude `server/*` and `tests/*`.

## Run the server (Hetzner) — see reference/godot-headless-runbook.md
```bash
godot-headless --headless --main-pack /opt/cage/cage_server.pck
```
Config via environment (never hardcode secrets or the host):

| Env | Meaning | Default |
|-----|---------|---------|
| `CAGE_ENGINE_VERSION` | Bundled engine version (FNV-1a from `GET /functions/get-engine-source`); seats with a different version are refused | `FightSim.ENGINE_VERSION` (empty until pinned) |
| `SERVER_SETTLE_TOKEN` | Shared secret for the settle POST (`Authorization: Bearer`) | — (out-of-band) |
| `CAGE_SETTLE_URL` | Settle endpoint | `…/functions/settle-native-match` |
| `CAGE_PORT` | ENet UDP + WebSocket TCP port | `7777` |
| `CAGE_WS` / `--no-ws` | WebSocket TCP fallback (`0` disables) | on |
| `CAGE_MATCH_TICKS` | Round length cap, ≤ 6000 (codec max) | `6000` |
| `CAGE_COUNTDOWN_TICKS` | 3-2-1 lead-in before LIVE | `180` |

systemd note: the runbook's unit passes the PCK via `--main-pack`; add the env
vars above as `Environment=` lines (keep `SERVER_SETTLE_TOKEN` out of the unit if
you can — load it from an `EnvironmentFile=` with restricted perms).

## Client
- Register the protocol once (per user, Windows): `CryptoCageCombat.exe --register-protocol`
  (writes `HKCU\Software\Classes\cryptocage`; `--unregister-protocol` removes it).
  macOS: `Info.plist` `CFBundleURLTypes`; Linux: a `.desktop` file with
  `MimeType=x-scheme-handler/cryptocage` + `xdg-mime default`.
- The OS then routes `cryptocage://launch?match=<id>&seat=<1|2>&token=<jwt>` to the
  client, which calls `verify-match-seat`, connects to the returned `server_url`
  (use `ws://host:7777` to force the WebSocket fallback), and sends inputs only.
- Client config: `CAGE_VERIFY_URL`, `CAGE_WEB_URL` (env or `--verify-url=`/`--web-url=`).
  Dev shortcut (skip verify): `--server-url=127.0.0.1:7777 --seat=1 --match=dev --engine-version=…`.

## Tests (headless, no templates needed)
```bash
# Determinism parity vs published fightSim.js (run both, diff):
godot --headless --path . --script res://tests/parity_harness.gd
node <scratch>/parity/run_js.mjs
# Codec parity + round-trip:
godot --headless --path . --script res://tests/codec_test.gd
# Full-loop (needs a running server + mock verify/settle): see tests/*.tscn
godot --headless --path . res://tests/client_net_test.tscn   # ENet
godot --headless --path . res://tests/client_ws_test.tscn    # WebSocket
```

## Engine-version discipline
Every time Base44 republishes the engine (new FNV-1a hash), re-port
`engine/fight_sim.gd` if the source changed, re-pin `CAGE_ENGINE_VERSION`, and
re-export the server PCK + clients. Drift silently breaks matchmaking/settlement.
