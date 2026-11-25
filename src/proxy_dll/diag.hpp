#pragma once

#include <string_view>

namespace pz2 {

// First-run diagnostics: patches PlanetZoo2.exe's own import table so the game's file opens and debug
// output can be observed, logging to <exe dir>\PZ2Coop\diag.log:
//   - every file path containing "pz2coop" (our content pack, the bridge folder, Lua marker files),
//   - the first few paths under "ovldata" (shows how the engine resolves content-pack folders),
//   - OutputDebugStringA/W text (catches api.debug.Trace if retail routes it there).
// ponytail: diagnostic scaffolding for bring-up; remove once Lua <-> DLL I/O is confirmed in-game.
void installDiagnostics();
// Background scan (12 passes, 20 s apart) for the marker string our Lua builds at runtime; proves the
// Lua ran and reports which api.debug file roots work, independent of Lua file I/O. Logs "LUA" lines.
void startDiagnosticScan();
// Appends one line to diag.log (thread-safe). Used by the DLL and, via {"cmd":"diag"}, by Lua.
void diagLog(std::string_view text);
// Points PlanetZoo2.exe's import of <dll>!<function> at hook; returns the original, or nullptr if not imported.
void* patchExeImport(const char* dll, const char* function, void* hook);

} // namespace pz2
