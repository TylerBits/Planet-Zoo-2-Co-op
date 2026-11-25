# Planet Zoo 2 Co-op (`PZ2-Coop`)

Unofficial peer-to-peer multiplayer co-op mod for *Planet Zoo 2* (Sandbox and Challenge modes) over Steam.

> **Disclaimer:** Unofficial community mod. Not affiliated with or endorsed by Frontier Developments. Requires a legitimate Steam copy of *Planet Zoo 2* (AppID `3219030`). Co-op automatically disables itself in Franchise mode.

## Overview

`PZ2-Coop` connects two players peer-to-peer through Valve's **Steam Datagram Relay** (`ISteamNetworkingSockets`) with no port forwarding or external servers:

- **`src/proxy_dll/` (`version.dll`):** C++20 proxy DLL loaded alongside `PlanetZoo2.exe`. Handles Steam Lobby matchmaking (Base62 room codes & Steam friend invites), Steam Datagram Relay P2P transport, LZ4 packet compression, lock-free SPSC queues, and an in-process shared-memory bridge to Lua.
- **`src/ovl_mod/`:** Cobra Lua scripts packed into an `.ovl` content pack (`Win64/ovldata/PZ2Coop/`) that synchronize building groups, loose scenery, paths, economy, presence/avatars, and more.
- **`src/ovl_ui/`:** Preact/CSS UI components (`CoopMenu`, `JoinFriends`, `EmoteWheel`) and minimal anchor patches (`*_patch.js`) applied at runtime/build time to the player's own game UI—**zero Frontier game assets are shipped in this repository or in release archives**.

## Feature Status

> **Beta notice:** Core building, path, economy, join, and presence systems have been exercised in solo loopback and initial two-PC playtesting; newer sync modules are offline-tested and undergoing live two-PC validation. Always back up your zoo save before hosting.

| Feature | Status | Notes |
|---|---|---|
| Steam lobbies, room codes (`PZ-xxxxxx`), friend invites & main-menu join | Beta | Works via Steam Datagram Relay; two-PC polish ongoing |
| Baseline zoo save transfer on join | Beta | Chunked reliable transfer with LZ4 compression |
| Building groups & blueprints (place, move, delete) | Working | Zero-ID spatial addressing with preview drift correction |
| Loose scenery pieces (place, delete, rotation) | Working | Applied via engine undo operations |
| Paths (draw, extend, demolish) | Working | Area sync via path volume chunks |
| Shared cash, game speed & time of day | Working / Beta | Host-authoritative 1 Hz ledger (prevents double-deductions) |
| Per-player undo / redo (`Ctrl+Z` / `Ctrl+Y`) | Beta | Undoes only your own changes |
| Walk together (first/third-person avatars, emotes, props & world actions) | Beta | Animated native avatars & radial emote wheel |
| Water (lakes), terrain strokes, staff, animals & research | Beta | Implemented & offline-tested; live two-PC validation pending |
| Fences / habitat walls | Disabled | Receive path currently disabled while investigating engine hang |

## Security & Networking Summary

- **Transport:** Steam Datagram Relay (`ISteamNetworkingSockets`) via the running game's `steam_api64.dll` (AppID `3219030` only; never Spacewar `480` or `steam_appid.txt`).
- **No listening ports, no external servers, no telemetry:** Release builds compile out all dev IPC listeners (WebSocket/named pipe) and verbose diagnostic hooks.
- **Safe file handling:** Incoming network payloads can never choose local file paths; received saves and attachments write strictly to fixed filenames (`rx_save.bin`, `rx_<n>.bin`) inside `<game>\PZ2Coop\`.
- **Franchise mode lockout:** All sync hooks automatically disable when playing a Franchise zoo. No DLC unlocking or ownership bypasses.
- **Zero Frontier assets:** UI overlays are generated locally from the player's own installation using anchor patches.

## Building from Source

### Prerequisites
- Windows 10/11 (x64)
- Visual Studio 2022 (or Build Tools for Visual Studio 2022) with the **Desktop development with C++** workload
- Python 3.10+ with `lupa` (`pip install lupa`)
- Node.js (optional, for headless UI JS checks)
- A legitimate Steam installation of *Planet Zoo 2*

CMake does not need to be preinstalled: `tools/build_dll.py` automatically downloads a pinned, SHA-256-verified portable CMake into `tools/cmake/` on first run.

### Commands

```powershell
# 1. Build version.dll (Release) and run C++ selftests
python tools/build_dll.py

# 2. Run the full offline test & invariant suite
python tools/run_all_tests.py

# 3. Build and install the mod into your local Planet Zoo 2 folder
python tools/build_ovl_mod.py --install

# 4. Package a shareable zip (dist/PZ2Coop.zip)
python tools/make_installer.py
```

To uninstall from the game folder:

```powershell
python tools/build_ovl_mod.py --uninstall
```

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — System architecture, shared-memory bridge, echo suppression, and invariants
- [`docs/NETWORK_PROTOCOL.md`](docs/NETWORK_PROTOCOL.md) — Binary packet headers, Steam P2P channels, and payload schemas
- [`docs/LUA_API_MAP.md`](docs/LUA_API_MAP.md) — Engine Lua & UI API reference
- [`docs/LUA_EXTRACTION_GUIDE.md`](docs/LUA_EXTRACTION_GUIDE.md) — Local `.ovl` extraction pipeline guide
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — Contribution rules and build/test steps

## License

Copyright (C) 2026 TylerBits

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version (`GPL-3.0-or-later`). It is distributed WITHOUT ANY WARRANTY. See [`LICENSE`](LICENSE) for the full text.
