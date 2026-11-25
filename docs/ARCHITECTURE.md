# System Architecture & Synchronization Design (`docs/ARCHITECTURE.md`)

## 0. Status (retail reality)
`docs/HANDOFF.md` → "Current state" is the source of truth; any public feature claim (Nexus page) must match it.

| Tag | Item |
|---|---|
| `[IMPLEMENTED]` | Shared-memory Lua ⇄ DLL bridge (`mem_bridge.*`), Esc-menu Co-op UI, Main-menu Join Friends, Steam lobby host/join, **LZ4 packet/save compression (`lz4_codec.hpp`, `kFlagLz4`)**, building groups (place/move/delete), loose scenery (place/delete), paths (area sync), **terrain brush strokes (`0x23`, `pz2coop.terrainsync.lua`)**, **water/lakes (`0x22`, `pz2coop.watersync.lua`)**, **staff hire/fire (`0x30`, `pz2coop.staffsync.lua`)**, **exhibit & habitat animals + waypoints (`0x30`/`0x31`, `pz2coop.animalsync.lua`)**, **research tier unlocks (`0x30`, `pz2coop.researchsync.lua`)**, host cash + game speed + time-of-day ledger (`0x11`), baseline save transfer, **AAA third-person locomotion & camera polish (`pz2coop.avatar.lua`, `pz2coop.presence.lua`)**, **Radial Emote Wheel + world object interactions + held props + co-op pair actions (`EmoteWheel.js`, `pz2coop.actions.lua`)** |
| `[OFF]` | Fence/habitat-wall receiving (`c_bApplyFences`, game hangs), WebSocket `ws://127.0.0.1:27099` + named pipe (compiled out of Release DLL), verbose diagnostic IAT hooks (`PZ2COOP_DEV_DIAG=OFF` in Release), file-polling bridge (file I/O stubbed in retail) |
| `[PLANNED]` | Conservation credits overwrite (no engine setter found), native CPU `IKHeadLook` / `IKFootPlant` prototype on skeletal `.mani` rigs |

Not yet verified: any two-PC session (all tests so far are solo loopback).

## 1. High-Level Data Flow
Network transport (`version.dll`) is kept separate from game logic (`.ovl` Lua + UI) across a local, in-process bridge:

```
[Host PC]                                              [Client PC]
PlanetZoo2.exe                                         PlanetZoo2.exe
 ├─ .ovl Lua (pz2coop.* managers, buildsync,            ├─ same
 │   regionsync, ui)  ◄─ Gameface JS (Esc Co-op screen) │
 │      ▲▼ shared-memory bridge (Lua table scanned by DLL)
 └─ version.dll (C++20 proxy)                           └─ version.dll
     ├─ SPSC ring buffers, echo guard                       │
     └─ steam_api64.dll ISteamNetworkingSockets ── Valve SDR (UDP relay) ──►
```

## 2. Crossing the Cobra Lua Sandbox Boundary
Cobra strips `io`/`os`; in retail, file I/O and HTTP from Lua are also stubbed.
- `[IMPLEMENTED]` **Memory bridge:** Lua keeps an integer table tagged with magic `0x5A32434F4F500000`; the DLL finds it
  in process memory (TValue stride 24) and exchanges JSON lines both ways. Pumped from wrapped `Game.GameScript.OnAdvance`.
- `[IMPLEMENTED]` **UI:** Gameface JS ⇄ Lua via the data store and engine events (`LUA_API_MAP.md` §10a). JS never talks
  to the DLL directly.
- `[OFF]` WebSocket `ws://127.0.0.1:27099` / pipe `\\.\pipe\PZ2CoopPipe` (dev tools/tests only) and file polling.

## 3. Sync Problems

### A. Initial Session Baseline (Save Handshake) — `[IMPLEMENTED]`, two-PC untested
Host lobby → 6-char Base62 room code. On join, host saves; DLL streams the save over reliable channel 0 as
`SAVE_CHUNK_DATA` (uncompressed; LZ4 `[PLANNED]`), client writes the fixed file `PZ2Coop/rx_save.bin` and loads it.

### B. Echo Loop Prevention — `[IMPLEMENTED]`
- Outgoing: if `g_IsApplyingRemoteAction`, drop. Else serialize and queue.
- Incoming: set the flag, run the apply job, clear it. Lua also absorbs detections near a just-replayed remote key.

### C. Spatial Addressing — `[IMPLEMENTED]` for groups, loose scenery, paths
Never send entity IDs as identity.
- Building groups: blueprint file + AABB centre; drift corrected by preview-measure-shift before commit.
- Loose parts: resource name + position + yaw/pitch/roll, applied via `editMode:RequestUndoOperation`.
- Deletes: position (cm) + radius; group ID only as a lookup hint, verified by position.
- Paths: area replace (`0x22`) with a blueprint of the path chunks in the changed AABB.

### D. Terrain / Water — `[PLANNED]`
Detected and logged only. Plan: replay tool parameters (brush strokes, lake AABB) instead of meshes.

### E. Economy & Animals
- `[IMPLEMENTED]` Economy: host authoritative; `LEDGER_SYNC_1HZ` overwrites client cash (float32: $8 steps at $100M).
  Conservation credits / research `[PLANNED]`.
- `[PLANNED]` Animals & staff: macro events keyed by `SyncUUID = CRC32(Species + Genetics + CreationIndex)`.

## 4. Hard Invariants
- Zero Frontier files in Git or release archives. UI changes ship only as anchor patches (`src/ovl_ui/*_patch.js`)
  applied at build time to the player's own game files.
- Steam AppID `3219030` only, taken from the running game. Never Spacewar `480`, never a `steam_appid.txt` override.
- Sync only in Sandbox/Challenge parks; Franchise disables all hooks (`managers.pz2coopmanager.lua`).
- No DLC/content unlocking, no ownership checks bypassed.
- Received data never chooses a local path: incoming files go to fixed names (`rx_save.bin`, `rx_<n>.bin`) in `<game>\PZ2Coop\`.
