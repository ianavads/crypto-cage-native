// © 2026 Ian W Thompson. Author & Owner: Ian W Thompson. All rights reserved.
// Proprietary — part of Crypto Cage Combat. No copying or derivative works.
//
// Client-side encoder for the match input replay. Mirrors the decode format in
// base44/shared/gatekeeperSim.ts: 6 bits per fixed 1/60s tick, one char from a
// 64-char alphabet. The server replays this exact stream through the
// deterministic gatekeeper sim to derive the authoritative skill score — so the
// player's score is server-verified, not client-claimed.
//
// Bit layout (must match decodeReplay exactly):
//   moveDir (0 none,1 left,2 right) | jump (bit 2) | crouch (bit 3) | action (bits 4-5: 0 none,1 light,2 heavy,3 special)

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export function encodeInput(i) {
  const moveDir = i.moveDir < 0 ? 1 : i.moveDir > 0 ? 2 : 0;
  const jump = i.jump ? 4 : 0;
  const crouch = i.crouch ? 8 : 0;
  const action = i.action === "light" ? 1 : i.action === "heavy" ? 2 : i.action === "special" ? 3 : 0;
  const v = moveDir | jump | crouch | (action << 4);
  return ALPHABET[v] || "A";
}

export const REPLAY_MAX = 6000;