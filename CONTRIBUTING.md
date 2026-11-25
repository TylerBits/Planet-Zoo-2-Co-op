# Contributing to PZ2-Coop

Unofficial, open-source co-op mod for Planet Zoo 2. Not affiliated with Frontier Developments.

## Hard rules (PRs breaking these are closed)
1. **Zero Frontier assets.** No `.ovl`, `.ppuipkg`, decompiled/extracted Lua, JS, CSS, textures or fonts from the game.
   Changes to game UI files go in as anchor patches (`src/ovl_ui/*_patch.js`, `@@ before|after <anchor>`), applied at
   build time to the player's own install.
2. **Steam AppID `3219030` only**, read from the running game. No Spacewar `480`, no `steam_appid.txt`.
3. **Sandbox/Challenge only.** Sync must stay off in Franchise parks. No DLC unlocking or ownership bypass.
4. **Fixed local paths.** Nothing received from the peer may choose a file path; incoming data is written only to
   fixed names under `<game>\PZ2Coop\`.
5. **Echo guard.** Outgoing hooks check `g_IsApplyingRemoteAction`; remote applies set/clear it (`docs/ARCHITECTURE.md` §3B).
6. **Honest status.** Don't mark a feature as working in docs unless it has been verified in game.

## Licensing and disclosure
- By opening a PR you license your contribution under the repository license and allow its redistribution on
  GitHub and Nexus Mods.
- PR description must state whether AI tools were used and which (tool + model), or "none".

## Build and test
Requires Windows, Visual Studio 2022 or the free "Build Tools for Visual Studio 2022" with the "Desktop development
with C++" workload, Python 3 with `lupa`, and a legitimate Steam copy of Planet Zoo 2. CMake is not needed:
`tools/build_dll.py` downloads the pinned portable CMake into `tools/cmake/` (gitignored, checksum-verified) on first run.

```
python tools/build_dll.py                         # builds version.dll, runs the selftest ("0 check(s) failed")
python tools/run_all_tests.py                     # runs the full offline Lua, UI, C++, and invariant suite
python tools/build_ovl_mod.py --install           # pack + version.dll into the game; --uninstall removes
```

Logs: `<game>\PZ2Coop\diag.log` (+ `diag.prev.log`). Include the relevant lines in bug reports, never the whole save.
Architecture: `docs/ARCHITECTURE.md`; wire format: `docs/NETWORK_PROTOCOL.md`.
