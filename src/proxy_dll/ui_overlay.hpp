#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace pz2 {

// Builds our UI overlay (Win64/ovldata/PZ2Coop/UI/PZ2CoopUI.ovl) on the player's PC, so the release zip holds
// no Frontier files (CLAUDE.md rule 8). Inputs, all local:
//   - the game's own Win64/ovldata/GameMain/Content/UserInterfaceEssentials.ovl (Oodle, read with the game's
//     oo2core_9_win64.dll),
//   - PZ2CoopUI.template: our overlay with one empty slot per patched vanilla file
//     ("/*PZ2COOP_SLOT <n> <size> <path>*/" + spaces), its archive stored as uncompressed zlib blocks,
//   - patch<n>.js: our anchor patch for slot n (format: src/ovl_ui/pausemenu_patch.js).
// Each slot gets the patched vanilla file, space padded, and the zlib adler32 is recomputed; no size changes.
// Python reference: tools/ui_overlay.py (tools/test_ui_overlay.py compares both byte for byte).

// Starts the build on its own thread (skipped when the cached output is still valid).
void startUiOverlayBuild();
// Called from the game's CreateFileW hook: an open of our PZ2CoopUI.ovl waits (max 20 s) until the build is
// done, so the engine's content scan / api.ui2.LoadOverlay never sees a missing or half-built file.
void waitForUiOverlayIfOurs(const wchar_t* path);

// The whole build; returns false with a reason on any problem (and removes a stale output then).
bool buildUiOverlay(const std::filesystem::path& gameDir, const std::filesystem::path& packUiDir, bool useCache,
                    std::string& error);

// Pieces, exposed for the self-test.
bool applyAnchorPatch(std::string_view vanilla, std::string_view patch, std::string& out, std::string& error);
std::string stripSourceMap(std::string_view js);
std::uint32_t adler32(const std::uint8_t* data, std::size_t size);

} // namespace pz2
